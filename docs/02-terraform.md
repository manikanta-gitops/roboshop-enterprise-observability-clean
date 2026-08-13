> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 3 — Terraform / Infrastructure as Code Roadmap

> **Current State: there is no Terraform in this repository.** The Helm charts assume an EKS
> cluster with the AWS Load Balancer Controller, EBS CSI driver, metrics-server, External
> Secrets Operator, a `gp3` StorageClass, IRSA, ACM certs and Route53 records — none of which
> is codified. **Score: 1/10.** Everything below the cluster is click-ops with a bus factor of 1.
>
> **Why it's a problem:** you cannot rebuild after a region incident, you cannot prove
> compliance, you cannot review an infra change, you cannot spin up an identical QA account,
> and you cannot answer "how is this cluster configured?" without opening the console.

This phase assumes **nothing exists** and builds the whole account from zero.

---

## 3.1 Layered architecture (state boundaries)

State files are the unit of blast radius. Use **five layers**, each with its own state key:

| Layer | State key | Change cadence | Destroy risk |
|---|---|---|---|
| 0 · bootstrap | *local → migrated* | once, ever | catastrophic |
| 1 · foundation | `foundation/<env>/terraform.tfstate` | quarterly | high (VPC, KMS, Route53) |
| 2 · platform | `platform/<env>/terraform.tfstate` | monthly | high (EKS, node groups) |
| 3 · addons | `addons/<env>/terraform.tfstate` | monthly | medium (IRSA, helm addons) |
| 4 · workload-support | `workload/<env>/terraform.tfstate` | weekly | low (ECR, Secrets, S3 backups) |

Layers read each other with `terraform_remote_state` (or better: **SSM Parameter Store
outputs**, which decouples you from state-file schemas).

---

## 3.2 Folder layout

```text
infrastructure/
├── bootstrap/                       # LAYER 0 — run once per AWS account
│   ├── main.tf                      # S3 state bucket, DynamoDB lock table, KMS CMK
│   ├── variables.tf outputs.tf
│   └── README.md                    # "run with local state, then migrate"
│
├── modules/
│   ├── vpc/                 # VPC, subnets, IGW, NAT, RT, flow logs
│   ├── kms/                 # CMKs: eks-secrets, ebs, s3, secretsmanager, logs
│   ├── iam-github-oidc/     # GitHub OIDC provider + per-repo deploy roles
│   ├── ecr/                 # repo per service, scan-on-push, lifecycle, immutable tags
│   ├── eks/                 # control plane, OIDC provider, access entries, logging
│   ├── eks-node-group/      # managed node groups (on-demand + spot)
│   ├── irsa/                # generic "role for service account" module
│   ├── eks-addons/          # helm_release for LBC, CSI, ESO, metrics, autoscaler
│   ├── route53/  acm/
│   ├── secrets-manager/  ssm-parameters/
│   ├── s3-backup/  cloudtrail/  cloudwatch/  guardduty-config/
│   └── waf/
│
└── environments/
    ├── dev/  qa/  staging/  production/
    │   ├── backend.tf  providers.tf  main.tf
    │   ├── variables.tf  terraform.tfvars  outputs.tf
    │   └── .terraform.lock.hcl        # COMMITTED
```

**Why modules + environments (and not workspaces):** workspaces share one backend key and one
provider config; a `terraform workspace select prod` typo destroys production. Separate
directories give separate state, separate IAM roles, separate CI jobs, separate approvers.

---

## 3.3 Layer 0 — Backend bootstrap (S3 + DynamoDB + KMS)

```hcl
# infrastructure/bootstrap/main.tf
terraform {
  required_version = "~> 1.9"
  required_providers { aws = { source = "hashicorp/aws", version = "~> 5.70" } }
}

resource "aws_kms_key" "tfstate" {
  description             = "Terraform state encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "roboshop-tfstate-${data.aws_caller_identity.this.account_id}"
  # NEVER add force_destroy = true
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }   # your state "undo" button
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "roboshop-tf-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute { name = "LockID"  type = "S" }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
  lifecycle { prevent_destroy = true }
}
```

Then in every environment:

```hcl
# infrastructure/environments/production/backend.tf
terraform {
  backend "s3" {
    bucket         = "roboshop-tfstate-123456789012"
    key            = "platform/production/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "roboshop-tf-locks"   # state LOCKING — prevents two applies racing
    encrypt        = true
    kms_key_id     = "arn:aws:kms:ap-south-1:123456789012:key/…"
  }
}
```

> **State locking, explained for interviews:** Terraform writes a `LockID` item to DynamoDB
> before mutating state and deletes it after. A second `apply` sees the item and refuses.
> Without it, two concurrent CI runs interleave writes and you get a corrupted state file with
> resources Terraform no longer knows it owns. `terraform force-unlock <id>` is the break-glass —
> use it only when you have *proven* the other run is dead.

---

## 3.4 Layer 1 — Foundation: VPC, subnets, NAT, routing

```hcl
module "vpc" {
  source = "../../modules/vpc"

  name = "roboshop-production"
  cidr = "10.0.0.0/16"                # /16 → room for 3 AZ × (public /24 + private /19)
  azs  = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]

  public_subnets   = ["10.0.0.0/24",  "10.0.1.0/24",  "10.0.2.0/24"]   # ALB + NAT only
  private_subnets  = ["10.0.32.0/19", "10.0.64.0/19", "10.0.96.0/19"]  # nodes + pods
  database_subnets = ["10.0.8.0/24",  "10.0.9.0/24",  "10.0.10.0/24"]  # RDS/Elasticache later

  enable_nat_gateway = true
  single_nat_gateway = false          # production: one NAT PER AZ (see note)
  one_nat_gateway_per_az = true

  enable_dns_hostnames = true
  enable_dns_support   = true
  enable_flow_log      = true         # to CloudWatch/S3 — required for forensics

  # Required so the LB controller and Karpenter can discover subnets:
  public_subnet_tags  = { "kubernetes.io/role/elb"          = "1"
                          "kubernetes.io/cluster/roboshop-production" = "shared" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1"
                          "karpenter.sh/discovery"          = "roboshop-production" }
}
```

**Design decisions to be able to defend:**

- **Public subnets hold only the ALB and NAT gateways.** No node ever gets a public IP.
- **One NAT per AZ in production** (~$32/mo each + data): a single NAT is a **cross-AZ SPOF
  and a cross-AZ data-transfer bill**. In dev use `single_nat_gateway = true` to save money —
  that is a deliberate, documented environment difference.
- **VPC endpoints** (Gateway for S3/DynamoDB — free; Interface for ECR api/dkr, STS,
  Secrets Manager, CloudWatch Logs) cut NAT data-processing cost dramatically because every
  image pull otherwise traverses NAT. This is the #1 EKS cost surprise.
- **Route tables:** public RT → `0.0.0.0/0` via IGW. Each private RT → `0.0.0.0/0` via that
  AZ's NAT. Keeping them per-AZ is what makes `one_nat_gateway_per_az` actually work.
- **Flow logs on** — you cannot investigate an exfiltration without them.

**Security groups (least privilege, referenced not CIDR'd):**

| SG | Ingress | Egress |
|---|---|---|
| `alb-sg` | 443 from `0.0.0.0/0` (via WAF), 80 → redirect | node-sg on 30000-32767 / pod ports |
| `node-sg` | from `alb-sg`, from `cluster-sg` (443, 10250), self (all — pod-to-pod) | 443 to `cluster-sg`, 443 world (ECR/API) |
| `cluster-sg` | 443 from `node-sg` | 10250 to `node-sg` |
| `vpce-sg` | 443 from `node-sg` | — |

Always reference the **source security group**, never a CIDR, for intra-VPC rules.

---

## 3.5 Layer 1 — IAM, GitHub OIDC, KMS

**Why OIDC:** long-lived `AWS_ACCESS_KEY_ID` secrets in GitHub are the most common cloud
breach vector in CI. OIDC issues a **15-minute STS token**, scoped to a specific repo,
branch/environment, and role. Nothing to rotate, nothing to leak.

```hcl
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "gha_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals { type = "Federated", identifiers = [aws_iam_openid_connect_provider.github.arn] }
    condition { test = "StringEquals" variable = "token.actions.githubusercontent.com:aud"
                values = ["sts.amazonaws.com"] }
    # Scope tightly: only this repo, only the production environment.
    condition { test = "StringLike"  variable = "token.actions.githubusercontent.com:sub"
                values = ["repo:roboshop/roboshop-platform:environment:production"] }
  }
}
```

> **Interview trap:** scoping `sub` to `repo:org/repo:*` lets *any branch in any fork PR* assume
> the role. Always scope to `:environment:<env>` or `:ref:refs/heads/main`.

Create **three** roles, not one:
`roboshop-gha-ecr-push` (ECR only), `roboshop-gha-terraform-plan` (ReadOnly + state),
`roboshop-gha-terraform-apply` (scoped write, gated by a GitHub Environment with reviewers).

**KMS CMKs** (customer-managed, `enable_key_rotation = true`): one each for EKS secret
envelope encryption, EBS volumes, S3 (state + backups + logs), Secrets Manager, CloudWatch
Logs. Separate keys = separate key policies = separate revocation.

---

## 3.6 Layer 2 — EKS + managed node groups

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "roboshop-production"
  cluster_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_public_access_cidrs = var.admin_cidrs   # NOT 0.0.0.0/0
  cluster_endpoint_private_access      = true

  # Envelope-encrypt Kubernetes Secrets with your own CMK.
  cluster_encryption_config = { resources = ["secrets"], provider_key_arn = module.kms.eks_arn }

  # Ship every control-plane log type — mandatory for audit/forensics.
  cluster_enabled_log_types = ["api","audit","authenticator","controllerManager","scheduler"]

  authentication_mode = "API"          # EKS Access Entries; aws-auth ConfigMap is legacy
  access_entries = {
    platform_admin = {
      principal_arn = aws_iam_role.platform_admin.arn
      policy_associations = { admin = {
        policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
        access_scope = { type = "cluster" } } }
    }
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni    = { most_recent = true, before_compute = true
                   configuration_values = jsonencode({ env = {
                     ENABLE_PREFIX_DELEGATION = "true"   # ~4× more pods/node
                     WARM_PREFIX_TARGET       = "1" } }) }
    aws-ebs-csi-driver = { most_recent = true, service_account_role_arn = module.irsa_ebs.arn }
    eks-pod-identity-agent = { most_recent = true }
  }

  eks_managed_node_groups = {
    # System pool: CoreDNS, ArgoCD, controllers. On-demand, tainted, never Spot.
    system = {
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      min_size = 3  max_size = 6  desired_size = 3
      labels = { workload = "system" }
      taints = [{ key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }]
    }
    # App pool: matches the charts' nodeSelector workload=roboshop + toleration.
    roboshop = {
      instance_types = ["m6i.xlarge", "m6a.xlarge", "m5.xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size = 3  max_size = 12  desired_size = 3
      labels = { workload = "roboshop" }
      taints = [{ key = "workload", value = "roboshop", effect = "NO_SCHEDULE" }]
    }
    # Spot pool for stateless/batch — up to 70% cheaper. Diversify instance types!
    spot = {
      instance_types = ["m6i.xlarge","m6a.xlarge","m5.xlarge","m5a.xlarge","m5n.xlarge"]
      capacity_type  = "SPOT"
      min_size = 0  max_size = 20  desired_size = 2
      labels = { workload = "spot", "node.kubernetes.io/lifecycle" = "spot" }
      taints = [{ key = "spot", value = "true", effect = "NO_SCHEDULE" }]
    }
  }
}
```

**Why three pools:** you never want a Spot reclamation to take CoreDNS or the ArgoCD
application-controller with it, and you never want a noisy app pod co-scheduled with the
control-plane-adjacent add-ons. Taints make placement explicit rather than accidental.

**Node group vs Karpenter:** managed node groups are simpler and interview-safe; Karpenter is
the 2024+ answer (bin-packs to the exact instance shape in ~40s, consolidates continuously,
handles Spot interruption natively). Recommended end state: **managed NG for `system`,
Karpenter NodePools for everything else.**

---

## 3.7 Layer 3 — Add-ons and IRSA

Each add-on = one IRSA role + one `helm_release`. **Deploy order matters.**

| # | Add-on | IRSA policy | Why |
|---|---|---|---|
| 1 | `metrics-server` | none | **Your HPAs do not work without it** — every `autoscaling.enabled: true` in your charts is a no-op today |
| 2 | `aws-load-balancer-controller` | `AWSLoadBalancerControllerIAMPolicy` | Turns your `platform` chart's ALB Ingress into a real ALB |
| 3 | `aws-ebs-csi-driver` | `AmazonEBSCSIDriverPolicy` + KMS | Backs every `gp3` PVC in your StatefulSets |
| 4 | `external-secrets` | `secretsmanager:GetSecretValue` on `roboshop/*` | Materialises `roboshop-secrets`; your charts already reference it |
| 5 | `cluster-autoscaler` *or* `karpenter` | ASG describe/set-desired | HPA scales pods; **something must scale nodes** |
| 6 | `external-dns` | Route53 `ChangeResourceRecordSets` on the zone | Auto-creates `roboshop.example.com → ALB` |
| 7 | `cert-manager` | Route53 DNS-01 | Internal TLS / mTLS; ACM covers the ALB edge |
| 8 | `kyverno` | none | Runtime admission enforcement (Phase 7) |
| 9 | `kube-prometheus-stack`, `loki`, `fluent-bit`, `tempo` | CloudWatch/S3 write | Phase 8 |
| 10 | `argocd` | none (or ECR read for OCI charts) | Installed last; then it manages 8–9 itself |

```hcl
module "irsa_external_secrets" {
  source            = "../../modules/irsa"
  cluster_oidc_arn  = module.eks.oidc_provider_arn
  namespace         = "external-secrets"
  service_account   = "external-secrets"
  policy_json       = data.aws_iam_policy_document.eso.json
}

data "aws_iam_policy_document" "eso" {
  statement {
    actions   = ["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"]
    resources = ["arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:roboshop/${var.env}/*"]
  }
  statement { actions = ["kms:Decrypt"], resources = [module.kms.secrets_arn] }
}
```

> **Fix for finding S11:** today all 11 charts share one `roboshop` ServiceAccount. Give each
> service its own SA + its own IRSA role so `catalogue` cannot read `payment`'s AMQP credentials.

---

## 3.8 Layer 4 — ECR, Route53, ACM, Secrets, backups, audit

```hcl
module "ecr" {
  source   = "../../modules/ecr"
  for_each = toset(["catalogue","user","cart","shipping","payment","frontend","charts"])

  name                 = "roboshop/${each.key}"
  image_tag_mutability = "IMMUTABLE"          # fixes finding W8: a tag can never be re-pointed
  scan_on_push         = true                 # ECR basic/enhanced (Inspector) scanning
  encryption_type      = "KMS"
  kms_key              = module.kms.ecr_arn

  lifecycle_rules = [
    { description = "keep last 30 release images", tagPrefixList = ["v"], countNumber = 30 },
    { description = "expire untagged after 7 days", tagStatus = "untagged", sinceDays = 7 },
  ]
}
```

- **Route53:** public hosted zone `roboshop.example.com`; `external-dns` writes records.
  Health checks + failover records if you go multi-region.
- **ACM:** DNS-validated wildcard `*.roboshop.example.com` in the ALB's region; ARN feeds
  `alb.ingress.kubernetes.io/certificate-arn`. Auto-renews — no cert expiry pages.
- **Secrets Manager:** one secret per env, `roboshop/<env>/app`, holding exactly the keys your
  README lists (`JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`, `MYSQL_ROOT_PASSWORD`, `AMQP_*`,
  `RABBITMQ_DEFAULT_*`). Enable **automatic rotation** with a Lambda; KMS-encrypted; a
  resource policy limiting `GetSecretValue` to the ESO IRSA role only.
- **Parameter Store:** non-secret config + **cross-layer outputs** (cluster name, VPC id, ECR
  URLs). Free, versioned, and avoids `terraform_remote_state` coupling.
- **CloudTrail:** org-wide multi-region trail → dedicated S3 bucket with Object Lock
  (WORM), log-file validation on, KMS-encrypted. **Never in the same account as workloads** if
  you can help it.
- **CloudWatch:** control-plane logs, Container Insights, log group retention (30d dev / 400d
  prod), metric filters + alarms (see Phase 8).
- **Backups (fixes W6/DR):** AWS Backup plan targeting EBS volumes by tag
  (`Backup=roboshop`), daily 03:00 UTC, 35-day retention, **copy to a second region**; plus
  `VolumeSnapshotClass` + a `VolumeSnapshot` CronJob for K8s-native restore; plus logical
  dumps (`mysqldump`, `mongodump`) to a versioned S3 bucket with lifecycle → Glacier.

---

## 3.9 Variables, outputs, and conventions

```hcl
# variables.tf — always typed, always described, validated where it matters
variable "environment" {
  type        = string
  description = "Deployment environment"
  validation {
    condition     = contains(["dev","qa","staging","production"], var.environment)
    error_message = "environment must be one of dev|qa|staging|production."
  }
}

variable "cluster_version" { type = string  default = "1.31" }
variable "node_desired"    { type = number  default = 3 }

# providers.tf — tag EVERYTHING once, centrally
provider "aws" {
  region = var.region
  default_tags { tags = {
    Project     = "roboshop"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "platform-engineering"
    CostCenter  = "platform"
    Repository  = "roboshop-platform"
  }}
}

# outputs.tf — publish to SSM so downstream layers/CI never parse state
output "cluster_name"     { value = module.eks.cluster_name }
output "cluster_endpoint" { value = module.eks.cluster_endpoint }
output "oidc_provider_arn"{ value = module.eks.oidc_provider_arn }
output "ecr_registry"     { value = "${data.aws_caller_identity.this.account_id}.dkr.ecr.${var.region}.amazonaws.com" }
output "kubeconfig_cmd" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}
```

**Best practices checklist:**

- ✅ Pin `required_version` and every provider with `~>`; **commit `.terraform.lock.hcl`**.
- ✅ `prevent_destroy` on state bucket, lock table, KMS keys, prod data stores.
- ✅ Never `terraform apply` from a laptop against production — CI with OIDC only.
- ✅ `terraform plan` on PR (posted as a comment), `apply` behind a GitHub Environment reviewer.
- ✅ `tflint` + `tfsec`/`Checkov` + `terraform fmt -check` + `terraform validate` in CI.
- ✅ **Nightly drift detection:** `terraform plan -detailed-exitcode`; exit `2` → alert.
- ✅ No hardcoded account IDs/ARNs — `data.aws_caller_identity`, `data.aws_region`.
- ✅ No secrets in `.tfvars`; read from Secrets Manager/SSM data sources.
- ✅ Keep modules small and single-purpose; version them with Git tags (`?ref=v1.4.0`).
- ✅ `moved {}` blocks when refactoring — never `state rm` + `state import` by hand if avoidable.

---

## 3.10 Deployment order (and *why* each dependency exists)

```text
 0. bootstrap        S3 + DynamoDB + KMS         local state → then `terraform init -migrate-state`
 1. iam-github-oidc  OIDC provider + roles       CI cannot authenticate before this exists
 2. kms              CMKs                        EKS/EBS/S3 encryption references them
 3. vpc              subnets, IGW, NAT, RT, SG   EKS needs subnet IDs
 4. route53 + acm    zone + wildcard cert        ACM validation needs the zone; ALB needs the cert
 5. ecr              repos                       CI must have somewhere to push before app CI runs
 6. eks              control plane + OIDC        needs VPC; emits the OIDC provider IRSA depends on
 7. node groups      system / app / spot         needs the cluster
 8. irsa roles       per-addon, per-service      needs the cluster OIDC provider ARN
 9. core addons      metrics-server → LBC → EBS CSI → ESO → autoscaler → external-dns → cert-manager
10. secrets manager  roboshop/<env>/app          ESO must exist to consume it (order 9 ↔ 10 is flexible)
11. observability    prometheus, loki, tempo     wants storage classes + IRSA for S3
12. security addons  kyverno, falco, gatekeeper  install BEFORE workloads so policies apply from day 0
13. argocd           GitOps controller           installed last in Terraform, then owns 9/11/12
14. root app-of-apps kubectl apply once          hands over to Phase 5
```

**Golden rule:** Terraform's job ends at "a cluster that can run ArgoCD." Everything after
step 13 is Git's job. Do **not** manage application Helm releases with `helm_release` in
Terraform — you would have two reconcilers fighting over the same objects.

---

## 3.11 Cost estimate (ap-south-1, order of magnitude)

| Item | dev | production |
|---|---:|---:|
| EKS control plane | $73 | $73 |
| Nodes | 2 × t3.large ≈ $120 | 3 × m6i.large + 3 × m6i.xlarge ≈ $700 |
| NAT Gateway | 1 × $32 + data | 3 × $32 + data ≈ $150 |
| ALB | $18 | $25 |
| EBS gp3 | ~$10 | ~$60 |
| Backups / snapshots | $2 | $40 |
| CloudWatch logs | $5 | $60 |
| **≈ total / month** | **~$260** | **~$1,100** |

Levers: Spot for stateless (−60% on that pool), VPC endpoints (kills NAT data charges),
`single_nat_gateway` in dev, Graviton (`m7g`) for ~20% off, Savings Plans on the baseline.

---

**Next:** [Phase 4 — Kubernetes](./03-kubernetes.md)
