# Argo CD / GitOps

Application packaging is Helm. Kustomize and legacy raw Kubernetes manifests are not part of the normal deployment path.

## Layout

```
argocd/
  projects/         AppProject - repo, destination and RBAC guardrails
  applications/     app-of-apps root Application, one per environment
  applicationsets/  ApplicationSet that fans out to one Application per chart
```

## Bootstrap

The `roboshop` AppProject and the dev root Application are applied
**automatically by Terraform** (`infrastructure/environments/dev`) as the Helm
release `roboshop-gitops-bootstrap` (chart `charts/argocd-bootstrap`), right
after Argo CD itself is installed. No manual `kubectl apply` is required and
re-running Terraform is a no-op once the resources exist.

```text
Terraform
  └─ helm_release.argocd           (argo-cd chart, installs Argo CD + CRDs)
  └─ helm_release.argocd_bootstrap (roboshop AppProject + roboshop-dev-root)
        └─ Argo CD syncs the root Application
              └─ ApplicationSet roboshop-dev (managed from Git)
                    └─ 11 dev Applications (platform, datastores, services, frontend)
```

For a cluster where the AppProject or root Application was previously created
with a manual `kubectl apply`, adopt the existing release into Terraform state
before the automated apply so Terraform does not create a duplicate:

```bash
cd infrastructure/environments/dev
terraform import helm_release.argocd_bootstrap roboshop-gitops-bootstrap
```

For environments not yet automated (qa/staging/production), the original
manual bootstrap still applies:

```bash
kubectl apply -f gitops/projects/roboshop-project.yaml
kubectl apply -f gitops/applications/root-qa.yaml       # or staging/production
```

## Sync waves

| Wave | Contents                                                        |
|------|-----------------------------------------------------------------|
| -10..-7 | Namespace, quota, limit range, storage class, SA, config, secrets, network policies (inside the platform chart) |
| -1   | `platform` chart                                                  |
| 0    | `mongodb`, `mysql`, `redis`, `rabbitmq`                           |
| 1    | `catalogue`, `user`, `cart`, `shipping`, `payment`                |
| 2    | `frontend`                                                        |
| 5    | Shared ALB Ingress (inside the platform chart, after backends)    |

ArgoCD only starts a wave once every resource in the previous wave is Healthy,
so datastores are ready before the APIs that connect to them, and target groups
exist before the ALB registers them.

## Environment policy

| Environment | Auto-sync | Prune | Self-heal |
|-------------|-----------|-------|-----------|
| dev         | yes       | yes   | yes       |
| qa          | yes       | yes   | yes       |
| staging     | yes       | no    | no        |
| production  | no (manual/PR-gated) | no | no |

`/spec/replicas` is in `ignoreDifferences` so HPA scaling never shows as drift.
