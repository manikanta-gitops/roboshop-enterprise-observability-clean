> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 12 — Execution Roadmap

Twelve phases, each with **Goal · Tasks · Expected Output · Validation · Interview Questions ·
Common Mistakes · Best Practices**. Estimated 10–12 weeks part-time.

---

## Phase 1 — Foundation & Infrastructure *(week 1–2)*

**Goal.** An empty AWS account becomes a 3-AZ VPC with remote Terraform state, OIDC, and KMS.

**Tasks.** Bootstrap S3+DynamoDB+KMS → migrate state → GitHub OIDC provider + 3 roles →
`modules/vpc` (public/private/db subnets, IGW, NAT per AZ, route tables, SGs, VPC endpoints,
flow logs) → Route53 zone → ACM wildcard → `terraform-plan.yaml` PR workflow.

**Expected output.** `terraform apply` in `environments/dev` and `production` is clean;
`.terraform.lock.hcl` committed; plan posted as a PR comment.

**Validation.** `terraform plan` → *No changes* · subnets tagged for ELB/Karpenter discovery ·
ACM status `ISSUED` · `aws ec2 describe-flow-logs` returns one.

**Interview Q.** Why S3+DynamoDB and not workspaces? · What does DynamoDB actually store? ·
Why NAT per AZ, and what does a single NAT cost you in an AZ failure? · Public vs private vs
database subnet? · How does OIDC remove the need for AWS keys in CI? · What's in `sub`?

**Mistakes.** `force_destroy` on the state bucket · `single_nat_gateway` in prod · forgetting
`kubernetes.io/role/elb` tags (ALB creation then fails mysteriously) · hardcoding account IDs ·
not committing the lock file · applying from a laptop.

**Best practice.** Layered state · `prevent_destroy` · `default_tags` · plan on PR, apply on
merge behind an environment reviewer.

---

## Phase 2 — Cluster Bootstrap *(week 2–3)*

**Goal.** A hardened EKS cluster with three node pools and the essential add-ons.

**Tasks.** `modules/eks` (1.31, envelope encryption with CMK, all 5 control-plane log types,
`authentication_mode: API` + access entries, private+restricted-public endpoint) → node groups
`system`/`roboshop`/`spot` with labels+taints → IRSA module → add-ons in order: metrics-server,
AWS LB Controller, EBS CSI, External Secrets, Cluster Autoscaler/Karpenter, external-dns,
cert-manager → `gp3-retain` StorageClass + VolumeSnapshotClass.

**Expected output.** `kubectl get nodes` shows 3 pools across 3 AZs; all add-ons Running.

**Validation.** `kubectl top nodes` works (metrics-server) · test Ingress produces a real ALB ·
test PVC binds · a test ExternalSecret materialises · `kubectl get events -A | grep -i error`
is quiet.

**Interview Q.** How does IRSA work end-to-end (SA token → OIDC → STS AssumeRoleWithWebIdentity)? ·
Why taint the system pool? · Managed node group vs Karpenter? · What does EKS envelope
encryption protect against? · Why `WaitForFirstConsumer`?

**Mistakes.** Public endpoint open to `0.0.0.0/0` · forgetting metrics-server (all HPAs silently
dead) · Spot for stateful/system workloads · VPC CNI IP exhaustion (enable prefix delegation) ·
add-on version skew with the control plane.

---

## Phase 3 — Container Registry & Images *(week 3)*

**Goal.** Every service image built, scanned, signed, and stored in ECR.

**Tasks.** ECR repos with `IMMUTABLE` tags, scan-on-push, KMS, lifecycle rules → pull-through
cache for upstream base images → fix `mysql/Dockerfile` (remove the baked password) → remove
`__pycache__`, `kubernetes.zip`, `debug/` → add `.dockerignore` everywhere → multi-arch builds.

**Expected output.** `aws ecr list-images` shows digest-pinned, signed images for all six services.

**Validation.** `trivy image <digest>` → no Critical/High fixable · `cosign verify` passes ·
image size sane (Node <150 MB, Java <250 MB) · container runs as UID 10001.

**Interview Q.** Multi-stage build benefits? · Why scan before push? · Tag vs digest? ·
What is a distroless image and what do you lose? · How does Cosign keyless signing work
(Fulcio + Rekor, no key to manage)?

**Mistakes.** Secrets in build args (visible in `docker history`) · `:latest` · running as root ·
`apt-get` without cleaning the layer · scanning after push.

---

## Phase 4 — Helm Hardening *(week 4)*

**Goal.** Take the existing 9/10 charts to 10/10.

**Tasks.** `values.schema.json` per chart · commit `Chart.lock` · publish `common` to OCI ·
`helm-unittest` + golden files · `common.servicemonitor` · checksum annotations · `preStop` +
grace period · split probes into live/ready/started · CPU limits removed / memory req==limit ·
PDB → `maxUnavailable` · PriorityClasses · dual topology spread · HPA `behavior` · enable HPA
on shipping/payment · default-deny egress · per-service ServiceAccount + IRSA.

**Validation.** `make lint template validate scan` green · `helm unittest charts/*` green ·
diff the rendered output before/after to prove only the intended fields changed.

**Interview Q.** Library vs subchart vs dependency? · Why no CPU limits? · `minAvailable` vs
`maxUnavailable`? · What breaks if liveness checks the database? · How do you roll pods on a
ConfigMap change?

**Mistakes.** `minAvailable: 1` on a 1-replica STS (blocks drains) · same endpoint for all
three probes · mutable selector labels (immutable field → upgrade fails) · `--set` in CI
instead of values files.

---

## Phase 5 — CI: Build & Test *(week 5)*

**Goal.** Every push runs tests and produces a signed, scanned artifact.

**Tasks.** `app-ci.yaml` with `dorny/paths-filter` + matrix · unit + integration tests
(testcontainers / `services:`) · coverage gate on new code · CodeQL, Semgrep, Gitleaks, Trivy fs
· Buildx with GHA cache · Trivy image gate → push → Cosign sign → Syft SBOM → attest · reusable
workflow · pin actions to SHAs · fix `helm-release.yaml`'s WORKDIR bug.

**Validation.** PR shows all checks · a deliberately vulnerable dependency fails the build ·
a planted fake AWS key is caught by Gitleaks · cached run < 3 min.

**Interview Q.** Why does CI never hold cluster credentials? · Difference between SAST, SCA,
DAST, IaC scanning? · Why pin actions to SHAs? · How do you keep matrix builds fast?

**Mistakes.** `pull_request_target` with secrets · `npm install` instead of `npm ci` ·
`continue-on-error` on security jobs ("green" pipelines that check nothing) · caching a
directory containing credentials.

---

## Phase 6 — GitOps *(week 6)*

**Goal.** ArgoCD actually reconciles, automatically.

**Tasks.** Install ArgoCD HA on the system pool · SSO + RBAC, disable local admin · AppProject
guardrails with blacklist + sync windows · **fix the three P0 bugs** (misplaced `syncPolicy`,
missing `automated`, out-of-bounds valueFile → multi-source `$values`) · app-of-apps roots ·
ApplicationSets with RollingSync · custom health checks for ExternalSecret · Git webhook ·
Slack notifications · nightly `argocd admin export` to S3.

**Validation.** All 11 apps Synced+Healthy · `kubectl delete deploy/cart` → self-healed in <60s ·
`argocd app diff` empty · a PR merge syncs within seconds via webhook.

**Interview Q.** Push vs pull CD — the security argument? · Sync waves vs hooks? · What does
self-heal do to `kubectl edit`? · How do you roll back in GitOps? · Why `ignoreDifferences` on
`/spec/replicas`?

**Mistakes.** `automated.prune` without understanding it deletes resources · CI running
`helm upgrade` *and* ArgoCD managing the same release (two reconcilers) · `targetRevision: HEAD`
on a branch that moves under you · no health check for a CRD (sync hangs forever).

---

## Phase 7 — CD & Promotion *(week 7)*

**Goal.** Close the loop: code → image → `images.yaml` → cluster.

**Tasks.** `images.yaml` per environment · `app-cd.yaml` writes dev pins and opens a PR ·
`promote.yaml` for dev→qa→staging→production behind GitHub Environments · deployment validation
(`argocd app wait`) · k6 smoke test as a PostSync hook · Slack notifications · documented
`git revert` rollback.

**Validation.** Change one line in `apps/cart/server.js` → within ~10 min it is live in dev with
zero manual steps · promotion to prod requires 2 approvals and respects the sync window ·
`git revert` restores the previous digest in <2 min.

**Interview Q.** Why digests instead of tags in `images.yaml`? · How do you prevent a bot PR
from bypassing review? · What is your change-failure rate and how do you measure it?

**Mistakes.** Bot commits triggering CI recursively (use `[skip ci]`) · promoting a *tag* rather
than a *digest* (the tag may have moved) · auto-merging into production.

---

## Phase 8 — Observability *(week 8)*

**Goal.** Answer "what's broken, since when, and what changed" in under 5 minutes.

**Tasks.** kube-prometheus-stack HA · ServiceMonitors via `common` · datastore + blackbox
exporters · dashboards as ConfigMaps with deploy annotations · SLOs + multi-burn-rate alerts ·
Alertmanager routing + inhibitions · Fluent Bit → Loki (S3) · OTel Operator → Tempo · Thanos → S3.

**Validation.** Kill a pod → alert fires and routes correctly · a trace shows the full
cart→payment→rabbitmq→shipping path · logs are queryable by `trace_id` · every alert has a
working `runbook_url`.

**Interview Q.** RED vs USE? · SLI/SLO/error budget/burn rate? · Why multi-window multi-burn-rate?
· Why does high-cardinality labelling kill Prometheus? · Loki vs Elasticsearch trade-off? ·
Head vs tail sampling?

**Mistakes.** Alerting on causes (CPU) rather than symptoms (error rate) · user IDs as labels ·
dashboards edited in the UI and lost on restart · alerts with no runbook and no owner.

---

## Phase 9 — Security Hardening *(week 9)*

**Goal.** Enforce at runtime what CI already checks.

**Tasks.** Kyverno in **Audit** for 2 weeks → Enforce · signed-image + ECR-only + hardening
policies · PSA `restricted` labels · Falco + Falcosidekick · kube-bench weekly → S3 ·
GuardDuty EKS Runtime Monitoring · Security Hub · default-deny egress · per-service IRSA ·
secret rotation test · WAF on the ALB.

**Validation.** An unsigned image is **rejected** at admission · a privileged pod is rejected ·
`kubectl exec` into a pod fires a Falco alert · kube-bench score improves week over week ·
rotating the secret in Secrets Manager propagates and pods pick it up.

**Interview Q.** Defence in depth across the four gates? · Kyverno vs Gatekeeper vs PSA? ·
What is SLSA and what level are you at? · Why is an SBOM useful *after* an incident (Log4Shell)? ·
How do you handle a secret leaked to Git?

**Mistakes.** Enforce from day one (instant outage) · policies without `kube-system` exclusions ·
scanning but never remediating · treating admission control as a substitute for CI scanning.

---

## Phase 10 — Resilience & DR *(week 10)*

**Goal.** Survive an AZ loss and prove you can restore.

**Tasks.** Decide managed vs operator vs documented-single-replica for each datastore · AWS
Backup plan + cross-region copy · logical dump CronJobs to S3 (versioned + Object Lock) ·
Velero · `restore-db.sh` · RTO/RPO table · game-day: delete a staging namespace and time the
recovery · chaos test: drain a node, kill an AZ's nodes.

**Validation.** A **timed, dated** restore record for each tier · drain a node with no user-visible
errors · full cluster rebuild from scratch under 60 min.

**Interview Q.** RTO vs RPO — pick numbers and justify them · Why is a snapshot not a backup? ·
How do you restore without overwriting live data? · Pilot light vs warm standby vs active-active?

**Mistakes.** Backups that were never restored · backups in the same account/region as the
data · no `reclaimPolicy: Retain` · assuming EBS snapshots are crash-consistent for a database
(they are not — quiesce or dump logically).

---

## Phase 11 — Progressive Delivery & Cost *(week 11)*

**Goal.** Deploy without fear; pay for what you use.

**Tasks.** Argo Rollouts + `common.rollout` · canary with Prometheus AnalysisTemplate and
automatic abort · Karpenter consolidation · Spot for stateless · Graviton multi-arch ·
VPA recommender → rightsize requests · OpenCost + cost dashboard · AWS Budgets + anomaly
detection · scale non-prod to zero out of hours.

**Validation.** Deploy a deliberately broken version → the canary aborts automatically at 5%
weight · cluster cost drops ≥30% with SLOs unchanged.

**Interview Q.** Canary vs blue/green vs rolling — when each? · How does Argo Rollouts decide
to abort? · Feature flags vs deployment strategies? · Three biggest EKS cost levers?

**Mistakes.** Canary without metric analysis (it's just a slow rolling update) · Spot for
stateful · rightsizing on averages instead of p95 · optimising cost before establishing SLOs.

---

## Phase 12 — Production Launch *(week 12)*

**Goal.** Go live with confidence and operate it.

**Tasks.** Complete the readiness checklist (Phase 9 §9.9) · load test and publish the numbers ·
finish runbooks for the top 10 alerts · on-call rotation + escalation · status page · DORA
dashboard · post-incident review template · launch review + explicit go/no-go.

**Validation.** All checklist boxes ticked with evidence · SLOs green for 7 consecutive days ·
one game day and one real deploy performed by someone who did **not** build the platform, using
only the docs.

**Interview Q.** What are the four DORA metrics and yours? · What does "production ready" mean
to you? · Walk me through your last incident. · What would you do differently next time?

**Mistakes.** Launching without runbooks · no on-call owner · treating launch as the finish line ·
no feedback loop from incidents back into the roadmap.

---

## Priority order if you only have two weeks

```text
1. Fix the three ArgoCD P0 bugs                      (2 h)   — nothing works without this
2. Fix helm-release.yaml WORKDIR                     (15 m)
3. Keep the legacy Kubernetes/Kustomize tree removed — this prevents a second source of truth
4. Remove the MySQL password default                 (15 m)
5. Add app-ci.yaml: test → Trivy → build → ECR push  (1 d)   — the missing half of the pipeline
6. Add images.yaml + GitOps write-back               (0.5 d)
7. Terraform bootstrap + VPC + EKS                   (3 d)   — biggest score jump: 1 → 8
8. metrics-server + kube-prometheus-stack + 10 alerts(1 d)   — 0 → 6 on observability
9. Backups: snapshots + logical dumps + one restore  (1 d)   — 1 → 6 on DR
10. Kyverno in Audit + PSA restricted                (0.5 d)
```

That sequence moves overall production readiness from **4.3 → ~7.5** and turns the repo from
"a very good Helm project" into "a platform."

---

**Back to:** [Phase 1 — Executive review](./00-executive-review.md)
