> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 14 — Operational Practices

Everything here is the "boring" layer a real team leans on after the platform
works: retention, state safety, environment gates, smoke tests, notifications,
backup/restore, and ownership. No new products were introduced — each item
reuses what the platform already runs (ECR, Terraform, GitHub, AWS Backup,
Slack).

---

## 1. Registry retention

| Artifact | Repository | Rule |
| --- | --- | --- |
| Service images | `roboshop/<service>` | keep last 50 (prod) / 15 (dev) tagged releases; untagged expire after 7 days |

Helm charts are intentionally **not** stored in ECR. Argo CD consumes the
version-controlled charts directly from Git, so there is no second chart registry
or second application packaging source to keep synchronized.

---

## 2. Terraform state and the plan/apply workflow

- **Remote state**: S3 bucket per account, one key per environment
  (`dev/terraform.tfstate`, `production/terraform.tfstate`), SSE enabled,
  DynamoDB table `roboshop-tf-locks` for locking. Provisioned by
  `infrastructure/bootstrap`.
- **Locking**: every `init`, `plan` and `apply` passes `-lock-timeout=5m`, so a
  concurrent run waits instead of failing.
- **Plan on PR**: `terraform plan -detailed-exitcode` runs for both
  environments and is posted as a PR comment. Exit code `2` means "changes
  pending", which is information, not failure.
- **Apply**: `workflow_dispatch` only, gated by the GitHub Environment for that
  stack. The apply job plans and applies **the same plan file** in one run, so
  the change the approver saw is the change that lands.
- **Drift detection**: a weekday `schedule` plan runs against real state. Exit
  code `2` on a scheduled run raises a workflow warning and a Slack message.

---

## 3. GitHub environment protection

`./scripts/setup-environments.sh <owner/repo> [team]` creates:

| Environment | Wait timer | Reviewers | Branch policy |
| --- | --- | --- | --- |
| `dev` | — | — | any |
| `qa` | — | — | any |
| `staging` | 5 min | — | any |
| `production` | 5 min | platform team, self-review blocked | protected branches only |

The `promote` and `terraform` jobs both declare `environment:`, so these rules
apply automatically — there is no way to reach production without passing them.

---

## 4. Environment-specific secrets

Two levels, on purpose:

- **Environment-scoped** — different value per environment, never visible to
  another one: `AWS_OIDC_ROLE_ARN` (points at
  `roboshop-<env>-github-actions`), `SMOKE_BASE_URL`.
- **Repository-scoped** — same value everywhere and not environment-sensitive:
  `SLACK_WEBHOOK_URL`, `SONAR_TOKEN`, `GITOPS_TOKEN`.

Runtime application secrets are *not* GitHub secrets. They live in AWS Secrets
Manager under `roboshop/<env>/…` and reach pods through External Secrets with
an IRSA role scoped to that prefix, so the dev cluster cannot read production
secrets even if it tried.

```bash
gh secret set AWS_OIDC_ROLE_ARN --env production --body 'arn:aws:iam::…:role/roboshop-production-github-actions'
gh secret set SMOKE_BASE_URL    --env production --body 'https://roboshop.example.com'
```

---

## 5. Post-deployment smoke tests

`scripts/smoke-test.sh <base-url> [version]` runs at the end of every
promotion, after a short sync wait:

1. Polls `/` until it returns `200` (ArgoCD may still be rolling pods).
2. Checks the health endpoint of every service plus one real data path
   (`/api/catalogue/categories`).
3. Optionally asserts the served version equals the promoted version.

A failure fails the promotion job, fires a Slack alert with the rollback
command, and stops the version from being promoted onward — the promotion gate
requires the previous environment to be running that exact version.

---

## 6. Release and deployment notifications

Slack incoming webhook (`SLACK_WEBHOOK_URL`), one message per meaningful event:

| Workflow | Message |
| --- | --- |
| `release` | version published, source commit, link to release notes |
| `promote` | environment, version, status, actor, rollback hint on failure |
| `terraform` | apply result; drift warning on the scheduled plan |

Every step is `if: always() && secrets.SLACK_WEBHOOK_URL != ''`, so the
platform works unchanged without Slack configured.

---

## 7. Backup and restore

**What is backed up.** Only stateful data: the EBS volumes behind MongoDB,
MySQL, Redis and RabbitMQ. Everything else (manifests, charts, images) is
already reproducible from Git and ECR.

**How.** AWS Backup — managed, nothing to run in-cluster:

- Vault + plan + IAM role in `infrastructure/modules/backup`.
- Daily at 01:00 UTC, retained 7 days; weekly Sunday 02:00 UTC, retained 30 days.
- Selection by tag `backup=daily`, which the production `gp3` StorageClass
  stamps on every volume it provisions (`tagSpecification_1`).
- Production volumes use `reclaimPolicy: Retain`, so deleting a PVC never
  deletes the data.

**RPO / RTO.** RPO 24 h, RTO ~30 min per volume.

**Restore runbook.**

```bash
# 1. Find the recovery point
aws backup list-recovery-points-by-backup-vault \
  --backup-vault-name roboshop-production \
  --query 'RecoveryPoints[?contains(ResourceArn,`volume`)].[RecoveryPointArn,CreationDate]' --output table

# 2. Restore it to a new EBS volume in the AZ of the target node
aws backup start-restore-job \
  --recovery-point-arn <arn> \
  --iam-role-arn <backup_role_arn> \
  --resource-type EBS \
  --metadata availabilityZone=us-east-1a,volumeType=gp3,encrypted=true

# 3. Scale the datastore down, swap the volume in, scale back up
kubectl -n roboshop-production scale statefulset mongodb --replicas=0
#    create a PV pointing at the restored volumeHandle, bind the PVC to it
kubectl -n roboshop-production apply -f restored-pv.yaml
kubectl -n roboshop-production scale statefulset mongodb --replicas=1

# 4. Verify, then run the smoke test
./scripts/smoke-test.sh https://roboshop.example.com
```

**Test it quarterly** by restoring a production recovery point into the dev
cluster. An untested backup is not a backup.

---

## 8. Branch protection and repository ownership

`./scripts/setup-branch-protection.sh <owner/repo>` enforces on `main`:

- required status checks (helm lint/template/kubeconform, checkov, terraform
  validate), strict — branches must be up to date
- 1 approving review, stale reviews dismissed, **code owner review required**
- linear history, no force pushes, no deletions, conversations resolved
- a ruleset blocking deletion and update of `v*` tags

`.github/CODEOWNERS` assigns platform surfaces (infrastructure, gitops,
workflows, charts/common, monitoring, logging, security, scripts, releases,
docs) to the platform team, and each service directory to the team that owns
it. Combined with code-owner review, a change to the deploy pipeline cannot
merge without platform approval.

---

## Run order for a fresh repository

```bash
./scripts/setup-branch-protection.sh your-org/roboshop
./scripts/setup-environments.sh      your-org/roboshop platform-engineering
# then set the environment secrets the script prints
```
