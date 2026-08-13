> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 11 — Prerequisites

Everything required **before** running a single command. Verify with `make prereqs-check`.

---

## 11.1 Local machine

| | Minimum | Recommended |
|---|---|---|
| OS | macOS 13 / Ubuntu 22.04 / Windows 11 + WSL2 | macOS 14 or Ubuntu 24.04 |
| CPU / RAM | 4 cores / 16 GB | 8 cores / 32 GB (kind + 11 charts is heavy) |
| Disk | 50 GB free | 100 GB SSD |
| Network | outbound 443 to AWS, GitHub, ECR, Docker Hub | — |

---

## 11.2 Software

| Tool | Version | Install | Why |
|---|---|---|---|
| git | ≥ 2.40 | `brew install git` | with `git-lfs` if you add binaries |
| Docker / Colima / Rancher | ≥ 24 (Buildx v0.14+) | `brew install docker docker-buildx` | multi-stage + multi-arch builds |
| kubectl | 1.35–1.36 (cluster ±1) | `brew install kubectl` | — |
| Helm | ≥ 3.16 | `brew install helm` | CI validation and Argo CD Git-sourced application packaging |
| helm plugins | `helm-diff`, `helm-unittest`, `helm-secrets` | `helm plugin install …` | `make diff`, chart tests |
| Terraform | ~> 1.9 (pin with `tfenv`) | `brew install tfenv && tfenv install 1.9.8` | IaC |
| tflint · tfsec · checkov | latest | `brew install tflint tfsec && pip install checkov` | IaC policy |
| AWS CLI | v2 ≥ 2.17 | `brew install awscli` | — |
| eksctl | ≥ 0.190 | `brew install eksctl` | break-glass / IRSA helpers only — Terraform is primary |
| kubeconform | ≥ 0.6.7 | `brew install kubeconform` | schema validation |
| argocd CLI | matches server | `brew install argocd` | `app wait`, `app diff` |
| yq · jq | latest | `brew install yq jq` | GitOps values/release manifest edits |
| kind or k3d | latest | `brew install kind` | local cluster |
| k9s · stern | latest | `brew install k9s stern` | quality of life |
| trivy · cosign · syft · gitleaks | latest | `brew install trivy cosign syft gitleaks` | supply chain |
| pre-commit | ≥ 3.7 | `pip install pre-commit && pre-commit install` | gate 1 |
| k6 | ≥ 0.53 | `brew install k6` | smoke + load tests |
| GNU Make | ≥ 4.3 | `brew install make` (macOS ships 3.81 — use `gmake`) | entry points |

**Language runtimes** (only for the services you touch):
Node.js **20 LTS** (`nvm install 20`) · Java **21** Temurin (`sdk install java 21-tem`) +
Maven 3.9 · Python **3.12** (`pyenv install 3.12`) + `pip`, `venv`.

```bash
# one-shot verification
make prereqs-check    # or:
for t in git docker kubectl helm terraform aws eksctl kubeconform argocd yq jq trivy cosign k6; do
  command -v "$t" >/dev/null && printf '✅ %-12s %s\n' "$t" "$($t version 2>&1|head -1)" \
                             || printf '❌ %-12s MISSING\n' "$t"
done
```

---

## 11.3 AWS services required

| Service | Purpose |
|---|---|
| IAM + IAM OIDC provider | roles, IRSA, GitHub federation |
| S3 | Terraform state, backups, ALB/CloudTrail logs, Loki chunks |
| DynamoDB | Terraform state locking |
| KMS | CMKs for state, EKS secrets, EBS, S3, Secrets Manager |
| VPC (subnets, IGW, NAT, RT, SG, endpoints, flow logs) | networking |
| EKS + managed node groups | the cluster |
| EC2 | nodes, EBS volumes, ALB |
| ECR | immutable container images |
| Secrets Manager | app credentials consumed by External Secrets |
| SSM Parameter Store | non-secret config + cross-layer outputs |
| Route53 | DNS zone + records via external-dns |
| ACM | TLS certificate for the ALB |
| CloudWatch (Logs, Metrics, Alarms, Container Insights) | control-plane logs, alarms |
| CloudTrail | audit trail |
| AWS Backup | EBS snapshot policies |
| GuardDuty · Security Hub · Config | *(recommended)* threat detection & compliance |
| WAFv2 | *(recommended)* ALB protection |

**Quotas to raise before you start:** EIPs per region (NAT ×3 + ALB), vCPU limit for the
instance family, EKS clusters per region, ECR repos, ALBs per region.

---

## 11.4 IAM permissions

**Bootstrap operator (human, one-time):** `AdministratorAccess` in a sandbox account, or a
scoped policy covering `s3:*`, `dynamodb:*`, `kms:*` on the state resources, plus
`iam:CreateOpenIDConnectProvider` and `iam:CreateRole/PutRolePolicy`.

**Three CI roles (OIDC, no static keys):**

| Role | Trust `sub` | Permissions |
|---|---|---|
| `roboshop-gha-ecr` | `repo:org/repo:ref:refs/heads/main` | `ecr:GetAuthorizationToken`, `BatchCheckLayerAvailability`, `PutImage`, `UploadLayerPart`, `InitiateLayerUpload`, `CompleteLayerUpload` on `roboshop/*` |
| `roboshop-gha-tf-plan` | `repo:org/repo:pull_request` | `ReadOnlyAccess` + `s3:GetObject/PutObject` on state + `dynamodb:GetItem/PutItem/DeleteItem` |
| `roboshop-gha-tf-apply` | `repo:org/repo:environment:production` | scoped write on the resource types Terraform manages |

**Cluster IRSA roles:** LB controller, EBS CSI, External Secrets, external-dns, cert-manager,
Cluster Autoscaler/Karpenter, backup job, Loki/Tempo S3 writers, kube-bench. One role per
service account, least privilege.

**Human access:** EKS Access Entries — devs `view` in `roboshop-dev`, SRE `edit`, break-glass
`cluster-admin` role that emits a CloudTrail alarm on assumption.

---

## 11.5 GitHub secrets

| Secret | Scope | Value |
|---|---|---|
| `AWS_OIDC_ECR_ROLE` | repo | role ARN |
| `AWS_OIDC_TF_PLAN_ROLE` | repo | role ARN |
| `AWS_OIDC_TF_APPLY_ROLE` | env: each | role ARN |
| `ARGOCD_AUTH_TOKEN` | env | project-scoped token (sync + get only) |
| `GITOPS_APP_ID` / `GITOPS_APP_PRIVATE_KEY` | repo | GitHub App used to open promotion PRs |
| `SLACK_WEBHOOK_URL` | repo | notifications |
| `SONAR_TOKEN` / `SEMGREP_APP_TOKEN` / `SNYK_TOKEN` | repo | optional scanners |
| `GITLEAKS_LICENSE` | repo | optional (org use) |

**No `AWS_ACCESS_KEY_ID`. No `KUBECONFIG`. Ever.**

## 11.6 GitHub variables

| Variable | Example |
|---|---|
| `AWS_REGION` | `ap-south-1` |
| `AWS_ACCOUNT_ID` | `123456789012` |
| `ECR_REGISTRY` | `123456789012.dkr.ecr.ap-south-1.amazonaws.com` |
| `CLUSTER_NAME_DEV` … `_PRODUCTION` | `roboshop-dev` … `roboshop-production` |
| `ARGOCD_SERVER` | `argocd.roboshop.example.com` |
| `BASE_URL_DEV` … `_PROD` | `https://roboshop.example.com` |
| `HELM_VERSION` / `KUBE_VERSION` / `TF_VERSION` | `v3.16.3` / `1.31` / `1.9.8` |

**Repository settings:** Environments `dev`/`qa`/`staging`/`production` with required
reviewers on staging+prod · branch protection on `main` (PR, CODEOWNERS, required checks,
linear history, signed commits) · Dependabot for npm/maven/pip/docker/github-actions ·
Secret scanning + push protection **on** · CodeQL default setup **on**.

---

## 11.7 Terraform backend (create before any `terraform init`)

```bash
export AWS_REGION=ap-south-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cd infrastructure/bootstrap
terraform init            # local state
terraform apply -var="region=$AWS_REGION"

# migrate bootstrap's own state into the bucket it just created
terraform init -migrate-state \
  -backend-config="bucket=roboshop-tfstate-$ACCOUNT_ID" \
  -backend-config="key=bootstrap/terraform.tfstate" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=roboshop-tf-locks" \
  -backend-config="encrypt=true"
```

Verify: bucket versioning **Enabled**, SSE-KMS **on**, public access **blocked**,
`prevent_destroy` present, DynamoDB table with `LockID` hash key and PITR enabled.

---

## 11.8 Pre-flight checklist

```text
[ ] AWS account + billing alerts + service quotas raised
[ ] Domain in Route53; ACM cert requested and DNS-validated
[ ] All CLI tools installed at the pinned versions (make prereqs-check green)
[ ] `aws sts get-caller-identity` returns the expected account
[ ] Terraform backend bootstrapped and state migrated
[ ] GitHub OIDC provider + three roles created
[ ] GitHub secrets, variables, environments and branch protection configured
[ ] Secrets Manager secret roboshop/<env>/app created with all 7 keys
[ ] pre-commit installed locally (`pre-commit install`)
[ ] Slack channel + webhook, Slack webhook
[ ] Cost budget + anomaly detection alarm configured
```

---

**Next:** [Phase 12 — Execution roadmap](./11-roadmap.md)
