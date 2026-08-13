> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 10 — The Documentation Set

Your repo already has `README.md`, `DECISIONS.md`, `INTERVIEW_GUIDE.md` and
`MODERNIZATION_NOTES.md` — genuinely above average. What is missing is everything an
**operator** needs at 3am. This phase supplies the templates and the content.

**Score: 7/10 → target 10/10.** Documentation-as-code: lives in `docs/`, versioned with the
code, reviewed in the same PR, and CI fails if a new chart has no doc entry.

---

## 10.1 Enterprise `README.md` (root)

````markdown
<div align="center">

# Roboshop Platform
**Production-grade e-commerce microservices platform on Amazon EKS**

[![helm-ci](badge)](link) [![app-ci](badge)](link) [![security](badge)](link)
[![terraform](badge)](link) [![license](badge)](link)

</div>

## What this is
A 6-service polyglot e-commerce platform (Node.js, Java/Spring, Python, nginx) running on
EKS, delivered by GitOps, provisioned by Terraform, observed by Prometheus/Loki/Tempo, and
secured end-to-end from pre-commit hook to admission controller.

## Quick start (15 minutes)
```bash
git clone https://github.com/roboshop/roboshop-platform && cd roboshop-platform
make prereqs-check          # verifies every tool in docs/prerequisites.md
make dev-up                 # kind cluster + charts + seed data
open http://localhost:8080
```

## Architecture
[C4 context and container diagrams — docs/architecture/]

| Service | Language | Port | Datastore | Scaling | Owner |
|---|---|---|---|---|---|
| frontend | nginx (static) | 8080 | – | HPA 3–12 | @web |
| catalogue | Node 20 | 8080 | MongoDB | HPA 3–12 | @catalog |
| user | Node 20 | 8080 | MongoDB + Redis | HPA 3–12 | @identity |
| cart | Node 20 | 8080 | Redis | HPA 3–12 | @checkout |
| shipping | Java 21 / Spring | 8080 | MySQL | HPA 3–8 | @fulfilment |
| payment | Python 3.12 | 8080 | RabbitMQ | KEDA (queue) | @payments |

## Repository map
| Path | Purpose | Owner |
|---|---|---|
| `apps/` | application source + Dockerfiles | app teams |
| `infrastructure/` | Terraform (bootstrap, modules, environments) | @cloud |
| `charts/` | Helm library + service charts | @platform |
| `gitops/` | ArgoCD desired state — the only path ArgoCD reads | @platform + @sre |
| `platform/` | cluster add-ons | @platform |
| `monitoring/` `security/` | observability + policy-as-code | @sre / @security |
| `docs/` | this documentation set | everyone |

## Documentation
| Doc | Read it when |
|---|---|
| [Prerequisites](docs/prerequisites.md) | before your first command |
| [Developer guide](docs/developer-guide.md) | you're shipping a feature |
| [Platform guide](docs/platform-guide.md) | you're changing a chart or add-on |
| [Infrastructure](docs/infrastructure.md) | you're touching Terraform |
| [CI/CD](docs/cicd.md) | a pipeline failed |
| [GitOps](docs/gitops.md) | ArgoCD is OutOfSync |
| [Production deployment](docs/production-deployment.md) | you're releasing |
| [**Runbook**](docs/runbook.md) | **you're on call and something is broken** |
| [Troubleshooting](docs/troubleshooting.md) | a symptom you don't recognise |
| [Disaster recovery](docs/disaster-recovery.md) | something is *really* broken |
| [ADRs](docs/architecture/adr/) | "why is it built this way?" |

## Status
| Env | URL | Cluster | ArgoCD |
|---|---|---|---|
| dev | https://dev.roboshop.example.com | roboshop-dev | [link] |
| production | https://roboshop.example.com | roboshop-production | [link] |

## Contributing
Conventional commits · PR + CODEOWNERS approval · all checks green · signed commits.
Production changes need 2 approvals and land inside a sync window.
````

---

## 10.2 Architecture documentation (`docs/architecture/`)

Use the **C4 model** — four zoom levels, no more:

1. **Context** — users, Roboshop, and external systems (payment gateway, DNS, email).
2. **Container** — the six services, four datastores, ALB, and the protocols between them.
3. **Component** — inside one service (only for the complex ones: `shipping`, `payment`).
4. **Code** — skip it; the code is the documentation.

Plus **deployment diagrams**: AWS account → VPC → 3 AZs → EKS → node pools → namespaces.

**ADRs** (`docs/architecture/adr/NNNN-title.md`) — one file per significant decision, never
edited, only superseded:

```markdown
# ADR-0007: Use a Helm library chart instead of per-service duplicated templates

- Status: Accepted
- Date: 2026-08-06
- Deciders: @platform-engineering
- Supersedes: —

## Context
Eleven workloads shared ~1,300 lines of near-identical YAML. Adding a securityContext field
meant eleven edits and eleven chances to miss one.

## Decision
Create `charts/common` as a Helm `type: library` chart exposing `common.deployment`,
`common.service`, `common.hpa`, etc. Every service template becomes a one-line `include`.

## Consequences
+ One edit changes all eleven charts; drift becomes structurally impossible.
+ Enforced consistency of labels, probes, and security context.
− A bug in `common` breaks everything → mitigated by helm-unittest + golden files.
− Templates are harder to read for newcomers → mitigated by NOTES.txt and this ADR.

## Alternatives considered
Kustomize bases/overlays (rejected: no packaging/versioning story for OCI distribution).
cdk8s (rejected: adds a language runtime to the delivery path).
```

Suggested initial ADR set: 0001 EKS over ECS · 0002 GitOps with ArgoCD over push CD ·
0003 Helm over Kustomize · 0004 External Secrets over Sealed Secrets · 0005 single shared ALB ·
0006 Terraform layer/state split · 0007 library chart · 0008 in-cluster datastores vs managed
(**document the trade-off you accepted**) · 0009 Kyverno over Gatekeeper · 0010 Loki over
OpenSearch.

---

## 10.3 Runbook (`docs/runbook.md`) — the most valuable doc you don't have

Structure **one section per alert**, and put the `runbook_url` in the alert itself.

````markdown
# Runbook

## On-call quick reference
| | |
|---|---|
| Escalation | L1 on-call → @platform-lead (15m) → @cto (30m) |
| Status page | https://status.roboshop.example.com |
| War room | #incident-response |
| Prod dashboard | https://grafana…/d/roboshop-overview |
| ArgoCD | https://argocd… |

### Golden commands
```bash
aws eks update-kubeconfig --name roboshop-production --region ap-south-1
kubectl -n roboshop get pods -o wide --sort-by=.status.startTime
kubectl -n roboshop get events --sort-by=.lastTimestamp | tail -40
argocd app list -p roboshop
kubectl -n roboshop logs -l app.kubernetes.io/name=cart --tail=200 --since=15m
```

---

## ALERT: CatalogueErrorBudgetBurnFast
**Severity:** critical · **Impact:** users cannot browse products · **Budget:** burning 14.4×

### 1. Assess (2 min)
```bash
kubectl -n roboshop get deploy,pods -l app.kubernetes.io/name=catalogue
kubectl -n roboshop logs -l app.kubernetes.io/name=catalogue --tail=100 | grep -i error
```
Open the Catalogue RED dashboard. Is it errors, latency, or availability?

### 2. Did something change? (1 min)
```bash
git log --oneline -10 gitops/environments/production/images.yaml
argocd app history roboshop-production-catalogue
```
**If a deploy landed within 30 minutes → roll back first, diagnose second.**
```bash
git revert --no-edit <sha> && git push        # ArgoCD converges in ~1 min
```

### 3. Common causes
| Symptom | Cause | Action |
|---|---|---|
| `MongoNetworkError` in logs | MongoDB pod down / PVC full | see *MongoDB unavailable* below |
| p95 up, errors flat | HPA at ceiling | `kubectl -n roboshop get hpa`; raise `maxReplicas` |
| 503 from the ALB | no healthy targets | check readiness probes + target group health |
| OOMKilled restarts | memory limit too low | bump memory request/limit, then investigate the leak |

### 4. Mitigate
```bash
kubectl -n roboshop scale deploy/catalogue --replicas=10   # temporary; ArgoCD will revert
# permanent: PR raising autoscaling.minReplicas in charts/catalogue/values-production.yaml
```

### 5. Verify & close
SLO burn back under 1× for 15 min · smoke test green · post in #incidents ·
create the post-incident review issue within 24h.
````

Write one of these for each of: `PodCrashLooping`, `PVCAlmostFull`, `RabbitMQQueueBacklog`,
`MySQLConnectionPoolExhausted`, `NodeNotReady`, `ArgoCDAppOutOfSync`, `CertificateExpiringSoon`,
`HPAMaxedOut`, `MongoDB unavailable`, `ALB 5xx`.

---

## 10.4 Troubleshooting guide (`docs/troubleshooting.md`)

Symptom-first, not component-first — that's how people actually search.

| Symptom | Likely cause | Diagnose | Fix |
|---|---|---|---|
| Pod `Pending` | no node fits; `DoNotSchedule` topology; PVC in another AZ | `kubectl describe pod` → Events | scale nodes; relax spread; check StorageClass binding mode |
| Pod `CrashLoopBackOff` | bad config; missing secret; failing liveness | `logs --previous`; `describe` | fix env/secret; check `/health/live` isn't checking the DB |
| Pod `ImagePullBackOff` | wrong tag; no ECR permission; rate limit | `describe pod` | verify digest in `images.yaml`; check node IAM/ECR policy |
| `CreateContainerConfigError` | ConfigMap/Secret key missing | `describe pod` | `kubectl get secret roboshop-secrets -o yaml`; check the ExternalSecret status |
| ExternalSecret not `Ready` | IRSA misconfigured; secret path wrong | `kubectl describe externalsecret` | verify the SA annotation and the Secrets Manager ARN |
| HPA shows `<unknown>` | **metrics-server missing** | `kubectl top pods` | install metrics-server |
| Ingress has no ADDRESS | LB controller missing/misconfigured | `kubectl -n kube-system logs deploy/aws-load-balancer-controller` | check IRSA + subnet tags |
| 502/504 from the ALB | no `preStop` drain; readiness flapping; idle timeout | ALB target group health; pod events | add `preStop: sleep 15`; align timeouts |
| Cross-service call refused | NetworkPolicy blocks it | `kubectl exec … nc -zv svc 8080` | add the explicit allow; confirm the CNI enforces policy |
| ArgoCD `OutOfSync` forever | out-of-bounds valueFile; missing `automated`; a controller mutates the object | `argocd app diff` | fix the source; add `ignoreDifferences` |
| ArgoCD `Progressing` forever | resource with no health check; hook Job never completes | `argocd app get` | add a Lua health check; set `activeDeadlineSeconds` |
| `kubectl drain` hangs | **PDB unsatisfiable on a 1-replica workload** | `kubectl get pdb` | `ALLOWED DISRUPTIONS: 0` → fix the PDB |
| Terraform "state locked" | a previous run died | `terraform force-unlock <id>` | only after proving the other run is dead |

---

## 10.5 The remaining documents (purpose + table of contents)

| Doc | Audience | Must contain |
|---|---|---|
| `infrastructure.md` | cloud engineers | layer/state model, module reference, apply order, IAM matrix, network CIDR plan, cost model, drift procedure |
| `cicd.md` | all engineers | every workflow, trigger, required secret/variable, how to re-run, how to debug a failed job, branch protection rules |
| `gitops.md` | platform/SRE | ArgoCD topology, AppProject guardrails, sync waves, how to add a service, how to promote, how to roll back, sync windows |
| `developer-guide.md` | app devs | local setup, `make dev-up`, running one service against port-forwarded datastores, writing tests, commit conventions, opening a PR, reading pipeline output |
| `platform-guide.md` | platform engineers | adding a chart, changing `common`, adding a values key, add-on upgrades, cluster upgrade procedure, on-boarding a new environment |
| `production-deployment.md` | release manager | the full promotion path, pre-flight checklist, change window rules, canary observation checklist, go/no-go criteria, rollback decision tree, post-deploy verification |
| `disaster-recovery.md` | SRE | RTO/RPO table, backup inventory, the seven recovery scenarios (§9.3), exact restore commands, game-day schedule, last-tested date **per scenario** |
| `prerequisites.md` | everyone | Phase 11 |
| `roadmap.md` | leadership | Phase 12 |
| `interview-guide.md` | you | Phase 12 doc + the Q&A bank |

---

## 10.6 "Explain this project" — the 90-second version

> "Roboshop is a polyglot e-commerce platform — six microservices in Node, Java and Python
> plus MongoDB, MySQL, Redis and RabbitMQ — running on Amazon EKS across three availability
> zones.
>
> **Infrastructure** is 100% Terraform, split into five state layers (bootstrap, foundation,
> platform, add-ons, workload support) with S3 remote state and DynamoDB locking, so I can
> rebuild the entire account from an empty AWS account in about 45 minutes.
>
> **Packaging** is Helm with a library chart: eleven workloads share one set of templates, so
> a security-context change is a single edit instead of eleven. Four environments layer values
> on top.
>
> **Delivery** is pull-based GitOps. GitHub Actions builds, tests, scans with Trivy and CodeQL,
> signs with Cosign, attaches an SBOM, pushes to ECR by digest, and then writes the digest into
> a `gitops/environments/<env>/images.yaml` file via a pull request. ArgoCD reconciles that.
> CI never holds cluster credentials — the only thing it can touch is ECR and a Git branch.
>
> **Security** is layered at four gates: pre-commit secret scanning, CI SAST/SCA/image scanning,
> registry signing with immutable tags, and Kyverno at admission refusing to run any image that
> isn't signed and from our own ECR. Falco watches syscalls at runtime.
>
> **Observability** is Prometheus for RED metrics, Loki for structured logs, Tempo for traces
> that follow a request across the async RabbitMQ hop, and SLOs with multi-burn-rate alerting
> so we only page when the error budget is genuinely at risk.
>
> The trade-off I'd call out is the datastores: they run in-cluster as single-replica
> StatefulSets, which is a deliberate cost decision with a documented RPO of one hour and a
> tested 30-minute restore. In a real production environment I'd move them to RDS Multi-AZ,
> DocumentDB and ElastiCache."

That paragraph — especially the last one — is what distinguishes a senior candidate.

---

**Next:** [Phase 11 — Prerequisites](./10-prerequisites.md)
