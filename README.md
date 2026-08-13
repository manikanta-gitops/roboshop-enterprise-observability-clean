# Roboshop Enterprise DevOps Platform

A production-style DevOps/SRE portfolio implementation for the Roboshop microservices application.

## Architecture

```text
Developer
  -> Feature branch
  -> Pull Request
  -> automated CI/security/quality gates
  -> human approval
  -> main
  -> build + test + Trivy + SBOM
  -> dev ECR (immutable SHA)
  -> GitOps dev update
  -> release tag
  -> exact image promoted to immutable production ECR
  -> dev smoke verification
  -> QA
  -> staging
  -> production approval
  -> Argo CD
  -> EKS
  -> Prometheus/Grafana/Alertmanager
  -> GitOps rollback on failed verification
```

## Main components

- AWS VPC, EKS, ECR, IAM/OIDC, KMS, AWS Backup
- Terraform with remote state and locked plans
- Docker multi-stage builds
- GitHub Actions
- SonarQube and OWASP Dependency-Check
- Trivy vulnerability scanning and SBOM generation
- Gitleaks secret scanning
- Helm + kubeconform + Checkov
- Argo CD GitOps
- External Secrets + AWS Secrets Manager
- AWS Load Balancer Controller
- Prometheus, Grafana, Alertmanager, Fluent Bit and OpenSearch
- Kyverno runtime policy enforcement

## Environment model

| Environment | Purpose | Deployment model |
|---|---|---|
| Dev | continuous integration validation | main -> dev ECR/GitOps |
| QA | release validation | manual promotion |
| Staging | production-like verification | manual promotion + wait gate |
| Production | controlled release | required GitHub Environment approval |

Production EKS uses a private API endpoint. Terraform plan/apply therefore runs on a VPC-connected self-hosted GitHub Actions runner.

## Security rules

- No long-lived AWS access keys in GitHub.
- GitHub Actions uses OIDC.
- Production images are immutable and digest-addressed.
- Promotion never rebuilds the image.
- CI does not use `kubectl apply` for application deployment.
- Secrets are delivered from AWS Secrets Manager through External Secrets.
- Runtime Kyverno policies enforce non-root workloads and reject `:latest`.

## Validation

Before merging, CI validates application code, Docker images, Helm, Kubernetes manifests, Terraform, dependencies and repository security policy.

See:

- `docs/15-production-standard.md`
- `docs/16-terraform-runner.md`
- `docs/17-sre-standard.md`
- `docs/runbooks/incident-response.md`
- `docs/runbooks/rollback.md`
- `docs/runbooks/disaster-recovery.md`
