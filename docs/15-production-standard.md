# Roboshop Production Standard

## Authoritative lifecycle

```text
Feature branch
  -> Pull Request
  -> automated validation/security gates
  -> human approval
  -> merge
  -> application build/test/scan
  -> dev ECR
  -> release tag
  -> immutable production ECR artifact
  -> GitOps promotion
  -> Argo CD
  -> dev -> qa -> staging -> production
  -> smoke verification
  -> monitoring/alerting
  -> GitOps rollback
```

## Rules

- No long-lived AWS keys in GitHub. Use OIDC.
- No production image is rebuilt during promotion.
- Production images are referenced by immutable digest.
- No direct `kubectl apply` from CI.
- PR validation and deployment approval are separate controls.
- Secrets come from AWS Secrets Manager through External Secrets.
- Production EKS API remains private; production Terraform execution requires a VPC-connected runner.
- Repository policy, Helm validation, Terraform validation and secret scanning are mandatory CI controls.
- Runtime Kyverno policies enforce baseline pod security in Roboshop namespaces.

## Artifact account model

This implementation uses the same AWS account for the dev and production ECR registries so the production release role can read the dev source repository and copy the exact image digest into immutable production ECR. If dev and production are later separated into AWS accounts, replace this with an explicit cross-account ECR repository policy or dedicated artifact-promotion role; do not add long-lived AWS keys.

## Platform versions

The baseline uses Kubernetes/EKS 1.35. The pinned controller/chart versions are selected to align with the 1.35 platform baseline; dependency updates are managed through Dependabot and must be validated before promotion.
