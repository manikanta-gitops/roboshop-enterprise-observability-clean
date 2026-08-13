> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 5 — GitOps Architecture (ArgoCD)

> **Current State:** `argocd/projects/roboshop-project.yaml`, four root Applications, four
> ApplicationSets (list generator, 11 elements, sync waves −1/0/1/2).
> **Score: 4/10 — right shape, three defects that mean it does not actually sync.**

---

## 5.1 The three P0 bugs, fixed

### 🔴 Bug 1 — `syncPolicy` nested under `destination`

```yaml
# CURRENT — argocd/applications/root-production.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
    syncPolicy:              # ❌ ArgoCD silently ignores unknown fields here
      automated: { prune: true, selfHeal: true }
```

`syncPolicy` is a sibling of `destination` under `spec`. As written the root Application is
created in **manual mode**. All four root apps have this bug. Fixed:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: roboshop-production-root
  namespace: argocd
  finalizers: [resources-finalizer.argocd.argoproj.io]
spec:
  project: roboshop
  source:
    repoURL: https://github.com/roboshop/roboshop-platform.git
    targetRevision: main                    # ← pin a branch, not HEAD (see §5.4)
    path: gitops/applicationsets
    directory: { recurse: false, include: 'roboshop-production.yaml' }
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:                               # ✅ correct level
    automated: { prune: true, selfHeal: true, allowEmpty: false }
    syncOptions: [CreateNamespace=true, ServerSideApply=true, ApplyOutOfSyncOnly=true]
    retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 5m } }
```

### 🔴 Bug 2 — child Applications have no `automated` block

`spec.template.spec.syncPolicy` in every ApplicationSet contains only `syncOptions` and
`retry`. So all 11 workloads sit **OutOfSync forever**. Add `automated` to the template.

### 🔴 Bug 3 — out-of-bounds value file

```yaml
valueFiles:
  - ../../environments/production/global-values.yaml   # ❌ outside spec.source.path
```

ArgoCD ≥2.6 refuses paths that resolve outside the app path. Fix with **multi-source
Applications** and a `$values` reference:

```yaml
sources:
  - repoURL: https://github.com/roboshop/roboshop-platform.git
    targetRevision: main
    ref: values                                     # ← names this source
  - repoURL: https://github.com/roboshop/roboshop-platform.git
    targetRevision: main
    path: charts/catalogue
    helm:
      releaseName: catalogue
      valueFiles:
        - values.yaml
        - values-production.yaml
        - $values/gitops/environments/production/global-values.yaml   # ✅ legal
        - $values/gitops/environments/production/images.yaml          # ✅ image tags
```

---

## 5.2 Repository layout ArgoCD reads

```text
gitops/
├── projects/
│   ├── roboshop-appproject.yaml        # guardrails for application workloads
│   └── platform-appproject.yaml        # guardrails for cluster add-ons
├── bootstrap/
│   ├── root-dev.yaml  root-qa.yaml  root-staging.yaml  root-production.yaml
│   └── root-addons.yaml
├── applicationsets/
│   ├── roboshop-dev.yaml … roboshop-production.yaml
│   └── addons-<env>.yaml
└── environments/
    ├── dev/        global-values.yaml, images.yaml
    ├── qa/         global-values.yaml, images.yaml
    ├── staging/    global-values.yaml, images.yaml
    └── production/ global-values.yaml, images.yaml   ← CODEOWNERS: 2 approvals
```

**Why `images.yaml` is a separate file:** it is the **only** file CI writes to. Humans edit
`global-values.yaml`; the bot edits `images.yaml`. Clean diffs, clean audit trail, no merge
conflicts between a human config change and an automated tag bump.

```yaml
# gitops/environments/production/images.yaml — written by CI, reviewed by humans
images:
  catalogue: { repository: 123456789012.dkr.ecr.ap-south-1.amazonaws.com/roboshop/catalogue,
               tag: "v2.4.1", digest: "sha256:9f2c…" }
  cart:      { repository: …/roboshop/cart,  tag: "v2.4.1", digest: "sha256:81ab…" }
```

---

## 5.3 The full architecture

```text
                         ┌──────────────────────────────────────┐
                         │ Git  (gitops/ = single source of truth)│
                         └───────────────┬──────────────────────┘
                                         │ poll 3m / webhook (instant)
                    ┌────────────────────▼─────────────────────┐
                    │            ArgoCD (namespace argocd)      │
                    │  api-server · repo-server · app-controller│
                    │  redis · applicationset-controller · notif│
                    └────┬──────────────────────────────┬──────┘
                         │                              │
             AppProject: platform            AppProject: roboshop
                         │                              │
        root-addons Application            root-<env> Application (app-of-apps)
                         │                              │
        ApplicationSet: addons-<env>       ApplicationSet: roboshop-<env>
                         │                              │
   ┌───────┬────────┬────┴───┬──────┐      wave -1 ── platform (ns, quota, SC, ingress, netpol)
   LBC   EBS-CSI   ESO   Kyverno  Prom     wave  0 ── mongodb · mysql · redis · rabbitmq
   (waves -20 … -5)                        wave  1 ── catalogue · user · cart · shipping · payment
                                           wave  2 ── frontend
                                           wave  3 ── smoke-test Job (PostSync hook)
```

**Deploy targets:** `roboshop-dev` (ns `roboshop-dev`) … `roboshop` (prod ns).
Recommended maturity step: **separate clusters** for prod vs non-prod, registered as
additional ArgoCD destinations — namespace isolation is not a security boundary against a
container escape.

---

## 5.4 AppProject — real guardrails

**Current problem:** `namespaceResourceWhitelist: '*'/'*'` — no guardrail at all. An
Application could create a `ClusterRoleBinding` to `cluster-admin`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: { name: roboshop, namespace: argocd, finalizers: [resources-finalizer.argocd.argoproj.io] }
spec:
  description: Roboshop microservices platform
  sourceRepos:
    - https://github.com/roboshop/roboshop-platform.git
    - 123456789012.dkr.ecr.ap-south-1.amazonaws.com/roboshop     # OCI chart registry
  destinations:
    - { namespace: 'roboshop*', server: https://kubernetes.default.svc }

  clusterResourceWhitelist:                 # allow-list, tiny
    - { group: "",                kind: Namespace }
    - { group: storage.k8s.io,    kind: StorageClass }
    - { group: networking.k8s.io, kind: IngressClass }
    - { group: scheduling.k8s.io, kind: PriorityClass }

  namespaceResourceBlacklist:               # ❗ the important one
    - { group: rbac.authorization.k8s.io, kind: ClusterRole }
    - { group: rbac.authorization.k8s.io, kind: ClusterRoleBinding }
    - { group: "",                        kind: ResourceQuota }   # platform team only

  orphanedResources: { warn: true }

  # Freeze production deploys outside change windows.
  syncWindows:
    - kind: deny
      schedule: "0 0 * * 5,6"     # Fri/Sat 00:00
      duration: 48h
      applications: ['roboshop-production-*']
      manualSync: true            # break-glass still allowed, and audited
      timeZone: "Asia/Kolkata"
    - kind: allow
      schedule: "0 9 * * 1-4"
      duration: 9h
      applications: ['roboshop-production-*']

  roles:
    - name: read-only
      policies: [p, proj:roboshop:read-only, applications, get, roboshop/*, allow]
      groups:   [roboshop:developers]
    - name: deployer
      policies:
        - p, proj:roboshop:deployer, applications, sync,     roboshop/*, allow
        - p, proj:roboshop:deployer, applications, override, roboshop/*, deny
      groups: [roboshop:sre]
```

---

## 5.5 The corrected ApplicationSet

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: roboshop-production
  namespace: argocd
spec:
  goTemplate: true
  goTemplateOptions: ["missingkey=error"]

  # Do not let a Git mistake delete production. Prune only after review.
  syncPolicy:
    applicationsSync: create-update          # never auto-delete Applications
    preserveResourcesOnDeletion: true

  strategy:                                  # progressive rollout ACROSS applications
    type: RollingSync
    rollingSync:
      steps:
        - matchExpressions: [{ key: wave, operator: In, values: ["-1"] }]
        - matchExpressions: [{ key: wave, operator: In, values: ["0"]  }]
        - matchExpressions: [{ key: wave, operator: In, values: ["1"]  }]
        - matchExpressions: [{ key: wave, operator: In, values: ["2"]  }]

  generators:
    - list:
        elements:
          - { name: platform,  chart: charts/platform,  wave: "-1" }
          - { name: mongodb,   chart: charts/mongodb,   wave: "0"  }
          - { name: mysql,     chart: charts/mysql,     wave: "0"  }
          - { name: redis,     chart: charts/redis,     wave: "0"  }
          - { name: rabbitmq,  chart: charts/rabbitmq,  wave: "0"  }
          - { name: catalogue, chart: charts/catalogue, wave: "1"  }
          - { name: user,      chart: charts/user,      wave: "1"  }
          - { name: cart,      chart: charts/cart,      wave: "1"  }
          - { name: shipping,  chart: charts/shipping,  wave: "1"  }
          - { name: payment,   chart: charts/payment,   wave: "1"  }
          - { name: frontend,  chart: charts/frontend,  wave: "2"  }

  template:
    metadata:
      name: 'roboshop-production-{{.name}}'
      annotations:
        argocd.argoproj.io/sync-wave: '{{.wave}}'
        notifications.argoproj.io/subscribe.on-sync-failed.slack: platform-alerts
        notifications.argoproj.io/subscribe.on-health-degraded.slack: platform-alerts
      labels:
        roboshop.io/environment: production
        wave: '{{.wave}}'
      finalizers: [resources-finalizer.argocd.argoproj.io]
    spec:
      project: roboshop
      sources:
        - repoURL: https://github.com/roboshop/roboshop-platform.git
          targetRevision: main
          ref: values
        - repoURL: https://github.com/roboshop/roboshop-platform.git
          targetRevision: main
          path: '{{.chart}}'
          helm:
            releaseName: '{{.name}}'
            valueFiles:
              - values.yaml
              - values-production.yaml
              - $values/gitops/environments/production/global-values.yaml
              - $values/gitops/environments/production/images.yaml
      destination: { server: https://kubernetes.default.svc, namespace: roboshop }
      syncPolicy:
        automated: { prune: true, selfHeal: true, allowEmpty: false }   # ✅ the missing block
        syncOptions:
          - CreateNamespace=false          # the platform chart owns the Namespace
          - ServerSideApply=true
          - ApplyOutOfSyncOnly=true
          - PruneLast=true                 # delete removed objects after the new ones are healthy
          - RespectIgnoreDifferences=true
        managedNamespaceMetadata:
          labels: { pod-security.kubernetes.io/enforce: restricted }
        retry: { limit: 5, backoff: { duration: 10s, factor: 2, maxDuration: 5m } }
      revisionHistoryLimit: 10
      ignoreDifferences:
        - group: apps
          kind: Deployment
          jsonPointers: [/spec/replicas]            # ✅ already correct — HPA owns this
        - group: ""
          kind: Secret
          name: roboshop-secrets
          jsonPointers: [/data]                     # ESO owns the contents
```

---

## 5.6 Sync waves — how they actually work

- Waves apply **within one Application** (resource-level, via the
  `argocd.argoproj.io/sync-wave` annotation on each object) and **across Applications** only
  when the parent app-of-apps syncs them together.
- ArgoCD sorts by wave ascending, applies a wave, **waits for every resource in it to become
  Healthy**, then proceeds.
- Negative waves run first. Convention here:

| Wave | Contents | Why |
|---:|---|---|
| −20 … −5 | add-ons (CRDs, LBC, CSI, ESO, Kyverno) | CRDs must exist before CRs; policies before workloads |
| −1 | `platform` chart: Namespace, quota, LimitRange, StorageClass, IngressClass, SA, shared ConfigMap, ExternalSecret, ALB Ingress, baseline NetworkPolicies | Everything else references these |
| 0 | mongodb, mysql, redis, rabbitmq | apps crash-loop without their datastore |
| 1 | catalogue, user, cart, shipping, payment | need datastores + shared secret |
| 2 | frontend | last, so the site only goes live once APIs are healthy |
| 3 | smoke-test Job (PostSync hook) | verifies the release end-to-end |

> **Gotcha:** a wave only "completes" if ArgoCD can compute Health. A `Job` with no
> completion, or a CRD without a health check, stalls the whole sync. Use
> `hook-delete-policy: HookSucceeded` and set `activeDeadlineSeconds` on hook Jobs.

---

## 5.7 Hooks

```yaml
# Pre-sync: database migration must succeed before new pods roll
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
    argocd.argoproj.io/sync-wave: "0"
---
# Post-sync: smoke test; failure marks the sync Degraded → notification → rollback
metadata:
  annotations:
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
---
# Sync-fail: page + capture diagnostics
metadata:
  annotations: { argocd.argoproj.io/hook: SyncFail }
```

Hook types: `PreSync` → `Sync` → `PostSync`, plus `Skip` and `SyncFail`.
Prefer hooks over `helm.sh/hook` — ArgoCD understands its own annotations natively.

---

## 5.8 Health checks

ArgoCD ships built-in health for Deployment/StatefulSet/Service/Ingress/Job. For CRDs
(ExternalSecret, SecretProviderClass, Rollout) supply a Lua check:

```yaml
# argocd-cm ConfigMap
resource.customizations.health.external-secrets.io_ExternalSecret: |
  hs = {}
  if obj.status ~= nil and obj.status.conditions ~= nil then
    for _, c in ipairs(obj.status.conditions) do
      if c.type == "Ready" and c.status == "True"  then hs.status="Healthy";  hs.message=c.message; return hs end
      if c.type == "Ready" and c.status == "False" then hs.status="Degraded"; hs.message=c.message; return hs end
    end
  end
  hs.status = "Progressing"; hs.message = "waiting for secret"
  return hs
```

Without this, an ExternalSecret that never resolves shows as Healthy and your app starts with
empty credentials.

---

## 5.9 Helm + OCI registry

Two valid models:

| Model | `spec.source` | When |
|---|---|---|
| **Git-as-chart-source** (current) | `repoURL: git…, path: charts/catalogue` | Simple; chart and values move together; good for a monorepo |
| **OCI chart** | `repoURL: <acct>.dkr.ecr…/roboshop, chart: catalogue, targetRevision: 1.4.2` | Immutable, versioned, signable artifacts; chart promotion is independent of Git branch |

Your `helm-release.yaml` already pushes to OCI — so **finish the loop**: have ArgoCD consume
the OCI chart in staging/production and Git in dev. Register the ECR credential:

```bash
kubectl -n argocd create secret generic ecr-helm-creds \
  --from-literal=url=123456789012.dkr.ecr.ap-south-1.amazonaws.com \
  --from-literal=name=ecr --from-literal=type=helm \
  --from-literal=enableOCI=true --from-literal=username=AWS \
  --from-literal=password="$(aws ecr get-login-password)" \
  && kubectl -n argocd label secret ecr-helm-creds argocd.argoproj.io/secret-type=repository
```
ECR tokens expire in 12h → run a small CronJob to refresh, or use the ECR credential helper
sidecar on the repo-server.

---

## 5.10 The full application flow (end state)

```text
1. dev pushes apps/cart/server.js  → PR → app-ci.yaml
2. tests + Semgrep + CodeQL + Trivy green → image built
3. push  <ecr>/roboshop/cart:v2.4.1@sha256:… (immutable tag, signed with Cosign, SBOM attached)
4. app-cd.yaml opens a PR editing gitops/environments/dev/images.yaml
5. auto-merge to dev  → ArgoCD detects (webhook) → syncs roboshop-dev → PostSync smoke test
6. promotion PR: copy the dev image block to qa/images.yaml → CODEOWNERS review
7. …staging… then production/images.yaml → 2 approvals + sync window
8. ArgoCD syncs production wave-by-wave; Argo Rollouts runs a canary with metric analysis
9. failure → automatic rollback (Rollouts) or `git revert` (ArgoCD self-heals back)
```

**Key property:** at no point does CI hold cluster credentials. CI's write scope is ECR + a Git
branch. That is the entire security argument for pull-based GitOps.

---

## 5.11 Operational hardening

- **Webhook, not polling.** Default 3-minute reconcile → configure a GitHub webhook to
  `/api/webhook` for instant sync and lower Git API load.
- **HA ArgoCD:** `argocd-application-controller` sharded (`replicas: 2`, `SHARDING_ALGORITHM=round-robin`),
  repo-server `replicas: 3`, Redis HA (3-node) — on the `system` node pool.
- **SSO** via OIDC (Okta/Entra/Google) + RBAC groups; **disable the local `admin` account**
  after bootstrap (`admin.enabled: false`).
- **Notifications** to Slack on `on-sync-failed`, `on-health-degraded`, `on-sync-succeeded`
  (prod only).
- **Disaster recovery for ArgoCD itself:** it is stateless *except* for its `Secret`/`ConfigMap`
  set. Back up with `argocd admin export > backup.yaml` nightly to S3. Full rebuild =
  reinstall + apply the four root apps.
- **Never** `kubectl apply` into an ArgoCD-managed namespace. With self-heal on it is reverted
  within seconds; without it you create silent drift.

---

**Next:** [Phase 6 — CI/CD](./05-cicd.md)
