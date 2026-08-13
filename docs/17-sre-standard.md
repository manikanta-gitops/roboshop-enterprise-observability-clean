# SRE Standard

## Availability SLI

The repository currently measures workload availability using Kubernetes deployment desired versus available replicas. This is an infrastructure SLI, not an end-user HTTP success-rate SLI.

## Initial SLO

- Workload availability target: 99% for the initial portfolio implementation.
- Critical customer-facing request SLIs should be added when stable application request metrics are available.
- Alerts should be actionable and tied to a runbook.

## Error budget

The 99% target allows approximately 7.2 hours of unavailability in a 30-day month. Promotion decisions should consider whether an incident consumed a material portion of that budget before increasing release frequency.
