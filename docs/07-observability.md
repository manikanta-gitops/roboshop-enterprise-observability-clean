> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 8 — Observability

> **Current State: nothing.** No Prometheus, no ServiceMonitor, no dashboards, no alert rules,
> no log aggregation, no tracing — in a 6-service distributed system with 4 datastores and an
> async RabbitMQ path. **Score: 0/10.**
>
> **Why it's a problem:** when checkout fails, the question is "is it `cart`, `payment`, the
> RabbitMQ queue, or `shipping`'s MySQL connection pool?" With `kubectl logs` you will guess.
> Mean time to *identify* dominates MTTR in microservices, and identification is exactly what
> observability buys.

---

## 8.1 The three pillars, mapped to this stack

| Pillar | Question it answers | Stack | Retention |
|---|---|---|---|
| **Metrics** | *Is it broken? How badly? Since when?* | Prometheus → Thanos/AMP | 15d local, 1y in S3 |
| **Logs** | *What exactly happened in this request?* | Fluent Bit → Loki (S3) | 30d hot / 1y S3 |
| **Traces** | *Where in the 6-hop path did the latency come from?* | OTel SDK → Collector → Tempo/Jaeger | 7d, 10% sampled + 100% of errors |

Plus the fourth, often-forgotten one: **events & change tracking** — ArgoCD sync events,
deploy markers, and Kubernetes Events overlaid on dashboards. "What changed?" answers most
incidents faster than any dashboard.

---

## 8.2 Architecture

```text
   ┌───────────────────────── EKS cluster ─────────────────────────┐
   │                                                                │
   │  app pods ──/metrics──► ServiceMonitor ──┐                     │
   │  kubelet / cAdvisor ─────────────────────┤                     │
   │  kube-state-metrics ─────────────────────┼──► Prometheus ──────┼──► Thanos sidecar ──► S3
   │  node-exporter ──────────────────────────┤     (2 replicas,     │        (1y, downsampled)
   │  exporters: mongodb, mysqld, redis, ─────┘      HA pair)        │
   │             rabbitmq, blackbox                   │              │
   │                                                  ├──► Alertmanager ──► Slack
   │                                                  └──► Grafana ◄─────────┐
   │                                                                          │
   │  app stdout ──► Fluent Bit (DaemonSet) ──► Loki (S3 chunks) ─────────────┤
   │                                        └─► CloudWatch Logs (audit/compliance)
   │                                                                          │
   │  OTel SDK ──► OTel Collector (Deployment) ──► Tempo (S3) ────────────────┘
   │                     └──► Prometheus (span metrics: RED from traces)
   └────────────────────────────────────────────────────────────────┘
                     CloudWatch: EKS control-plane logs, ALB metrics,
                     Container Insights, RDS/ElastiCache (if adopted)
```

**Managed alternative:** Amazon Managed Prometheus (AMP) + Amazon Managed Grafana + OpenSearch.
Costs more, operates itself. For a portfolio project, self-hosted `kube-prometheus-stack`
demonstrates more skill; for a real team, managed is usually the right call.

---

## 8.3 Metrics — instrumentation per service

| Service | Exporter / library | Key metrics |
|---|---|---|
| `catalogue`, `user`, `cart` (Node) | `prom-client` + `express-prom-bundle` | `http_request_duration_seconds` histogram (route, method, status), `nodejs_eventloop_lag_seconds`, `nodejs_heap_size_used_bytes` |
| `shipping` (Spring Boot) | Micrometer + `spring-boot-starter-actuator` | `http_server_requests_seconds`, `hikaricp_connections_active/pending`, `jvm_gc_pause_seconds`, `jvm_memory_used_bytes` |
| `payment` (Python/uwsgi) | `prometheus_client` multiprocess mode | request histogram, `rabbitmq_publish_total`, `payment_amount_total` |
| `frontend` (nginx) | `nginx-prometheus-exporter` sidecar | `nginx_http_requests_total`, active connections |
| MongoDB | `percona/mongodb_exporter` | `mongodb_op_counters_total`, replication lag, connections, `WiredTiger` cache |
| MySQL | `prom/mysqld-exporter` | `mysql_global_status_threads_connected`, slow queries, InnoDB buffer pool hit ratio |
| Redis | `oliver006/redis_exporter` | hit rate, `evicted_keys`, `blocked_clients`, memory fragmentation |
| RabbitMQ | built-in `rabbitmq_prometheus` plugin | **`rabbitmq_queue_messages_ready`** (the one that matters), consumers, unacked, publish rate |
| Synthetic | `blackbox_exporter` | probe success + TLS cert expiry for `https://roboshop.example.com` |

```yaml
# Add to charts/common as common.servicemonitor, enabled per chart
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: {{ include "common.fullname" . }}
  labels: { release: kube-prometheus-stack }   # must match Prometheus' serviceMonitorSelector
spec:
  selector: { matchLabels: {{ include "common.selectorLabels" . | nindent 6 }} }
  endpoints:
    - port: http
      path: /metrics
      interval: 30s
      scrapeTimeout: 10s
      relabelings:
        - { sourceLabels: [__meta_kubernetes_pod_node_name], targetLabel: node }
        - { sourceLabels: [__meta_kubernetes_namespace],      targetLabel: environment }
```

**Cardinality warning:** never put a user id, cart id, or raw URL path into a label. One
`/api/cart/add/{uuid}/{sku}/{qty}` route as a label = millions of series = a dead Prometheus.
Use the *route template*, not the resolved path.

---

## 8.4 SLIs, SLOs and error budgets

Define SLOs for **user journeys**, not for CPU.

| # | User journey | SLI | SLO (30d) | Error budget |
|---|---|---|---|---|
| 1 | Browse catalogue | share of `GET /api/catalogue/*` with status<500 | 99.9% availability | 43m 12s |
| 2 | Browse catalogue | share of requests with latency < 300ms | 99% latency | — |
| 3 | Login / register | `POST /api/user/login` success rate | 99.9% | 43m |
| 4 | Add to cart | `POST /api/cart/add/*` success | 99.5% | 3h 36m |
| 5 | Checkout (payment) | `POST /api/payment/pay/*` success | 99.5% | 3h 36m |
| 6 | Order dispatch (async) | messages consumed from `payments` queue within 60s | 99% | — |

```yaml
# monitoring/rules/slo.yaml — multi-window multi-burn-rate (the Google SRE workbook pattern)
groups:
  - name: slo-catalogue-availability
    interval: 30s
    rules:
      # Recording rules: precompute the error ratio at several windows
      - record: sli:catalogue_errors:ratio5m
        expr: |
          sum(rate(http_request_duration_seconds_count{service="catalogue",status=~"5.."}[5m]))
          / sum(rate(http_request_duration_seconds_count{service="catalogue"}[5m]))
      - record: sli:catalogue_errors:ratio1h
        expr: |
          sum(rate(http_request_duration_seconds_count{service="catalogue",status=~"5.."}[1h]))
          / sum(rate(http_request_duration_seconds_count{service="catalogue"}[1h]))
      - record: sli:catalogue_errors:ratio6h
        expr: |
          sum(rate(http_request_duration_seconds_count{service="catalogue",status=~"5.."}[6h]))
          / sum(rate(http_request_duration_seconds_count{service="catalogue"}[6h]))

      # FAST burn: 14.4x budget burn over 1h+5m → 2% of the 30d budget in 1h → PAGE
      - alert: CatalogueErrorBudgetBurnFast
        expr: |
          sli:catalogue_errors:ratio5m > (14.4 * 0.001)
          and sli:catalogue_errors:ratio1h > (14.4 * 0.001)
        for: 2m
        labels: { severity: critical, team: platform, slo: catalogue-availability }
        annotations:
          summary: "Catalogue burning error budget 14.4x — page now"
          runbook_url: "https://github.com/roboshop/roboshop-platform/blob/main/docs/runbook.md#catalogue-5xx"

      # SLOW burn: 6x over 6h → TICKET, not a page
      - alert: CatalogueErrorBudgetBurnSlow
        expr: sli:catalogue_errors:ratio6h > (6 * 0.001)
        for: 15m
        labels: { severity: warning, team: platform }
```

**Why multi-burn-rate:** a naive `error_rate > 1%` alert either pages on every blip or misses
a slow bleed. Burn-rate alerting pages only when the *budget* is genuinely at risk, which is
what keeps on-call sustainable.

---

## 8.5 Alert rules that matter (beyond SLOs)

```yaml
groups:
  - name: roboshop-platform
    rules:
      - alert: PodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total{namespace=~"roboshop.*"}[15m]) * 900 > 3
        for: 5m
        labels: { severity: critical }

      - alert: DeploymentReplicasMismatch
        expr: |
          kube_deployment_spec_replicas{namespace=~"roboshop.*"}
            != kube_deployment_status_replicas_available{namespace=~"roboshop.*"}
        for: 15m
        labels: { severity: warning }

      - alert: HPAMaxedOut
        expr: |
          kube_horizontalpodautoscaler_status_current_replicas
            >= kube_horizontalpodautoscaler_spec_max_replicas
        for: 15m
        labels: { severity: warning }
        annotations: { summary: "HPA at ceiling — raise maxReplicas or investigate load" }

      - alert: PVCAlmostFull                      # your datastores are 5–10Gi. This WILL fire.
        expr: |
          kubelet_volume_stats_available_bytes / kubelet_volume_stats_capacity_bytes < 0.15
        for: 10m
        labels: { severity: critical }

      - alert: RabbitMQQueueBacklog
        expr: rabbitmq_queue_messages_ready{queue="payments"} > 1000
        for: 5m
        labels: { severity: critical }
        annotations: { summary: "payment consumers not keeping up — orders are delayed" }

      - alert: MySQLConnectionPoolExhausted
        expr: hikaricp_connections_pending{application="shipping"} > 5
        for: 5m

      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels: { severity: critical }

      - alert: CertificateExpiringSoon
        expr: probe_ssl_earliest_cert_expiry - time() < 14 * 86400
        labels: { severity: warning }

      - alert: ArgoCDAppOutOfSync
        expr: argocd_app_info{sync_status!="Synced",name=~"roboshop-production-.*"} == 1
        for: 30m
        labels: { severity: warning }
        annotations: { summary: "Production drift or a stuck sync" }
```

**Alertmanager routing:**

```yaml
route:
  group_by: [alertname, namespace, service]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: slack-platform
  routes:
    - matchers: [severity="critical", environment="production"]
      continue: true
    - matchers: [severity="warning"]
      receiver: slack-platform
    - matchers: [environment=~"dev|qa"]
      receiver: slack-noise
      repeat_interval: 24h
inhibit_rules:
  # If the node is down, don't also page for every pod on it.
  - source_matchers: [alertname="NodeNotReady"]
    target_matchers: [severity="critical"]
    equal: [node]
```

**Rule:** every alert must have a `runbook_url`. An alert without a runbook is a 3am puzzle.

---

## 8.6 Logging

```text
container stdout/stderr → /var/log/containers/*.log
        ↓ Fluent Bit DaemonSet (tail input, kubernetes filter enriches with pod/ns/labels)
        ├─► Loki  (S3 chunk store, 30d index, queried in Grafana with LogQL)
        └─► CloudWatch Logs (audit/security streams only — cheap retention for compliance)
```

**Why Loki over ELK/OpenSearch here:** Loki indexes only labels, storing log bodies as
compressed chunks in S3 → roughly 10× cheaper and it shares Grafana + the same label set as
Prometheus, so you can pivot from a metric spike straight to the logs of the exact pod. Choose
OpenSearch instead when you need full-text search over TBs, complex aggregations, or an
existing SIEM integration.

**Non-negotiables for app logs:**
1. **Structured JSON** to stdout. Never write log files inside a container (your rootfs is
   read-only anyway — good).
2. **Correlation IDs.** Propagate `X-Request-Id` / W3C `traceparent` across all six services
   and log it. Without it, you cannot reconstruct a request.
3. **Never log** JWTs, passwords, card data, or full request bodies.
4. Consistent fields: `ts, level, service, env, trace_id, span_id, request_id, msg`.

```yaml
# Fluent Bit — the kubernetes filter is what makes logs queryable
[FILTER]
    Name                kubernetes
    Match               kube.*
    Merge_Log           On          # parse JSON app logs into fields
    Keep_Log            Off
    Labels              On
    Annotations         Off
[OUTPUT]
    Name                loki
    Match               kube.*
    host                loki-gateway.monitoring.svc
    labels              job=fluentbit, namespace=$kubernetes['namespace_name'], app=$kubernetes['labels']['app_kubernetes_io/name']
    label_keys          $trace_id
    auto_kubernetes_labels off      # ← avoid label explosion
```

---

## 8.7 Tracing

Robot Shop is literally an APM demo app — tracing is the highest-value addition here.

```text
frontend (browser) ──traceparent──► ALB ──► cart ──► catalogue ──► mongodb
                                       └──► redis
                                       └──► payment ──► rabbitmq ──► shipping ──► mysql
```

- **Instrumentation:** OpenTelemetry auto-instrumentation — zero code change for Node
  (`@opentelemetry/auto-instrumentations-node`), Java (`-javaagent:opentelemetry-javaagent.jar`)
  and Python (`opentelemetry-instrument`). Use the **OpenTelemetry Operator** with
  `instrumentation.opentelemetry.io/inject-nodejs: "true"` pod annotations so it is a values
  change, not a code change.
- **Collector:** deployment mode, `otlp` receiver → `batch` + `memory_limiter` +
  `k8sattributes` processors → `tempo` exporter + `spanmetrics` connector (which generates RED
  metrics from traces for free).
- **Sampling:** tail-based — keep **100% of errors and slow traces**, 5–10% of the rest.
  Head sampling throws away the traces you actually need.
- **Context propagation across RabbitMQ** is the interesting bit: inject `traceparent` into
  message headers in `payment`, extract it in `shipping`. Without that, the async half of the
  order flow is a black hole.

---

## 8.8 Dashboards

| Dashboard | Audience | Panels |
|---|---|---|
| **Executive / SLO** | leadership | SLO attainment per journey, error budget remaining, deploys this week, MTTR trend |
| **Service RED** (one per service, templated) | on-call | Rate, Errors, Duration (p50/p95/p99), saturation, pod count, restarts, HPA position |
| **USE — nodes** | platform | Utilisation/Saturation/Errors for CPU, memory, disk, network per node pool |
| **Datastores** | platform | Mongo ops+connections, MySQL pool+slow queries, Redis hit rate+evictions, **RabbitMQ queue depth** |
| **Kubernetes health** | platform | Pending pods, OOMKills, evictions, PVC usage, node pressure conditions |
| **Delivery** | everyone | ArgoCD sync status, DORA metrics: deploy frequency, lead time, change-failure rate, MTTR |
| **Cost** | FinOps | Kubecost/OpenCost: $ per namespace, per service, idle vs requested |

Provision as ConfigMaps with the `grafana_dashboard: "1"` label — **dashboards are code**,
never hand-edited in the UI (they vanish on pod restart).

```yaml
# Annotate deploys on every dashboard so "what changed?" is one glance
annotations:
  list:
    - name: Deployments
      datasource: Prometheus
      expr: changes(kube_deployment_status_observed_generation{namespace="roboshop"}[1m]) > 0
      titleFormat: "Deploy: {{deployment}}"
```

---

## 8.9 CloudWatch — what stays in AWS

Do not try to move everything into Prometheus:

- **EKS control-plane logs** (api, audit, authenticator, scheduler, controllerManager) — you
  cannot scrape these; they only exist in CloudWatch. Add metric filters + alarms on
  `system:masters` usage and on authentication failures.
- **ALB metrics**: `TargetResponseTime`, `HTTPCode_ELB_5XX_Count`, `RejectedConnectionCount`,
  `UnHealthyHostCount` — the edge view your in-cluster Prometheus cannot see.
- **ALB access logs** → S3 → Athena for ad-hoc "who hit this endpoint" queries.
- **CloudTrail** → the audit trail for every AWS API call.
- **Container Insights** for a quick node/pod view without Grafana.
- **Cost & Usage Report** → the FinOps source of truth.

Bridge them: use the **CloudWatch Grafana datasource** so one Grafana shows in-cluster and AWS
metrics side by side.

---

## 8.10 Rollout order

```text
1. kube-prometheus-stack (Prometheus HA + Alertmanager + Grafana + node-exporter + KSM)
2. ServiceMonitors for all 6 services (add common.servicemonitor to the library chart)
3. Datastore exporters (Mongo, MySQL, Redis, RabbitMQ) + blackbox exporter
4. Grafana dashboards as ConfigMaps + deploy annotations
5. Alert rules: infrastructure first (nodes, PVC, crashloop), then SLO burn-rate
6. Alertmanager routing → Slack (warning) (critical) + inhibitions
7. Fluent Bit → Loki (S3) ; audit streams → CloudWatch
8. OTel Operator + auto-instrumentation → Tempo ; spanmetrics → Prometheus
9. Thanos sidecar → S3 for long-term retention and cross-cluster global query
10. OpenCost/Kubecost + FinOps dashboard
11. Write the runbooks and link every alert to one
```

**Definition of done:** you can answer, in under 5 minutes and without SSH, *"a user reports
checkout is slow — which of the six services is responsible, since when, what changed, and
how much of the error budget has it burned?"*

---

**Next:** [Phase 9 — Production readiness](./08-production-readiness.md)
