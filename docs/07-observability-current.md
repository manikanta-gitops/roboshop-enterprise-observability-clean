# Roboshop Observability — Current Standard

This project uses a deliberately practical observability stack suitable for a small production team and a 3-year DevOps portfolio project. It focuses on useful signals rather than adding enterprise tools only for complexity.

## Responsibilities

- **Prometheus:** Kubernetes and application metrics.
- **Alertmanager:** alert routing to Slack.
- **Grafana:** dashboards and investigation.
- **Fluent Bit:** Kubernetes log collection.
- **OpenSearch:** centralized log search.
- **CloudWatch:** AWS/EKS platform telemetry.
- **Argo CD:** deployment/change visibility.

PagerDuty, Thanos, Tempo/Jaeger, and additional database exporters are intentionally not part of the current baseline. They can be added later if the project actually needs them.

## Metrics flow

```text
Application / Kubernetes
        |
        v
 ServiceMonitor
        |
        v
   Prometheus
      /   \
     v     v
 Grafana  Alertmanager --> Slack
```

The current application scrape examples are:

- `cart` → `/metrics`
- `payment` → `/metrics`
- `shipping` → `/actuator/prometheus`

The other services are still covered by Kubernetes workload/resource monitoring. This avoids pretending that application instrumentation exists where it does not.

## Core alerts

The current baseline focuses on signals that are straightforward to explain and operate:

- pod crash loops
- unavailable deployment replicas
- no healthy replicas
- metrics target unavailable
- CPU throttling
- memory near limit
- PVC capacity
- datastore workload availability
- node readiness
- cluster CPU request capacity

The application metrics target alert checks the actual Prometheus scrape status instead of assuming an `http_requests_total` metric exists.

## SLO approach

The current SLO rule is a simple workload-availability indicator. It is intentionally not presented as a complete user-journey SLO implementation. A future improvement can add HTTP request success/latency SLIs once all application services expose a consistent metrics contract.

## Logging

```text
Pod stdout
   |
   v
Fluent Bit
   |
   v
OpenSearch
   |
   v
Grafana / OpenSearch Dashboards
```

## Interview explanation

> "I implemented practical monitoring with Prometheus, Grafana and Alertmanager. Prometheus collects Kubernetes metrics and selected application metrics through ServiceMonitors. Alertmanager sends actionable warnings and critical alerts to Slack. Fluent Bit collects container logs into OpenSearch for investigation. I focused on the signals a small production team would actually operate rather than adding PagerDuty, distributed tracing and long-term metrics systems just to increase the tool count."
