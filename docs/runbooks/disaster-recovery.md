# Disaster Recovery Runbook

## Recovery objectives

- Terraform is the source of truth for VPC/EKS/IAM/ECR/platform infrastructure.
- GitOps is the source of truth for workloads.
- AWS Backup is the source of truth for protected EBS recovery points.

## Cluster loss

1. Bootstrap Terraform backend/state.
2. Apply the target environment Terraform stack from the VPC-connected Terraform runner.
3. Verify EKS managed add-ons and IRSA roles.
4. Bootstrap Argo CD and apply the platform/root Applications.
5. Confirm External Secrets resolves the environment secret.
6. Allow Argo CD to recreate workloads from Git.
7. Restore persistent data from the latest AWS Backup recovery point where required.
8. Run the environment smoke test.
9. Record actual recovery time and compare it with the intended RTO.

## Data restore

Do not test restore by deleting production data. Use a non-production recovery environment and document:

- recovery point ID
- restore start/end time
- restored volume IDs
- application verification
- data consistency checks

A backup that has never been restored is not considered operationally proven.
