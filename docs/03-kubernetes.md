> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 4 — Kubernetes & Helm Deep Review

> Reviewed: `charts/common` (15 `_*.tpl` partials), `charts/platform`, and 10 workload charts,
> each with `values.yaml` + 4 environment overlays.
> **Score: 9/10 packaging, 7/10 production hardening.** This is the strongest part of the repo.

---

## 4.1 Library chart (`charts/common`) — review

**Current State.** `type: library`, renders nothing itself, exposes `common.deployment`,
`common.statefulset`, `common.service`, `common.serviceaccount`, `common.hpa`, `common.pdb`,
`common.networkpolicy`, `common.pvc`, `common.configmap`, `common.secret`,
`common.externalsecret`, `common.secretproviderclass`, `common.ingress`, `common.container`,
`common.resources`, plus naming/label/probe/scheduling helpers. Each service template is a
one-line `include`.

**Verdict: correct pattern, correctly applied.** Adding a capability to 11 charts is one edit.

**Gaps and fixes:**

| Gap | Why it matters | Fix |
|---|---|---|
| No `values.schema.json` | `autoscaling.minReplias: 5` (typo) silently does nothing — no error, wrong replica count in prod | Add a JSON Schema per chart; `helm lint` enforces it |
| No `Chart.lock` committed | `helm dependency build` re-resolves `common` at CI time → builds are not reproducible | Commit `Chart.lock`; pin `common` with `version: 1.4.2` not `^1.0.0` |
| No `helm-unittest` tests | `kubeconform` proves *valid*, not *correct*. Nothing catches "prod PDB became minAvailable: 0" | Add `tests/*_test.yaml` asserting rendered output; golden files in CI |
| `common` not published | Consumers resolve it via `file://../common` | Publish `common` to OCI/ECR and consume by version — that's what makes it a real library |
| No `common.checksumAnnotations` | ConfigMap change does not restart pods | Add `checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}` |

```yaml
# charts/common/values.schema.json  (excerpt)
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image", "resources"],
  "properties": {
    "replicaCount": { "type": "integer", "minimum": 1 },
    "image": {
      "type": "object", "required": ["repository"],
      "properties": {
        "repository": { "type": "string" },
        "tag":        { "type": "string", "pattern": "^(?!latest$).+" },
        "digest":     { "type": "string", "pattern": "^(sha256:[a-f0-9]{64})?$" }
      }
    },
    "resources": { "type": "object", "required": ["requests", "limits"] }
  },
  "additionalProperties": false     // ← this is what catches the typo
}
```

---

## 4.2 Deployment template

**Current State (good).** `revisionHistoryLimit: 5`, `maxUnavailable: 0 / maxSurge: 1`,
`terminationGracePeriodSeconds: 30`, hardened pod + container security contexts, `emptyDir`
at `/tmp` for read-only-rootfs, `automountServiceAccountToken: false`.

**Problems and fixes:**

1. **No `preStop` hook.** On `SIGTERM`, kubelet removes the pod from the Endpoints object
   *and* sends the signal concurrently. In-flight requests from the ALB (which learns about
   deregistration seconds later) get RST.
   ```yaml
   lifecycle:
     preStop:
       exec: { command: ["/bin/sh","-c","sleep 15"] }   # drain window > ALB dereg delay
   terminationGracePeriodSeconds: 60                     # must exceed preStop + app drain
   ```
   Pair with `alb.ingress.kubernetes.io/target-group-attributes:
   deregistration_delay.timeout_seconds=30`.

2. **Config changes do not roll pods.** Add the checksum annotation above.

3. **No `PriorityClass`.** `priorityClassName: ""` everywhere. Under node pressure the
   scheduler may evict MySQL to fit a frontend pod.
   ```yaml
   # platform chart
   apiVersion: scheduling.k8s.io/v1
   kind: PriorityClass
   metadata: { name: roboshop-datastore }
   value: 1000000
   globalDefault: false
   description: "Stateful datastores — evict last."
   ---
   kind: PriorityClass
   metadata: { name: roboshop-critical }   # frontend, catalogue, user, cart
   value: 100000
   ```

4. **Add `revisionHistoryLimit: 3`** in prod (5 is fine, but each revision is a stored
   ReplicaSet; with ArgoCD you roll back via Git anyway).

---

## 4.3 Probes — the most misunderstood topic in interviews

**Current State.** `catalogue`: `startupProbe` (`failureThreshold: 30`, `periodSeconds: 2` →
60s budget), `readinessProbe` 10s, `livenessProbe` 20s, all hitting `/health`.
**This is already better than most production repos.**

**Problems:**

- **All three probes hit the same `/health` endpoint.** If `/health` checks MongoDB
  connectivity, a transient DB blip makes the **liveness** probe fail → kubelet restarts every
  pod simultaneously → a database hiccup becomes a full outage. This is the single most common
  self-inflicted production incident in Kubernetes.

**Best practice — three distinct endpoints, three distinct semantics:**

| Probe | Endpoint | Question it answers | Must it check dependencies? |
|---|---|---|---|
| `startupProbe` | `/health/started` | "Has the process finished booting?" | No |
| `readinessProbe` | `/health/ready` | "Can I serve traffic *right now*?" | **Yes** — DB, cache, queue |
| `livenessProbe` | `/health/live` | "Is this process wedged and only a restart fixes it?" | **Never** — process-local only |

```yaml
startupProbe:                       # protects slow JVM boot (shipping needs ~40s)
  httpGet: { path: /health/started, port: http }
  failureThreshold: 30
  periodSeconds: 2                  # 60s budget, then liveness takes over
readinessProbe:
  httpGet: { path: /health/ready, port: http }
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3               # out of rotation in ~15s
  successThreshold: 1
livenessProbe:
  httpGet: { path: /health/live, port: http }
  periodSeconds: 20
  timeoutSeconds: 3
  failureThreshold: 3               # restart only after ~60s of being wedged
```

Rule of thumb: **liveness should be lazier and dumber than readiness.**
For `shipping` (Spring Boot) use the built-ins: `/actuator/health/liveness` and
`/actuator/health/readiness` with `management.endpoint.health.probes.enabled=true`.

---

## 4.4 Resources & QoS

**Current State.** `catalogue`: requests `100m/128Mi`, limits `500m/512Mi`. Same values in
`values.yaml` and `values-production.yaml`.

**Problems:**
1. **CPU limits cause throttling.** With `500m` and a bursty Node.js event loop, CFS throttles
   at the 100ms quota boundary, adding p99 latency even at 20% average CPU.
   **Best practice: set CPU *requests*, omit CPU *limits*; always set memory requests == limits.**
   Memory is incompressible (OOMKill), CPU is compressible (throttle). This is what Google's
   Borg-derived guidance and most large K8s shops do.
2. **Burstable QoS.** requests ≠ limits on memory → QoS class `Burstable` → evicted before
   `Guaranteed` pods under node memory pressure. Datastores should be **Guaranteed**.
3. **Requests are guesses.** Nobody measured. Use VPA in `Off`/recommender mode for 2 weeks,
   then set requests to p95 usage.

```yaml
# Recommended (stateless service)
resources:
  requests: { cpu: 200m, memory: 256Mi }
  limits:   {            memory: 256Mi }   # memory limit == request → predictable OOM
# Recommended (datastore → Guaranteed QoS)
resources:
  requests: { cpu: 1,    memory: 2Gi }
  limits:   { cpu: 1,    memory: 2Gi }
```

---

## 4.5 Autoscaling — HPA

**Current State.** HPA `autoscaling/v2` on frontend/catalogue/user/cart (prod: min 3, max 12,
CPU 60%). `shipping` and `payment` have autoscaling **disabled** with fixed replicas.

**Problems:**
1. **`metrics-server` is nowhere in the repo.** Without it every HPA reports
   `<unknown>/60%` and never scales. Fix in Phase 3 §3.7.
2. **`shipping`/`payment` are unscaled on the synchronous path** behind scaled callers →
   cascading failure (finding W14).
3. **No `behavior` block** → default scale-down stabilisation of 300s and aggressive scale-up
   can flap.
4. **CPU% is a poor proxy** for a Node.js/queue workload. Better SLIs: RPS per pod, p95
   latency, RabbitMQ queue depth (via KEDA / Prometheus Adapter).

```yaml
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
        - { type: Percent, value: 100, periodSeconds: 30 }   # double, fast
        - { type: Pods,    value: 4,   periodSeconds: 30 }
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300                        # shrink slowly
      policies: [{ type: Percent, value: 25, periodSeconds: 60 }]
```

For `payment`, scale on the queue instead of CPU:

```yaml
# KEDA ScaledObject — the correct autoscaler for a consumer
triggers:
  - type: rabbitmq
    metadata: { protocol: amqp, queueName: payments, mode: QueueLength, value: "50" }
```

**Three-layer scaling story for interviews:** HPA scales pods → Cluster Autoscaler/Karpenter
scales nodes → VPA rightsizes requests. Never run HPA and VPA on the same metric.

---

## 4.6 PodDisruptionBudget

**Current State.** `minAvailable: 1` base, `minAvailable: 2` in production for stateless.
Datastores also have PDBs — but they are **single-replica StatefulSets**.

**Critical problem:** `minAvailable: 1` on a **1-replica** StatefulSet means the PDB can
*never* be satisfied → `kubectl drain` blocks forever → **node upgrades and EKS version
upgrades hang**. This will bite you during your first cluster upgrade.

```yaml
# Stateless (HPA min 3)
podDisruptionBudget: { enabled: true, maxUnavailable: 1 }   # prefer maxUnavailable — it
                                                            # scales correctly with the HPA
# Single-replica datastore — be honest about it
podDisruptionBudget: { enabled: false }   # accept downtime, OR make it HA (§4.13)
```

> **Why `maxUnavailable` beats `minAvailable`:** with `minAvailable: 2` and an HPA that scales
> down to 3, a drain can only ever move 1 pod at a time; with `maxUnavailable: 1` the budget
> stays correct at 3 or at 20 replicas.

---

## 4.7 Scheduling: affinity, topology spread, tolerations

**Current State (good).** Prod uses `topologySpreadConstraints` `maxSkew: 1`,
`topology.kubernetes.io/zone`, `whenUnsatisfiable: DoNotSchedule`, plus
`nodeSelector: workload=roboshop` and a matching toleration.

**Problems:**
1. **Zone spread only — no host spread.** Three pods can land on one node in one AZ. Add a
   second constraint on `kubernetes.io/hostname`.
2. `DoNotSchedule` on zone + a node pool that has capacity in only 2 AZs = **unschedulable
   pods during a scale-up**. Ensure the ASG spans all 3 AZs (Phase 3 does).
3. No `podAntiAffinity` fallback for datastores.

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule          # hard: survive an AZ loss
    labelSelector: { matchLabels: { app.kubernetes.io/name: catalogue } }
    matchLabelKeys: [pod-template-hash]       # per-revision spread (k8s ≥1.27)
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: ScheduleAnyway         # soft: prefer node spread
    labelSelector: { matchLabels: { app.kubernetes.io/name: catalogue } }
```

---

## 4.8 Service, Ingress, and the ALB

**Current State.** ClusterIP services; headless for StatefulSets; a **single shared ALB
Ingress** in `charts/platform` with `group.name: roboshop`; per-service `ingress.enabled: false`.

**Verdict: correct.** One ALB for all paths = one ~$18/mo LB instead of six, one cert, one WAF
attachment. Using `alb.ingress.kubernetes.io/group.name` is exactly the right mechanism.

**Improvements:**

```yaml
annotations:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip              # bypass kube-proxy hop; required for
                                                          # pod-readiness gates
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
  alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
  alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:...
  alb.ingress.kubernetes.io/healthcheck-path: /health/ready
  alb.ingress.kubernetes.io/healthcheck-interval-seconds: "10"
  alb.ingress.kubernetes.io/target-group-attributes: >-
    deregistration_delay.timeout_seconds=30,
    load_balancing.algorithm.type=least_outstanding_requests,
    stickiness.enabled=false
  alb.ingress.kubernetes.io/load-balancer-attributes: >-
    idle_timeout.timeout_seconds=60,
    routing.http2.enabled=true,
    access_logs.s3.enabled=true,
    access_logs.s3.bucket=roboshop-alb-logs
  alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:...   # add WAF
  alb.ingress.kubernetes.io/shield-advanced-protection: "false"
```

Also enable **pod readiness gates** (label the namespace
`elbv2.k8s.aws/pod-readiness-gate-inject: enabled`) so a rolling update does not mark a pod
Ready before the ALB target group says `healthy` — this eliminates 502s during deploys.

**Path-routing note:** your frontend serves static only and the ALB routes `/api/*` directly.
Good — it avoids a needless nginx proxy hop, but it means **CORS and path rewriting are ALB
concerns**; document that.

---

## 4.9 ConfigMaps & Secrets

**Current State (very good).** Shared `roboshop-config` ConfigMap in the platform chart holds
infra wiring; services pull individual keys via `envFromConfigMapKeys`. Secrets come from AWS
Secrets Manager through **ExternalSecret** or **SecretProviderClass**. Nothing sensitive in Git.

**Improvements:**
1. Add the **checksum annotation** so a ConfigMap edit triggers a rollout (today it does not).
2. Prefer **Secrets Store CSI with `syncSecret: false`** for the highest-sensitivity values —
   the secret is mounted into the pod's tmpfs and never becomes a Kubernetes `Secret` object
   (which is only base64 in etcd, readable by anyone with `get secret`).
3. Set `refreshInterval: 1h` on `ExternalSecret` and add a **reloader** (stakater/reloader) so
   rotated secrets actually reach running pods.
4. Enable **EKS envelope encryption with a CMK** (Phase 3) so etcd secrets are KMS-encrypted.

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: roboshop-secrets
  annotations: { reloader.stakater.com/match: "true" }
spec:
  refreshInterval: 1h
  secretStoreRef: { name: aws-secretsmanager, kind: ClusterSecretStore }
  target:
    name: roboshop-secrets
    creationPolicy: Owner
    template: { type: Opaque }
  dataFrom:
    - extract: { key: roboshop/production/app }
```

---

## 4.10 Storage: PVC, StorageClass, StatefulSets

**Current State.** `gp3` StorageClass (encrypted, `WaitForFirstConsumer`, `allowVolumeExpansion`)
defined in the platform chart. Each datastore = 1 replica + one PVC (10Gi / 5Gi).

**`WaitForFirstConsumer` is correct** — with `Immediate`, EBS provisions in a random AZ and the
pod may be unschedulable.

**Problems:**
1. **No `VolumeSnapshotClass`, no snapshots, no backup.** (finding W6 — highest risk in repo)
2. `reclaimPolicy` not stated — must be `Retain` for datastores so a deleted PVC does not
   delete the volume.
3. gp3 IOPS/throughput not tuned — defaults are 3000 IOPS / 125 MiB/s; MySQL wants more.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: { name: gp3-retain }
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "6000"
  throughput: "250"
  encrypted: "true"
  kmsKeyId: arn:aws:kms:...:key/ebs
  fsType: ext4
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain            # ← non-negotiable for stateful data
---
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata: { name: ebs-snapclass }
driver: ebs.csi.aws.com
deletionPolicy: Retain
```

---

## 4.11 NetworkPolicy

**Current State (strong).** Namespace `default-deny-ingress`, then allows for DNS egress,
ALB→frontend, ALB→backend, svc↔svc, svc→datastore on 27017/3306/6379/5672.

**Gap: no default-deny *egress*.** A compromised `catalogue` pod can still call any host on the
internet — that is how data exfiltration and crypto-miners work.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-all }
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]     # ← add Egress
---
# Then allow only what's needed, e.g. DNS:
kind: NetworkPolicy
metadata: { name: allow-dns-egress }
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to: [{ namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system }},
             podSelector: { matchLabels: { k8s-app: kube-dns }}}]
      ports: [{ protocol: UDP, port: 53 }, { protocol: TCP, port: 53 }]
```

> **EKS caveat:** the AWS VPC CNI only enforces NetworkPolicy from v1.14+ with
> `ENABLE_NETWORK_POLICY=true`. If that flag is off, **your policies are decorative.** Verify
> with a `kubectl exec … curl` test — and codify it as a smoke test.

---

## 4.12 ServiceAccount, RBAC, Pod Security

**Current State.** One shared `roboshop` ServiceAccount, `automountServiceAccountToken: false`
everywhere. Excellent default.

**Improvements:**
1. **One SA per service** (finding S11) so IRSA policies are least-privilege and blast radius
   on compromise is one service.
2. **Pod Security Admission** on the namespace — this is the runtime backstop to Checkov:
   ```yaml
   metadata:
     labels:
       pod-security.kubernetes.io/enforce: restricted
       pod-security.kubernetes.io/enforce-version: v1.31
       pod-security.kubernetes.io/audit: restricted
       pod-security.kubernetes.io/warn: restricted
   ```
3. **RBAC:** you currently need none for workloads (good). For humans, bind EKS Access Entries
   → `view` for developers in `roboshop-dev`, `edit` in dev only, `admin` for SRE via a
   break-glass role that emits a CloudTrail event.

---

## 4.13 The elephant: stateful services are not HA

**Current State.** MongoDB, MySQL, Redis, RabbitMQ each = **1 replica, 1 EBS volume, no
backup, no replication**.

**Why it's a problem:** EBS volumes are AZ-scoped. AZ `ap-south-1b` degrades → the pod cannot
be rescheduled anywhere else → the service is down until the AZ returns. If the volume is
damaged, **the data is gone permanently**.

**Three options, in order of preference:**

| Option | What | Trade-off |
|---|---|---|
| **A. Managed AWS services (recommended for prod)** | MongoDB→DocumentDB, MySQL→RDS Multi-AZ (or Aurora), Redis→ElastiCache Multi-AZ, RabbitMQ→Amazon MQ | Automatic failover, PITR, patching, backups — for money. Removes 4 StatefulSets from the cluster |
| **B. Kubernetes Operators** | Percona XtraDB Operator, MongoDB Community Operator, Redis Sentinel/Cluster, RabbitMQ Cluster Operator | Real HA in-cluster, portable, free — but *you* are now the DBA |
| **C. Keep single-replica + protect it** | `reclaimPolicy: Retain`, daily `VolumeSnapshot` + AWS Backup cross-region, logical dumps to S3, tested restore runbook, documented RTO/RPO | Cheapest; honest about being a dev/portfolio topology |

**Minimum acceptable today:** option C, immediately. Even in a portfolio project, saying
"single-replica MySQL with a tested 20-minute restore from snapshot, RPO 24h" is a *senior*
answer. Saying nothing is a junior one.

```yaml
# automation/backup/mysql-logical-backup.yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: mysql-logical-backup, namespace: roboshop }
spec:
  schedule: "0 2 * * *"
  successfulJobsHistoryLimit: 3
  jobTemplate:
    spec:
      backoffLimit: 2
      template:
        spec:
          serviceAccountName: backup            # IRSA → s3:PutObject on the backup bucket
          restartPolicy: OnFailure
          containers:
            - name: dump
              image: <ecr>/roboshop/mysql-backup:1.0.0
              command: ["/bin/sh","-c"]
              args:
                - |
                  set -euo pipefail
                  TS=$(date -u +%Y%m%dT%H%M%SZ)
                  mysqldump -h mysql -u root -p"$MYSQL_ROOT_PASSWORD" \
                    --single-transaction --routines --triggers --all-databases \
                  | gzip -9 > /tmp/mysql-$TS.sql.gz
                  aws s3 cp /tmp/mysql-$TS.sql.gz \
                    s3://roboshop-backups/mysql/$TS.sql.gz --sse aws:kms
              envFrom: [{ secretRef: { name: roboshop-secrets } }]
```

---

## 4.14 Production checklist (per workload)

- [ ] 3+ replicas, spread across 3 AZs (`DoNotSchedule`) **and** hosts (`ScheduleAnyway`)
- [ ] `maxUnavailable: 1` PDB (never on a 1-replica workload)
- [ ] `maxUnavailable: 0 / maxSurge: 1` rolling update ✅ *already done*
- [ ] Distinct `/health/live`, `/health/ready`, `/health/started`
- [ ] `preStop: sleep 15` + `terminationGracePeriodSeconds: 60` + graceful SIGTERM in-app
- [ ] CPU request, **no** CPU limit; memory request == limit
- [ ] `runAsNonRoot`, read-only rootfs, drop ALL caps, `RuntimeDefault` seccomp ✅ *already done*
- [ ] `automountServiceAccountToken: false` ✅ *already done*
- [ ] Own ServiceAccount + least-privilege IRSA
- [ ] Image referenced by **digest**, from ECR, signed, scanned
- [ ] Default-deny ingress **and** egress NetworkPolicy
- [ ] `PriorityClass` set
- [ ] ServiceMonitor + dashboard + alert rules (Phase 8)
- [ ] `checksum/config` annotation on the pod template
- [ ] Chart has `values.schema.json` and `helm-unittest` coverage

---

**Next:** [Phase 5 — GitOps](./04-gitops.md)
