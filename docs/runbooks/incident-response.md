# Incident Response Runbook

1. Identify impact: environment, service, customer-facing path.
2. Check Grafana/Prometheus alerts and recent GitOps promotions.
3. Inspect Argo CD health and the current release version in `environments/<env>/version.yaml`.
4. Check pod events, previous logs and dependency health.
5. If the failure is release-related, use the promotion rollback path rather than editing live Kubernetes resources.
6. Preserve logs, alert timestamps and the release commit for the post-incident review.
7. Record root cause, contributing factors and a prevention action.
