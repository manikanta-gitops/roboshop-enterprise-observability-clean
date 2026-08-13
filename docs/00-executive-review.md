> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 1 — Enterprise Architecture Review (Roboshop)

> Reviewed artifact: `roboshop_prod-dev_1.zip` — 340 files, 11 Helm charts, 1 library chart,
> 4 environments, 2 GitHub Actions workflows, 5 CI shell scripts, 6 application services,
> 4 datastores, Helm-based application deployment managed by Argo CD, with Terraform managing AWS infrastructure.

---

## 1.1 What this repository actually is

This is the Instana **Stan's Robot Shop** reference application (`frontend`, `catalogue`,
`user`, `cart`, `shipping`, `payment` + MongoDB / MySQL / Redis / RabbitMQ), which has been
**Helmified** into a library-chart-driven packaging repo and wired to ArgoCD.

It is a **single repository doing four jobs at once**:

| Job | Where it lives | Verdict |
|---|---|---|
| Application source code | `cart/`, `catalogue/`, `user/`, `payment/`, `shipping/`, `frontend/` | Mixed into the deploy repo |
| Container build | per-service `Dockerfile` | Good quality, **never built by CI** |
| Kubernetes packaging | `charts/` (11 charts + `common` library) | The strongest part of the repo |
| Delivery / GitOps | `argocd/`, `.github/workflows/`, `ci/` | Partially wired, **broken in three places** |

The legacy raw Kubernetes shadow copy has been removed; Helm charts are the single application packaging source.
(+ a committed `kubernetes.zip`), which is now a second, silently-diverging source of truth.

---

## 1.2 Current architecture (as-is)

```text
                 Internet
                    │  HTTPS
          ┌─────────▼─────────┐
          │ AWS ALB           │  ingress group.name = roboshop
          │ path routing      │  (single Ingress in charts/platform)
          └─────────┬─────────┘
        ┌───────┬───┴───┬───────┬────────┬─────────┐
        ▼       ▼       ▼       ▼        ▼         ▼
    frontend  catalogue user   cart   payment  shipping
    nginx:8080  :8080   :8080  :8080   :8080    :8080
      (HPA)     (HPA)   (HPA)  (HPA)  (fixed)  (fixed)
                  │       │      │       │        │
                  ▼       ▼      ▼       ▼        ▼
             mongodb   mongodb  redis  rabbitmq  mysql
             (STS,1)   (STS,1) (STS,1)  (STS,1) (STS,1)
             gp3 PVC   gp3 PVC gp3 PVC  gp3 PVC gp3 PVC
```

**Control plane / delivery flow (as-is):**

```text
developer ──push──> GitHub ──> helm-ci.yaml (lint, template, kubeconform, checkov)
                              helm-release.yaml (tag → helm package → push OCI/ECR)
                                       │
                        ArgoCD root Application (app-of-apps)
                                       │
                        ApplicationSet (list generator, 11 elements)
                                       │
                        11 Applications → namespace roboshop*
```

**The missing half:** there is no path from *source code → image → tag update → Git*.
Images are hard-pinned to Docker Hub `devopman/<svc>:2.0.1` in every values file, and the
`image.registry` field in all four `global-values.yaml` files is `""`. So the platform is
GitOps for *manifests* but **manual for the thing that actually changes daily** — the image tag.

---

## 1.3 Strengths (credit where due — this is above average for a portfolio repo)

1. **Real library chart.** `charts/common` exposes `common.deployment`, `common.statefulset`,
   `common.hpa`, `common.pdb`, `common.networkpolicy`, `common.externalsecret`,
   `common.secretproviderclass`, `common.ingress`. Every service template is a one-line
   `include`. This is exactly how Bitnami/Uber do it, and it is the single biggest thing
   that separates this repo from a "copy-paste YAML" project.
2. **Security posture in the pod spec is genuinely good:** `runAsNonRoot`, fixed UID `10001`,
   `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile:
   RuntimeDefault`, `readOnlyRootFilesystem` on stateless services with an `emptyDir` at
   `/tmp`, and `automountServiceAccountToken: false` everywhere.
3. **No secrets in Git.** Secret delivery is External Secrets Operator **or** Secrets Store
   CSI → AWS Secrets Manager. `secrets-policy.json` and `clustersecretstore.yaml` show the
   IRSA intent.
4. **Dockerfiles are multi-stage, non-root, pinned base tags, with HEALTHCHECKs.**
   `npm ci --omit=dev`, Maven `dependency:go-offline` layer caching, distro-slim runtimes.
5. **Default-deny NetworkPolicy baseline** + explicit allows (DNS, ALB→frontend,
   ALB→backend, svc↔svc, svc→datastore ports).
6. **Four-environment values model** with a clean precedence chain
   (`values.yaml` → `values-<env>.yaml` → `environments/<env>/global-values.yaml`).
7. **CI actually validates**: `helm lint --strict` for every chart × every env,
   `helm template`, `kubeconform -strict` with the datree CRD catalog, Checkov + SARIF upload.
8. **Production values are differentiated, not copy-paste**: prod uses
   `whenUnsatisfiable: DoNotSchedule`, `minAvailable: 2`, dedicated `workload=roboshop`
   node pool with matching tolerations, higher HPA floors.

---

## 1.4 Weaknesses, ranked by blast radius

### 🔴 P0 — will break in production / already broken

**W1. The root ArgoCD Application never auto-syncs — `syncPolicy` is nested in the wrong place.**

```yaml
# argocd/applications/root-production.yaml  (CURRENT — BUG)
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
    syncPolicy:            # ← indented under destination; ArgoCD ignores this entirely
      automated:
        prune: true
        selfHeal: true
```

`syncPolicy` is a sibling of `destination` under `spec`, not a child. As written, the root
app is created in **manual sync mode with no prune and no self-heal** — silently. All four
root apps (`root-dev`, `root-qa`, `root-staging`, `root-production`) have the same defect.

**W2. The child Applications generated by every ApplicationSet have no `syncPolicy.automated` at all.**
`spec.template.spec.syncPolicy` only contains `syncOptions` and `retry`. So even after W1 is
fixed, all 11 workloads per environment sit in **OutOfSync, waiting for a human**. There is no
self-heal, no prune, no drift correction — i.e. **this is not GitOps yet, it is "ArgoCD as a
deploy button."**

**W3. Out-of-bounds Helm value file.**

```yaml
helm:
  valueFiles:
    - values.yaml
    - values-production.yaml
    - ../../environments/production/global-values.yaml   # ← outside spec.source.path
```

ArgoCD ≥ 2.6 rejects value files resolved outside the Application's `path`
(`.. is not allowed`). Every Application will fail to render. Fix = **multi-source
Applications** with a `$values` ref (shown in Phase 5).

**W4. `helm-release.yaml` runs in a directory that does not exist.**
`env.WORKDIR: roboshop-helm` + `defaults.run.working-directory: ${{ env.WORKDIR }}`, but the
repo root *is* the chart repo — there is no `roboshop-helm/` folder. Every step fails with
`no such file or directory`. (Also: `env` is not available in `defaults.run.working-directory`
at that scope in Actions — a second, independent failure.)

**W5. No application CI whatsoever.** No `docker build`, no unit tests, no image scan, no
push to ECR, no image-tag write-back to Git. The `.github/workflows/helm-ci.yaml` `paths:`
filter is `charts/** | ci/** | environments/**` — **changing `cart/server.js` triggers
nothing.** A code change can never reach the cluster.

**W6. Every datastore is a single-replica StatefulSet on a single EBS volume with no backup.**
MongoDB (×2 logical DBs), MySQL, Redis, RabbitMQ. EBS is **AZ-pinned**: lose the AZ, lose the
data and the pod cannot reschedule. No `VolumeSnapshot`, no Velero, no mysqldump CronJob,
no PITR. This is the single largest production risk in the repo.

### 🟠 P1 — serious

The legacy Kubernetes/Kustomize deployment source was removed. Application deployment is now GitOps-only through Argo CD and Helm.
**Delete it or move it to `archive/` with a README tombstone.**

**W8. Images are mutable Docker Hub tags.** `devopman/catalogue:2.0.1`, `pullPolicy:
IfNotPresent`. No digest pinning (`image.digest` exists in values but is `""` everywhere),
no ECR, no Cosign signature, no SBOM, no pull-through cache. Docker Hub is also rate-limited
and is a third-party supply-chain dependency for production.

**W9. `image.registry: ""` in all four environments.** Production pulls from Docker Hub.
Prod and dev pull the **same tag from the same public registry** — there is no promotion
boundary at all.

**W10. Committed build/junk artifacts.** `payment/__pycache__/*.pyc`, `kubernetes.zip`,
`debug/Dockerfile`, `rabbitmq-debug.yaml`. Bytecode in Git is a (small) supply-chain smell
and an instant red flag in an interview.

**W11. `mysql/Dockerfile` bakes `ARG MYSQL_ROOT_PASSWORD="RoboShop@1"` into `ENV`.**
The comment claims it is runtime-supplied, but the default **is** in the image layer and in
`docker history`. Remove the default entirely and fail fast if unset.

**W12. No observability.** Zero Prometheus, ServiceMonitor, PodMonitor, Grafana dashboards,
alert rules, log shipping, or tracing — in a **6-service distributed system** whose upstream
(Robot Shop) is literally an APM demo app. You cannot debug a `payment → rabbitmq → shipping`
failure with `kubectl logs`.

**W13. No progressive delivery.** `RollingUpdate maxUnavailable: 0 / maxSurge: 1` is fine,
but there is no canary, no blue/green, no automated rollback on SLO burn. `helm rollback`
by hand (`make rollback RELEASE=cart`) is the entire strategy — and it **conflicts with
ArgoCD self-heal**, which would immediately re-apply Git.

**W14. Shipping & payment have `autoscaling` off and fixed replicas** while sitting on the
synchronous request path behind HPA'd callers. Under load, `cart` scales to 8 and hammers a
fixed-size `shipping`. Classic cascading-failure setup.

### 🟡 P2 — quality / maturity

**W15.** No `Chart.lock` committed → `helm dependency build` resolves the `common` version at
CI time; builds are not byte-reproducible.
**W16.** No `values.schema.json` → a typo in `autoscaling.minReplias` silently does nothing.
**W17.** No `helm-unittest` / no rendered-golden-file tests. `kubeconform` proves it is *valid
YAML for the API server*, not that it is *correct*.
**W18.** No Kyverno/Gatekeeper — Checkov is a *CI* gate; nothing stops `kubectl apply` of a
privileged pod at runtime.
**W19.** No PriorityClass on datastores (`priorityClassName: ""`), so a node-pressure eviction
can kill MySQL before a stateless pod.
**W20.** No `terminationGracePeriodSeconds` tuning for RabbitMQ/MySQL (30s default is short
for a MySQL flush).
**W21.** No Renovate/Dependabot; base images and Actions (`actions/checkout@v4`) drift.
Actions are pinned by **tag, not SHA** — mutable.
**W22.** ArgoCD `AppProject` has `namespaceResourceWhitelist: '*'/'*'` — no real guardrail.
**W23.** No cost controls: no Spot node group, no Karpenter, no Kubecost, `LimitRange`/
`ResourceQuota` exist but no requests-vs-usage feedback loop.
**W24.** `INTERVIEW_GUIDE.md`, `DECISIONS.md`, `MODERNIZATION_NOTES.md` are good, but there is
no runbook, no DR guide, no troubleshooting guide, no on-call doc.

---

## 1.5 Security findings

| # | Finding | Severity | Fix |
|---|---|---|---|
| S1 | MySQL root password default baked into image layer | High | Drop `ARG` default; require env at runtime |
| S2 | Mutable, unsigned, unscanned public images in production | High | ECR + digest pin + Trivy gate + Cosign + SBOM |
| S3 | No admission control at runtime (CI-only policy) | High | Kyverno in `Enforce` mode + PSA `restricted` label |
| S4 | No image-pull secrets / private registry → Docker Hub outage = prod outage | Medium | ECR pull-through cache |
| S5 | `AppProject` whitelists all namespaced kinds | Medium | Whitelist explicit kinds; blacklist `ClusterRole*` |
| S6 | GitHub Actions pinned to mutable tags | Medium | Pin to commit SHA |
| S7 | No secret scanning (Gitleaks/Trufflehog) in CI | Medium | Add to PR gate + pre-commit |
| S8 | No SBOM / provenance attestation | Medium | Syft + Cosign attest, SLSA L3 target |
| S9 | Committed `.pyc` bytecode | Low | `.gitignore` + purge |
| S10 | No egress restriction to the internet from app pods | Medium | Default-deny egress + explicit CIDR allows |
| S11 | No IRSA per service account (one shared `roboshop` SA) | Medium | One SA per service, least-privilege IRSA |
| S12 | No CloudTrail/GuardDuty/Config in scope (no Terraform at all) | High | Phase 3 |

---

## 1.6 Production risks (what pages you at 3am)

1. **AZ failure → permanent data loss.** Single EBS-backed StatefulSets, no snapshots.
2. **Cluster rebuild is impossible.** No Terraform: the VPC, EKS, node groups, IRSA roles,
   ECR, Route53 and ACM that this repo assumes are **undocumented click-ops**. Bus factor 1.
3. **Drift is invisible.** No self-heal → someone's `kubectl edit` survives forever.
4. **No rollback SLA.** Manual `helm rollback` fights ArgoCD; no tested restore procedure.
5. **Blind incident response.** No metrics, logs, traces, or alerts.
6. **Docker Hub is a prod dependency.** Rate limits + upstream deletion risk.
7. **Cascading failure via unscaled `shipping`/`payment`.**
8. **Secret rotation untested** — ESO refresh interval and pod restart behaviour unproven.

---

## 1.7 Scorecard (1–10)

| Category | Score | One-line justification |
|---|:--:|---|
| Architecture & design | **7** | Clean service decomposition, sound library-chart abstraction, but mono-repo mixes app + platform |
| Repository structure | **5** | Application deployment is centralized in Helm + GitOps; legacy Kubernetes shadow copy removed |
| Infrastructure as Code | **1** | **Terraform does not exist.** Everything below the cluster is click-ops |
| Containerisation | **8** | Multi-stage, non-root, pinned, HEALTHCHECK — minus the MySQL password default |
| Helm / K8s packaging | **9** | Best-in-repo. Library chart, 4-env values, full resource matrix |
| Kubernetes production hardening | **7** | Excellent pod security; missing PriorityClass, PDB math on 1-replica STS, StatefulSet HA |
| GitOps | **4** | Right shape, but **three defects mean it does not actually sync** |
| CI (platform) | **6** | Lint/template/kubeconform/Checkov is real; SARIF upload is a nice touch |
| CI (application) | **0** | No build, no test, no scan, no push, no promotion. Missing entirely |
| Release & promotion | **3** | Tag → Argo CD Git-sourced Helm deployment exists but is broken; no dev→qa→stg→prod gates |
| Security (build-time) | **5** | Checkov only. No Trivy/Semgrep/CodeQL/Gitleaks/SBOM/signing |
| Security (runtime) | **4** | Great pod spec, zero admission control, one shared SA |
| Secrets management | **8** | ESO + CSI + Secrets Manager, nothing in Git. Missing rotation proof |
| Observability | **0** | Nothing. No metrics, logs, traces, dashboards or alerts |
| High availability | **3** | Stateless tier good; every datastore is a single point of failure |
| Disaster recovery | **1** | No backup, no snapshot, no restore runbook, no RTO/RPO |
| Scalability | **6** | HPA on 4 of 6 services; no Cluster Autoscaler/Karpenter defined |
| Cost optimisation | **2** | No Spot, no rightsizing loop, no Kubecost, no budgets |
| Testing | **1** | No unit, integration, contract, smoke or Helm tests |
| Documentation | **7** | README/DECISIONS/INTERVIEW_GUIDE are strong; no runbook/DR/troubleshooting |
| Compliance & audit | **2** | No CloudTrail/Config/audit-log pipeline, no policy-as-code evidence |
| **Overall production readiness** | **4.3 / 10** | **A very good Helm repo pretending to be a platform.** |

**Verdict:** the *packaging layer* is genuinely senior-level work. The *platform* around it —
infrastructure, delivery, observability, resilience — is missing or broken. Phases 2–12 close
that gap.

---

## 1.8 The improvement template used throughout this review

Every recommendation from here on follows this shape:

> **Current State** → **Problem** → **Why it's a problem** → **Industry Best Practice** →
> **Implementation** (folder / YAML / Terraform / Actions)

---

**Next:** [Phase 2 — Repository restructure](./01-repo-structure.md)
