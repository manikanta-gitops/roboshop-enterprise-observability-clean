# Terraform CI runner

Production EKS has a private API endpoint. Terraform manages Helm/Kubernetes add-ons, so the plan/apply jobs must run from a network location that can reach the EKS private endpoint.

## Required runner

Register a GitHub Actions self-hosted runner with labels:

```text
self-hosted
linux
x64
roboshop-tf
```

Place it in the production VPC (or a connected network) with access to the private EKS endpoint and outbound access to AWS APIs/GitHub. Do not put the runner in a public subnet.

## Required permissions

The runner uses GitHub OIDC, not static AWS keys. Use the environment-specific roles:

- `AWS_OIDC_ROLE_ARN` for dev application CI (environment-scoped)
- `AWS_OIDC_ROLE_ARN_DEV` for trusted Terraform CI
- `AWS_OIDC_ROLE_ARN_PRODUCTION` for trusted production Terraform/release CI

The production role must be limited to the Terraform/CI resources it actually needs. Terraform plans intentionally run only on trusted push/schedule/manual executions, not on untrusted pull-request code, because Terraform evaluates provider and module code. Pull requests use Terraform fmt/validate/Checkov as the mandatory static gate.

## GitOps bot token

Protected `main` is not written to directly by automation. Release, promotion and dev write-back workflows create short-lived PRs and enable auto-merge. Configure `GITOPS_TOKEN` as a fine-grained GitHub token with only the repository permissions required to create/update pull requests and push automation branches.
