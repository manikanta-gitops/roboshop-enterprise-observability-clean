> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 12 - Implementation

Everything in this phase is real, runnable code that now lives in the repository. No placeholders except the four values you must set for your own AWS account and GitHub org (listed at the end).

---

## 1. Folder structure

```text
.
├── apps/                              # application source + Dockerfiles (unchanged)
├── charts/                            # Helm charts + common library (unchanged)
├── environments/{dev,qa,staging,production}/
│   ├── global-values.yaml             # env-wide values (image.registry patched by CI)
│   └── releases.yaml
├── infrastructure/                    # NEW - Terraform
│   ├── bootstrap/                     # S3 state bucket + DynamoDB lock table
│   ├── modules/
│   │   ├── vpc/                       # VPC, subnets, IGW, NAT, route tables, flow logs
│   │   ├── eks/                       # cluster, OIDC, managed node group, EBS CSI, add-ons
│   │   ├── ecr/                       # one repo per service + lifecycle policies
│   │   ├── github-oidc/               # keyless GitHub Actions -> AWS role
│   │   ├── irsa/                      # generic IAM-role-for-service-account
│   │   ├── security-groups/           # ALB / node / datastore SGs
│   │   └── addons/                    # ALB controller, External Secrets, metrics-server,
│   │       └── policies/              #   gp3 StorageClass, ArgoCD
│   └── environments/
│       ├── dev/                       # 2 AZ, 1 NAT, SPOT t3.large, single-replica controllers
│       └── production/                # 3 AZ, NAT per AZ, ON_DEMAND m6i.large, HA controllers
├── gitops/                            # ArgoCD (fixed)
│   ├── projects/                      # roboshop + platform AppProjects
│   ├── applications/                  # root-<env> app-of-apps + root-platform
│   ├── applicationsets/               # one Application per chart per env
│   └── platform/                      # monitoring + logging Applications
├── monitoring/
│   ├── kube-prometheus-stack/values.yaml
│   └── rules/roboshop-alerts.yaml
├── logging/
│   ├── fluent-bit/values.yaml
│   ├── opensearch/{values.yaml,ism-policy.json}
│   └── opensearch-dashboards/values.yaml
├── security/
│   ├── zap/rules.tsv
│   └── dependency-check-suppression.xml
├── ci/                                # existing lint/template/validate/package scripts (reused)
├── sonar-project.properties
└── .github/workflows/
    ├── app-ci.yaml                    # test -> scan -> image -> ECR -> GitOps write-back
    ├── helm-ci.yaml                   # lint -> template -> kubeconform -> checkov -> Argo CD Git-sourced Helm deployment
    ├── terraform.yaml                 # fmt -> validate -> checkov -> plan -> gated apply
    └── dast-zap.yaml                  # nightly OWASP ZAP baseline
```

---

## 2. Infrastructure

### Modules

| Module | What it creates |
|---|---|
| `bootstrap` | Versioned, encrypted, public-access-blocked S3 state bucket + DynamoDB lock table |
| `vpc` | /16 VPC, public + private subnets per AZ, IGW, NAT (1 in dev / per-AZ in prod), route tables, S3 gateway endpoint, optional flow logs, ELB + karpenter subnet tags |
| `eks` | Control plane with secrets encryption and audit logs, OIDC provider, managed node group with a launch template (IMDSv2, encrypted gp3 root), `vpc-cni`/`coredns`/`kube-proxy`/`aws-ebs-csi-driver` add-ons, EBS CSI IRSA role |
| `ecr` | One repository per service, scan-on-push, KMS/AES encryption, lifecycle rules (keep N tagged, expire untagged), pull policy for the node role |
| `github-oidc` | GitHub OIDC provider (once per account) + a least-privilege CI role scoped to your `org/repo` and specific refs |
| `irsa` | Reusable IAM role trusted by one or more `namespace:serviceaccount` pairs |
| `security-groups` | ALB SG (80/443), node SG for ALB → pod traffic, optional datastore SG |
| `addons` | Helm-installed AWS Load Balancer Controller, External Secrets Operator, metrics-server, default gp3 StorageClass, ArgoCD |

### Commands

```bash
# 0. one-off: remote state
cd infrastructure/bootstrap
terraform init && terraform apply
# note the outputs, then put them in each environment's backend.tf

# 1. dev
cd ../environments/dev
terraform init
terraform plan  -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars

# 2. production (same, after dev is green)
cd ../production && terraform init && terraform apply -var-file=terraform.tfvars
```

### Validation

```bash
terraform fmt -recursive -check infrastructure
terraform -chdir=infrastructure/environments/dev validate
aws eks update-kubeconfig --region us-east-1 --name roboshop-dev
kubectl get nodes                       # 2 Ready
kubectl -n kube-system get deploy aws-load-balancer-controller metrics-server
kubectl -n external-secrets get pods
kubectl get storageclass                # gp3 (default)
kubectl top nodes                       # metrics-server working
```

---

## 3. CI pipeline (`.github/workflows/app-ci.yaml`)

Stages, in order: **checkout → detect changed services → install dependencies → unit test → build → SonarQube (SAST + quality gate) → OWASP Dependency-Check (SCA, fails at CVSS ≥ 8) → docker build → Trivy image scan (SARIF to GitHub Security, hard fail on CRITICAL) → push to ECR → GitOps write-back**.

- The `detect` job uses `dorny/paths-filter`, so a change to `apps/cart` builds only `cart`. This is the fix for the old `paths:` filters that ignored application code entirely.
- Language is auto-detected per service (Node 20, Java 17 + Maven, Python 3.11, or static), so one workflow covers all eight images.
- Images are tagged with the immutable commit SHA. Production ECR repositories are `IMMUTABLE`; dev also gets a moving `dev` tag.
- AWS access is keyless via GitHub OIDC (`AWS_OIDC_ROLE_ARN`), no long-lived access keys.
- The final job rewrites `charts/<svc>/values-<env>.yaml` (`image.repository`, `image.tag`) and `environments/<env>/global-values.yaml` (`image.registry`) with `yq`, then commits `[skip ci]`. **That commit is the deployment** - ArgoCD does the rest.

`helm-ci.yaml` runs `ci/lint.sh`, `ci/template.sh`, `ci/validate.sh` (kubeconform), Checkov against the charts, then packages every chart and pushes it to ECR as an OCI artifact from `main`.

`terraform.yaml` runs fmt/validate/Checkov on every PR, posts the plan as a PR comment for both environments, and exposes a manually dispatched `apply` gated by a GitHub Environment (add required reviewers on `production`).

### Validation

```bash
gh workflow run app-ci.yaml -f service=cart
gh run watch
aws ecr describe-images --repository-name roboshop/cart --query 'imageDetails[0].imageTags'
git log --oneline -1            # chore(deploy): dev -> <sha> [skip ci]
```

---

## 4. CD - ArgoCD

Three bugs from the review are fixed:

1. **`syncPolicy` was nested under `destination`** in all four root Applications, so nothing ever auto-synced. It is now a direct child of `spec`.
2. **Child Applications had no `automated` block.** The ApplicationSet template now sets `automated: {prune, selfHeal, allowEmpty:false}`.
3. **`valueFiles: ../../environments/...` escaped the chart directory** and is rejected by ArgoCD ≥ 2.6. Replaced with a multi-source Application: the chart from `path`, plus a second source with `ref: values`, referenced as `$values/environments/<env>/global-values.yaml`.

Structure: `AppProject` (roboshop + platform) → root Application per environment (app-of-apps) → `ApplicationSet` → 11 Applications, ordered by sync waves `-1` platform, `0` datastores, `1` microservices, `2` frontend. Namespaces are `roboshop-<env>`, matching the Terraform `app_namespace`. `preserveResourcesOnDeletion: true` means deleting an ApplicationSet never deletes running workloads, and `/spec/replicas` is ignored so ArgoCD does not fight the HPA.

### Commands

```bash
kubectl apply -f gitops/projects/
kubectl apply -f gitops/applications/root-platform.yaml
kubectl apply -f gitops/applications/root-dev.yaml
# production, after dev is healthy:
kubectl apply -f gitops/applications/root-production.yaml
```

### Validation

```bash
argocd app list
argocd app get roboshop-dev-root                     # Synced / Healthy
kubectl -n roboshop-dev get pods
argocd app history roboshop-dev-cart                 # a revision per CI write-back
kubectl -n roboshop-dev scale deploy/cart --replicas=7 && sleep 30
kubectl -n roboshop-dev get deploy cart              # self-heal reverts it
```

---

## 5. Security

| Tool | Where | Gate |
|---|---|---|
| SonarQube | `app-ci.yaml`, `sonar-project.properties` | quality gate blocks PRs |
| OWASP Dependency-Check | `app-ci.yaml` + `security/dependency-check-suppression.xml` | fails at CVSS ≥ 8 |
| Trivy | `app-ci.yaml` | SARIF to GitHub Security; hard fail on CRITICAL (fixed only) |
| Checkov | `helm-ci.yaml` (Helm) + `terraform.yaml` (Terraform), config in `ci/checkov.yaml` | fails the build |
| OWASP ZAP | `dast-zap.yaml`, rules in `security/zap/rules.tsv` | nightly baseline against dev, report artifact |

Nothing else was added - no Falco, Kyverno, OPA, Cosign, kube-bench. Secrets stay in AWS Secrets Manager and reach pods through External Secrets with an IRSA role scoped to `roboshop/<env>/*`.

---

## 6. Monitoring and logging

**Monitoring** - `kube-prometheus-stack` (Prometheus, Alertmanager, Grafana, node-exporter, kube-state-metrics) with 15-day retention on gp3, control-plane scrape jobs disabled for EKS, and cross-namespace ServiceMonitor discovery. `monitoring/rules/roboshop-alerts.yaml` ships 11 alerts across availability, traffic (5xx rate, p95 latency), resources (CPU throttling, memory near limit, PVC filling), datastores and cluster capacity. Alertmanager routes `critical` → Slack `#roboshop-incidents`, `warning` → Slack, `info` → dropped, with inhibition so a critical suppresses matching warnings.

**Logging** - Fluent Bit DaemonSet tails container logs, merges CRI multiline, enriches with Kubernetes metadata, drops health-check noise, and ships to OpenSearch as `roboshop-YYYY.MM.DD`. OpenSearch runs 3 nodes spread over AZs on 100 GB gp3; the ISM policy rolls over at 20 GB/1 day, force-merges at 7 days and deletes at 30. OpenSearch Dashboards is exposed through the shared ALB, and Grafana has OpenSearch registered as a datasource so metrics and logs sit side by side.

Both are delivered as ArgoCD Applications (`gitops/platform/`) with values in this repo, at sync waves `-20`/`-15`/`-14`/`-13` so they exist before the workloads.

### Validation

```bash
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/monitoring-grafana 3000:80
kubectl -n monitoring exec -it prometheus-monitoring-kube-prom-prometheus-0 -c prometheus -- \
  wget -qO- localhost:9090/api/v1/rules | head
kubectl -n logging get pods
kubectl -n logging exec -it opensearch-cluster-master-0 -- \
  curl -sk -u admin:$PW https://localhost:9200/_cat/indices/roboshop-*
```

---

## 7. How it integrates with the existing project

Nothing was recreated. The `common` library chart, the eleven service charts, the four-environment values model, the Dockerfiles and the `ci/*.sh` scripts are all reused as-is:

- `helm-ci.yaml` calls the existing `ci/lint.sh`, `ci/template.sh`, `ci/validate.sh` and `ci/checkov.yaml`.
- The CI write-back edits the chart values files that already existed - no new deployment mechanism.
- The ApplicationSet element list mirrors `environments/<env>/releases.yaml`, so waves stay in one shape.
- Terraform outputs feed straight into the existing config: `ecr_registry` → `environments/<env>/global-values.yaml` (`image.registry`), `github_actions_role_arn` → the `AWS_OIDC_ROLE_ARN` GitHub secret, `external_secrets_role_arn` → the ServiceAccount annotation used by the `platform` chart.

### Values you must set

1. `infrastructure/environments/*/backend.tf` - the S3 bucket name from `bootstrap`.
2. `infrastructure/environments/*/terraform.tfvars` - `github_org`, `github_repo`, region, `argocd_domain`.
3. Every `repoURL: https://github.com/your-org/roboshop.git` in `gitops/` - your repo.
4. GitHub secrets: `AWS_OIDC_ROLE_ARN`, `SONAR_HOST_URL`, `SONAR_TOKEN`, optionally `GITOPS_TOKEN`.

### Order of operations

```text
bootstrap -> dev infra -> gitops projects + root-platform -> root-dev
          -> app-ci pushes images and writes back -> ArgoCD syncs
          -> production infra -> root-production
```
