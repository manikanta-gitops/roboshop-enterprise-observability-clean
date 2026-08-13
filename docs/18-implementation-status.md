# Implementation Status

## Completed in this revision

- P0 security and architecture fixes carried forward.
- PR CI separated from publish/deployment credentials.
- Immutable dev image artifacts are transferred between CI jobs before ECR push.
- Trivy is blocking for HIGH/CRITICAL vulnerabilities.
- SBOMs are generated for built images.
- Cosign keyless signing is enabled for dev and production images.
- Application smoke/unit coverage was added for Node, Python and Java services.
- GitOps write-back uses protected-main PRs with auto-merge instead of direct pushes.
- Release promotion copies the exact dev image into immutable production ECR instead of rebuilding.
- Promotion is ordered dev -> QA -> staging -> production.
- Production requires GitHub Environment approval.
- Failed promotion smoke tests trigger an automatic GitOps rollback PR.
- Production EKS API remains private; Terraform runs on a VPC-connected runner.
- Production namespace consistency was corrected.
- Hardcoded JWT and database credentials were removed.
- MySQL application-user creation now consumes runtime secrets.
- Service-specific Kubernetes service accounts are used.
- Kyverno runtime policies enforce non-root and reject `:latest`.
- Gitleaks, dependency audit, repository policy checks, Helm validation and Terraform static checks are part of the PR gate.
- Dependabot is configured for GitHub Actions and application/IaC dependencies.
- Observability alerts were corrected to avoid NGINX-only metrics when ALB is the ingress path.
- SLO/availability recording and alerting were added.
- AWS monthly budget support was added as an optional Terraform control.
- Disaster recovery, rollback and incident runbooks were added.
- Current architecture documentation was rewritten and historical design notes were marked as historical.

## External configuration still required

The repository cannot safely invent account-specific values. Before enabling the workflows in GitHub/AWS, configure:

- `AWS_OIDC_ROLE_ARN` in the dev environment for application CI.
- `AWS_OIDC_ROLE_ARN_DEV` for trusted Terraform CI.
- `AWS_OIDC_ROLE_ARN_PRODUCTION` for release and trusted production Terraform CI.
- `GITOPS_TOKEN` with the minimum GitHub permissions needed to create/merge automation PRs and trigger CI.
- `SONAR_HOST_URL` and `SONAR_TOKEN`.
- `ECR_REGISTRY` for QA/staging/production GitHub Environments.
- `SMOKE_BASE_URL` for each environment.
- `DEV_SMOKE_BASE_URL` for release validation.
- ACM certificates matching the configured ingress hostnames, allowing ALB certificate discovery.
- AWS Secrets Manager keys referenced by External Secrets, including `JWT_ACCESS_SECRET`, `JWT_REFRESH_SECRET`, `MYSQL_ROOT_PASSWORD`, and `MYSQL_SHIPPING_PASSWORD`.
- A VPC-connected self-hosted runner with `roboshop-tf` labels.

These are deployment prerequisites, not values that should be fabricated in source control.
