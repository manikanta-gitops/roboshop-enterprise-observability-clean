> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 9 — Production Readiness

Every item follows: **Current State → Problem → Why → Best Practice → Implementation.**

---

## 9.1 High Availability

### Stateless tier — **7/10**

**Current:** prod `replicaCount: 3`, HPA min 3 / max 12, zone topology spread with
`DoNotSchedule`, PDB `minAvailable: 2`, `maxUnavailable: 0 / maxSurge: 1`.

**Problems:** (a) no host-level spread → 3 pods can share a node; (b) `shipping`/`payment`
have no HPA; (c) `minAvailable: 2` on an HPA'd workload breaks drains at low replica counts;
(d) no `preStop` drain → 502s during rollouts.

**Fix:** dual topology spread (zone hard + hostname soft), `maxUnavailable: 1` PDBs, enable HPA
on all six services, `preStop: sleep 15` with `terminationGracePeriodSeconds: 60`, and ALB pod
readiness gates. Details in Phase 4 §4.2/§4.6/§4.7/§4.8.

### Stateful tier — **2/10 (the critical gap)**

**Current:** MongoDB, MySQL, Redis, RabbitMQ each = 1 replica, 1 AZ-pinned EBS volume, no
replication, no backup.

**Why it's a problem:** an AZ impairment makes the pod unschedulable *and* the data
unreachable. Volume corruption = permanent loss. During any node upgrade, each datastore is
down for the duration of the reschedule.

**Fix — pick one and document it:**

| Target | Implementation | RTO | RPO |
|---|---|---|---|
| **Managed AWS (recommended)** | RDS MySQL Multi-AZ, DocumentDB 3-node, ElastiCache Redis Multi-AZ w/ automatic failover, Amazon MQ RabbitMQ cluster | 60–120s automatic | 0–5 min (PITR) |
| **In-cluster operators** | Percona XtraDB Operator (3 nodes), MongoDB replica set (3), Redis Sentinel (3+3), RabbitMQ Cluster Operator (3, quorum queues) | 15–30s | ~0 (sync repl) |
| **Keep single-replica + protect** | `reclaimPolicy: Retain`, hourly `VolumeSnapshot`, nightly logical dump to S3 cross-region, tested restore runbook | 30–60 min manual | 1–24 h |

The third option is acceptable for a portfolio/dev platform **only if you state the RTO/RPO
explicitly**. Silent single points of failure are the problem, not single replicas.

### Control plane

EKS control plane is Multi-AZ by AWS. Your responsibilities: 3 AZs of nodes, ArgoCD HA
(controller sharded ×2, repo-server ×3, Redis HA ×3), Prometheus HA pair with Thanos, and
CoreDNS ≥2 replicas with an anti-affinity rule + PDB.

---

## 9.2 Scalability — **6/10**

| Layer | Current | Target |
|---|---|---|
| Pods | HPA on 4/6 services, CPU-only, no `behavior` | HPA on all 6 + `behavior` tuning + KEDA queue-depth scaling for `payment` |
| Nodes | none defined | Karpenter NodePools (or Cluster Autoscaler across 3 AZ ASGs) |
| Requests | hand-guessed | VPA in recommender mode → set requests to observed p95 |
| Datastores | vertical only | read replicas (Mongo secondaries / RDS read replicas), Redis cluster mode |
| Edge | single ALB | ALB + CloudFront for static assets, WAF rate limiting |

```yaml
# Karpenter — replaces static node groups, provisions the exact shape needed in ~40s
apiVersion: karpenter.sh/v1
kind: NodePool
metadata: { name: roboshop }
spec:
  template:
    spec:
      requirements:
        - { key: karpenter.sh/capacity-type, operator: In, values: ["spot","on-demand"] }
        - { key: kubernetes.io/arch,         operator: In, values: ["amd64"] }
        - { key: karpenter.k8s.aws/instance-family, operator: In, values: ["m6i","m6a","m5","c6i"] }
        - { key: karpenter.k8s.aws/instance-size,   operator: NotIn, values: ["nano","micro","small"] }
      nodeClassRef: { group: karpenter.k8s.aws, kind: EC2NodeClass, name: roboshop }
      expireAfter: 720h            # forced node rotation = automatic patching
  limits: { cpu: "200", memory: 800Gi }
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 1m
    budgets: [{ nodes: "10%" }]    # never churn more than 10% at once
```

**Load-test before you claim a number.** k6 scenario: ramp 0→500 VUs over 5 min on the
browse→cart→checkout path; record p95, error rate, pods at peak, node count, and cost. That
turns "it scales" into "it serves 2,400 rps at p95 180ms on 9 pods / 4 nodes."

---

## 9.3 Disaster Recovery — **1/10**

**Current:** no backups, no snapshots, no restore procedure, no documented RTO/RPO.

**Define the targets first** (you cannot design DR without them):

| Tier | Components | RTO | RPO |
|---|---|---|---|
| 1 — critical | MySQL (orders/shipping), MongoDB (users) | 1 h | 15 min |
| 2 — important | RabbitMQ, Redis (cache — rebuildable) | 4 h | 1 h / n-a |
| 3 — rebuildable | Cluster, add-ons, apps (all in Git + Terraform) | 2 h | 0 (Git is the source of truth) |

**Backup matrix**

| What | Method | Frequency | Retention | Where |
|---|---|---|---|---|
| EBS volumes | AWS Backup by tag `Backup=roboshop` | daily 03:00 + hourly for tier 1 | 35 d | + cross-region copy |
| MySQL logical | `mysqldump --single-transaction` CronJob → S3 | daily | 90 d → Glacier | S3 versioned + Object Lock |
| MongoDB logical | `mongodump` CronJob → S3 | daily | 90 d | S3 |
| K8s objects | Velero (namespace + PV snapshots) | 6-hourly | 30 d | S3 |
| Terraform state | S3 versioning + replication | every apply | ∞ | cross-region bucket |
| ArgoCD config | `argocd admin export` CronJob | daily | 30 d | S3 |
| Secrets Manager | AWS built-in versioning + cross-region replica | continuous | — | second region |
| ECR images | cross-region replication rule | on push | lifecycle | second region |

**Recovery scenarios and procedures:**

1. **Pod lost** → Deployment/STS reschedules. RTO ~30s. No action.
2. **Node lost** → Karpenter/CA replaces; pods reschedule. Stateful pod waits for the EBS
   volume to detach (~6 min) and can only land in the same AZ.
3. **AZ lost** → stateless survives (3-AZ spread). **Stateful does not** without HA — restore
   the latest snapshot into a surviving AZ. This is the case that justifies §9.1.
4. **Cluster lost** →
   ```bash
   cd infrastructure/environments/production && terraform apply     # ~20 min
   aws eks update-kubeconfig --name roboshop-production
   ./platform/bootstrap/argocd-install.sh                            # ~3 min
   kubectl apply -f gitops/bootstrap/root-production.yaml            # ~10 min to converge
   ./automation/scripts/restore-db.sh --from s3://roboshop-backups/latest
   ./automation/scripts/smoke-test.sh https://roboshop.example.com
   ```
   **Total RTO ≈ 45 min** — achievable *only* because Terraform + GitOps exist. This is the
   single strongest argument for Phase 3.
5. **Region lost** → pilot-light: Terraform in `us-west-2` with `desired_size: 0`, ECR + S3 +
   Secrets Manager replicated, Route53 failover record with a health check. RTO ~2 h.
6. **Data corruption / bad migration** → restore from a point-in-time logical dump into a
   *scratch* namespace, verify, then cut over. Never restore over live data.
7. **Ransomware / malicious delete** → S3 Object Lock (WORM) + versioning + MFA delete on the
   backup bucket; backup account is separate with no cross-account write from prod.

**Non-negotiable: test the restore.** A quarterly game day — actually delete a namespace in
staging and time the recovery. An untested backup is a hypothesis, not a backup.

---

## 9.4 Cost Optimisation — **2/10**

| Lever | Saving | Effort |
|---|---|---|
| Spot for stateless (`payment`, `catalogue`, `cart`, `frontend`) | up to −70% on that pool | low — pool + tolerations exist already |
| Karpenter consolidation | −20–40% via bin-packing | medium |
| Graviton (`m7g`, `c7g`) — Node/Java/Python all support arm64 | −20% | medium (multi-arch builds, already in Phase 6) |
| VPC endpoints for ECR/S3/STS/Logs | kills NAT data-processing charges | low |
| `single_nat_gateway` in dev/qa | −$64/mo | low |
| Rightsize requests from VPA p95 | −30% cluster size | medium |
| S3 lifecycle: logs/backups → IA → Glacier | −60% storage | low |
| CloudWatch log retention 30d (not "never expire") | large, silently | low |
| Scale dev/qa to zero nights + weekends (CronJob or Karpenter schedule) | −65% on non-prod | low |
| gp3 instead of gp2, right-sized IOPS | −20% EBS | low |
| Savings Plans on the steady baseline | −30% compute | low (finance) |

**Make cost visible:** OpenCost/Kubecost per namespace, AWS Budgets with anomaly detection,
and mandatory cost-allocation tags (`Project`, `Environment`, `Owner`, `CostCenter` — already
in the Terraform `default_tags`). Put a cost panel on the platform dashboard; teams optimise
what they can see.

---

## 9.5 Performance

- **Establish a baseline** with k6 before optimising. Record p50/p95/p99 and rps at a fixed
  concurrency; re-run on every release and fail the pipeline on regression >20%.
- **CPU limits off** (Phase 4 §4.4) — removes CFS throttling latency.
- **Connection pooling:** Node `mongodb` driver `maxPoolSize`, HikariCP sizing for `shipping`
  (`maximumPoolSize ≈ (core_count * 2) + effective_spindles`, not 100).
- **Caching:** Redis already fronts `cart`; add catalogue read caching with a TTL and a
  cache-stampede guard.
- **Static assets:** CloudFront in front of the ALB for `frontend`; `Cache-Control: immutable`
  on hashed assets. Removes most of the traffic from the cluster.
- **HTTP keep-alive** between services; ALB `idle_timeout` ≥ app keep-alive to avoid 502s.
- **JVM:** `-XX:MaxRAMPercentage=75 -XX:+UseG1GC` — never a fixed `-Xmx` in a container.
- **Node.js:** the event loop is single-threaded — scale horizontally, and watch
  `nodejs_eventloop_lag_seconds` as the real saturation signal (not CPU).

---

## 9.6 Upgrade Strategy

**Cluster (quarterly, EKS supports n-2):**

```text
1. Read the Kubernetes changelog + EKS release notes for removed APIs
2. Run `pluto`/`kubent` against the cluster and against ci/_rendered → find deprecated APIs
3. Upgrade dev → soak 1 week → qa → staging → production (never skip a minor version)
4. Control plane first, then add-ons (VPC CNI, CoreDNS, kube-proxy — version matrix matters),
   then node groups
5. Node upgrade = rolling replacement. Requires: correct PDBs (see §9.1!), `maxUnavailable: 1`,
   and a maintenance window
6. Validate: smoke tests + all SLOs green for 24h before the next environment
```

> **Your PDB bug will surface here.** `minAvailable: 1` on a 1-replica StatefulSet blocks
> `kubectl drain` indefinitely and stalls the node upgrade. Fix it before your first upgrade.

**Application:** rolling by default, canary for risky changes (§9.7).
**Database migrations:** always **expand → migrate → contract**, never a breaking change in
one release. Run as an ArgoCD `PreSync` hook that is idempotent and has a tested down-path.

---

## 9.7 Progressive Delivery — **0/10 today**

**Current:** rolling update only; `make rollback RELEASE=cart` fights ArgoCD self-heal.

**Best practice: Argo Rollouts** — swap `kind: Deployment` for `kind: Rollout` in the library
chart (`common.rollout`) and everything else stays identical.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: { name: catalogue }
spec:
  replicas: 6
  strategy:
    canary:
      canaryService: catalogue-canary
      stableService: catalogue-stable
      trafficRouting:
        alb: { ingress: roboshop, servicePort: 8080 }
      analysis:
        templates: [{ templateName: success-rate-and-latency }]
        startingStep: 1
        args: [{ name: service, value: catalogue }]
      steps:
        - setWeight: 5
        - pause: { duration: 5m }      # analysis runs continuously from here
        - setWeight: 20
        - pause: { duration: 10m }
        - setWeight: 50
        - pause: { duration: 10m }
        - setWeight: 100
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: { name: success-rate-and-latency }
spec:
  args: [{ name: service }]
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.99
      failureLimit: 2                  # 2 bad samples → automatic rollback
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            sum(rate(http_request_duration_seconds_count{service="{{args.service}}",status!~"5.."}[2m]))
            / sum(rate(http_request_duration_seconds_count{service="{{args.service}}"}[2m]))
    - name: p95-latency
      interval: 1m
      successCondition: result[0] < 0.5
      failureLimit: 2
      provider:
        prometheus:
          address: http://prometheus.monitoring:9090
          query: |
            histogram_quantile(0.95,
              sum by (le) (rate(http_request_duration_seconds_bucket{service="{{args.service}}"}[2m])))
```

| Strategy | Use for | Cost | Rollback speed |
|---|---|---|---|
| Rolling | routine, low-risk | none | minutes (new rollout) |
| **Canary + analysis** | default for prod services | ~5% extra capacity | **seconds, automatic** |
| Blue/Green | database-coupled or big-bang releases | 2× capacity briefly | instant (switch the service selector) |
| Feature flags | decouple deploy from release; test in prod safely | flag service | instant, per-user |

**Rollback policy in a GitOps world:** the *correct* rollback is `git revert` of the
`images.yaml` commit — ArgoCD then converges. `helm rollback` and `kubectl rollout undo` create
drift that self-heal will erase. Argo Rollouts' automatic abort is the fast path; the Git
revert is the durable one. Document both, and **practise them**.

---

## 9.8 Compliance & Audit

- **Evidence generation, not screenshots:** kube-bench JSON → S3 (weekly), Kyverno
  PolicyReports → exported, Trivy/Checkov SARIF → GitHub Security tab, CloudTrail → S3 with
  Object Lock + log-file validation.
- **Change management:** every production change is a PR with a CODEOWNERS approval, a linked
  issue, and a green pipeline. `git log gitops/environments/production/` **is** your change log.
- **Access review:** quarterly review of EKS Access Entries, IAM roles, ArgoCD RBAC groups,
  GitHub org permissions.
- **Data:** classify what's in MySQL/MongoDB (PII in `user`, payment references in `payment`).
  Encryption at rest (KMS on EBS/RDS/S3) and in transit (TLS at the ALB; mTLS in-cluster via a
  service mesh if required). Define retention and a deletion path (GDPR right-to-erasure).
- **Frameworks worth naming:** CIS Kubernetes Benchmark, AWS Foundational Security Best
  Practices via Security Hub, SOC 2 CC6/CC7/CC8, PCI-DSS if real card data ever flows through
  `payment` (it does not here — say so explicitly).

---

## 9.9 Production readiness checklist

```text
INFRASTRUCTURE
[ ] Terraform for 100% of infra; no click-ops; state in S3 + DynamoDB lock
[ ] 3 AZs; private nodes; NAT per AZ; VPC endpoints; flow logs on
[ ] KMS CMKs with rotation; EKS envelope encryption for secrets
[ ] Nightly drift detection (terraform plan -detailed-exitcode)

KUBERNETES
[ ] 3+ replicas, dual topology spread, correct PDBs, PriorityClasses
[ ] Distinct live/ready/startup probes; preStop drain; grace period > drain
[ ] CPU requests (no CPU limits); memory request == limit
[ ] metrics-server + HPA on every user-facing service + node autoscaling
[ ] Default-deny ingress AND egress; PSA restricted; per-service SA + IRSA

DELIVERY
[ ] App CI: test → scan → build → scan → sign → push → SBOM
[ ] GitOps write-back; promotion via PR; ArgoCD automated + selfHeal + prune
[ ] Canary with automated metric analysis and abort
[ ] Rollback tested and documented (git revert path)

RESILIENCE
[ ] Datastores HA or an explicitly accepted, documented RTO/RPO
[ ] Backups: snapshot + logical + Velero, cross-region, versioned, WORM
[ ] Restore TESTED in the last 90 days (dated evidence)
[ ] Game day run: AZ failure, node loss, bad deploy

OBSERVABILITY
[ ] RED metrics per service; USE per node; datastore exporters
[ ] SLOs defined with multi-burn-rate alerts; every alert has a runbook_url
[ ] Centralised structured logs with correlation IDs
[ ] Distributed tracing across the async RabbitMQ hop

SECURITY
[ ] Signed images enforced at admission; ECR-only; digest-pinned
[ ] Kyverno enforcing; Falco alerting; kube-bench evidence archived
[ ] Secrets from Secrets Manager via IRSA; rotation tested
[ ] No long-lived cloud credentials anywhere in CI

OPERATIONS
[ ] Runbooks for the top 10 alerts; on-call rotation; escalation path
[ ] Cost dashboard + budget alarms; tagging enforced
[ ] Upgrade calendar; documented n-2 policy
[ ] Post-incident review template; blameless culture
```

---

**Next:** [Phase 10 — Documentation set](./09-documentation.md)
