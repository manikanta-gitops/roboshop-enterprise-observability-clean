> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 2 — Enterprise Repository Restructure

## 2.1 Current State

```text
roboshop_prod-dev/
├── cart/ catalogue/ user/ payment/ shipping/ frontend/   ← app source
├── mongodb/ mysql/                                        ← datastore images
├── charts/            ← 11 charts + common library
├── environments/      ← dev qa staging production
├── argocd/            ← projects, applications, applicationsets
├── ci/                ← 5 shell scripts
├── kubernetes.zip     ← committed archive (!)
├── debug/             ← debug Dockerfile
├── secrets-policy.json, clustersecretstore.yaml   ← loose infra files at root
├── docker-compose.yaml, Makefile
└── README.md DECISIONS.md INTERVIEW_GUIDE.md MODERNIZATION_NOTES.md
```

**Problem:** four independent lifecycles (application code, container images, Helm packaging,
GitOps desired-state) share one root and one commit history.

**Why it's a problem:**
- A `README.md` typo triggers the Helm CI; a `server.js` change triggers nothing.
- ArgoCD watches `HEAD` of the whole repo → every unrelated commit is a potential sync.
- Blast radius of a bad merge spans app + infra.
- You cannot give the app team write access without also giving them production desired-state.
- Helm charts under `charts/` are the single application packaging source; GitOps controls desired environment values.

**Industry Best Practice:** the **three-repo pattern** used at Google/Netflix/Uber scale:
`app` (source + build), `platform/infra` (Terraform + addons), `gitops` (desired state, the
only thing ArgoCD reads). CI writes into the gitops repo; **CD never runs `helm upgrade`**.

For a portfolio project you can keep it as a **monorepo with hard directory boundaries and
per-path CI** — but the boundaries must be real.

---

## 2.2 Target structure (monorepo variant — recommended for a portfolio)

```text
roboshop-platform/
│
├── apps/                                   # ── APPLICATION SOURCE ─────────
│   ├── catalogue/  { src/, tests/, Dockerfile, .dockerignore, package.json }
│   ├── user/
│   ├── cart/
│   ├── shipping/   { src/main/java, pom.xml, Dockerfile }
│   ├── payment/    { payment.py, rabbitmq.py, tests/, requirements.txt, Dockerfile }
│   └── frontend/   { static/, nginx.conf, Dockerfile }
│
├── infrastructure/                         # ── TERRAFORM (Phase 3) ────────
│   ├── bootstrap/                          # S3 + DynamoDB state backend (local state, run once)
│   ├── modules/
│   │   ├── vpc/ eks/ node-groups/ ecr/ iam-oidc/ irsa/
│   │   ├── route53/ acm/ kms/ secrets-manager/
│   │   ├── s3-backup/ cloudtrail/ cloudwatch/ waf/
│   └── environments/
│       ├── dev/       { main.tf backend.tf variables.tf terraform.tfvars outputs.tf }
│       ├── qa/
│       ├── staging/
│       └── production/
│
├── platform/                               # ── CLUSTER ADD-ONS (Helm-of-Helm)
│   ├── addons/
│   │   ├── aws-load-balancer-controller/
│   │   ├── ebs-csi-driver/  external-dns/  cert-manager/
│   │   ├── external-secrets/  metrics-server/  karpenter/
│   │   ├── kyverno/  gatekeeper/  falco/
│   │   └── argocd/                          # ArgoCD installs itself after bootstrap
│   └── bootstrap/
│       └── argocd-install.sh  root-app.yaml
│
├── charts/                                 # ── HELM PACKAGING (unchanged, it's good)
│   ├── common/       (library chart, semver-versioned, published to OCI)
│   ├── platform/     (namespace, quota, storageclass, ingress, netpol baseline)
│   └── catalogue/ user/ cart/ shipping/ payment/ frontend/
│       mongodb/ mysql/ redis/ rabbitmq/
│
├── gitops/                                 # ── DESIRED STATE (ArgoCD reads ONLY this)
│   ├── projects/            roboshop-appproject.yaml, platform-appproject.yaml
│   ├── bootstrap/           root-<env>.yaml            (app-of-apps)
│   ├── applicationsets/     roboshop-<env>.yaml, addons-<env>.yaml
│   └── environments/
│       ├── dev/       { global-values.yaml, images.yaml, releases.yaml }
│       ├── qa/
│       ├── staging/
│       └── production/
│
├── monitoring/                             # ── OBSERVABILITY (Phase 8) ────
│   ├── kube-prometheus-stack/  values-<env>.yaml
│   ├── loki/  fluent-bit/  tempo-or-jaeger/  opentelemetry-collector/
│   ├── dashboards/   *.json  (Grafana, provisioned as ConfigMaps)
│   └── rules/        recording-rules.yaml, alert-rules.yaml, slo.yaml
│
├── security/                               # ── DEVSECOPS (Phase 7) ────────
│   ├── policies/kyverno/       require-signed-images.yaml, disallow-latest.yaml …
│   ├── policies/gatekeeper/    constrainttemplates/, constraints/
│   ├── falco/                  rules-custom.yaml
│   ├── scanners/               trivy.yaml, semgrep.yml, .gitleaks.toml, checkov.yaml
│   └── compliance/             kube-bench-job.yaml, cis-evidence/
│
├── .github/
│   ├── workflows/
│   │   ├── app-ci.yaml            # matrix build/test/scan/push per service
│   │   ├── helm-ci.yaml            # lint/template/kubeconform/checkov
│   │   ├── release.yaml            # immutable image release + GitOps PR
│   │   ├── terraform-plan.yaml    # PR plan with comment
│   │   ├── terraform-apply.yaml   # environment-gated apply
│   │   ├── security-nightly.yaml  # Trivy repo scan, CodeQL, dep + license scan
│   │   └── drift-detect.yaml      # terraform plan -detailed-exitcode, argocd diff
│   ├── CODEOWNERS
│   └── dependabot.yml / renovate.json
│
├── automation/                             # ── SCRIPTS / MAKE ─────────────
│   ├── scripts/   bootstrap-cluster.sh, seed-secrets.sh, smoke-test.sh, restore-db.sh
│   ├── ci/        lint.sh template.sh validate.sh security-scan.sh package.sh
│   └── Makefile
│
├── docs/                                   # ── DOCUMENTATION (Phase 10) ───
│   ├── architecture/  { c4-context.md, c4-container.md, adr/0001-*.md }
│   ├── infrastructure.md  cicd.md  gitops.md  security.md  observability.md
│   ├── runbook.md  troubleshooting.md  disaster-recovery.md
│   ├── developer-guide.md  platform-guide.md  production-deployment.md
│   ├── prerequisites.md  roadmap.md  interview-guide.md
│   └── diagrams/  *.drawio / *.mmd
│
├── tests/
│   ├── smoke/         k6 or newman collections
│   ├── load/          k6 scenarios
│   └── helm/          helm-unittest suites + golden files
│
├── archive/                                # tombstoned legacy (or just delete)
│   └── kubernetes-raw-manifests/ + README-DEPRECATED.md
│
├── .gitignore  .editorconfig  .pre-commit-config.yaml
├── lovable/ n-a
└── README.md
```

---

## 2.3 Why every folder exists

| Folder | Why it exists (the interview answer) |
|---|---|
| `apps/` | Isolates the **application lifecycle**. Enables per-service path filters, per-service CODEOWNERS, per-service image tags, and independent release cadence. Also makes "extract to its own repo later" a `git filter-repo` away. |
| `infrastructure/bootstrap/` | The **chicken-and-egg** folder. You cannot store Terraform state in S3 before S3 exists. This one stack runs with local state, creates the S3 bucket + DynamoDB lock table, and is then migrated to remote state. Run once per account, ever. |
| `infrastructure/modules/` | Reusable, versioned, testable units. A module is the Terraform equivalent of the Helm library chart: write `vpc` once, call it four times with different CIDRs. Prevents the classic "prod drifted from dev because someone edited prod's inline resources". |
| `infrastructure/environments/` | **One state file per environment.** Isolation of blast radius: `terraform destroy` in dev can never touch prod state. Each has its own backend key, its own tfvars, its own IAM role. |
| `platform/addons/` | Cluster capabilities that are **not** your application but are required for it to run (LB controller, CSI, ESO, autoscaler, cert-manager). Separated because they upgrade on the *cluster's* cadence, not the app's, and because they are installed by ArgoCD *before* wave 0 of the apps. |
| `charts/` | Packaging only. A chart says *how to render*, never *what version is deployed where* — that lives in `gitops/`. This split is what lets you re-render an old chart with new values, and vice versa. |
| `gitops/` | The **single source of truth for desired state** and the only path ArgoCD is allowed to read. Every production change is a PR into this folder → free audit trail, free approval gate, free rollback (`git revert`). |
| `monitoring/` | Observability is a first-class deliverable, not an afterthought bolted into a chart. Kept separate so SREs own it via CODEOWNERS and it can be deployed to a cluster with zero apps. |
| `security/` | Policy-as-code + scanner config in one auditable place. When an auditor asks "prove you enforce non-root", you point at `security/policies/kyverno/require-non-root.yaml` and the Kyverno PolicyReport. |
| `.github/workflows/` | Automation, split by **trigger and blast radius**, not by convenience. App CI ≠ Helm CI ≠ Terraform apply — different permissions, different approvers, different OIDC roles. |
| `automation/` | Human ergonomics. `make dev-up` should work on day one for a new joiner. Also where CI scripts live so CI and local run **exactly the same code** (no logic inside YAML). |
| `docs/` | Documentation-as-code, versioned with the thing it documents. ADRs capture *why*, runbooks capture *what to do at 3am*. |
| `tests/` | Smoke and load tests belong to the platform, not to any one service, because they exercise the **integration** (ALB → frontend → cart → redis). |
| `archive/` | Explicit tombstone. Deleting is better; if you must keep it, mark it dead loudly so no one applies it. |

---

## 2.4 Migration plan (safe, incremental, reversible)

```bash
# 1. Kill the shadow copy first — it is the biggest correctness risk.
The legacy Kubernetes/Kustomize tree is removed; do not reintroduce a second application manifest source.
git rm -r --cached payment/__pycache__ && echo "__pycache__/" >> .gitignore
echo "*.pyc\ndist/\nci/_rendered/\n.terraform/\n*.tfstate*" >> .gitignore

# 2. Move app source under apps/ (history preserved).
mkdir apps && for s in cart catalogue user payment shipping frontend; do git mv $s apps/$s; done
git mv mongodb apps/mongodb-init && git mv mysql apps/mysql-init

# 3. Split gitops out of argocd/ + environments/
mkdir -p gitops/{projects,bootstrap,applicationsets,environments}
git mv argocd/projects/*            gitops/projects/
git mv argocd/applications/*        gitops/bootstrap/
git mv argocd/applicationsets/*     gitops/applicationsets/
git mv environments/*               gitops/environments/

# 4. Automation
mkdir -p automation && git mv ci automation/ci && git mv Makefile automation/Makefile

# 5. Create the empty-but-committed skeletons so the structure is self-documenting
mkdir -p infrastructure/{bootstrap,modules,environments} platform/addons \
         monitoring security docs tests
```

Then update: `ci/*.sh` paths, both workflows' `paths:` filters, the ArgoCD `path:` fields, and
the README tree. Do this in **one PR labelled `chore: repo restructure`, no behaviour change** —
never mix a move with a semantic change.

---

## 2.5 Enforcement (structure only survives if it's enforced)

**`.github/CODEOWNERS`**
```text
/apps/                @roboshop/app-engineers
/charts/              @roboshop/platform-engineering
/gitops/environments/production/  @roboshop/platform-leads @roboshop/sre
/infrastructure/      @roboshop/cloud-architects
/security/            @roboshop/security
/monitoring/          @roboshop/sre
```

**Branch protection on `main`:** require PR, 1+ owner approval, all required checks green,
linear history, signed commits, no force-push. Production values require **2** approvals.

**`.pre-commit-config.yaml`:** `gitleaks`, `terraform fmt`, `tflint`, `helm lint`,
`yamllint`, `shellcheck`, `check-added-large-files` (catches the next `kubernetes.zip`).

---

**Next:** [Phase 3 — Terraform](./02-terraform.md)
