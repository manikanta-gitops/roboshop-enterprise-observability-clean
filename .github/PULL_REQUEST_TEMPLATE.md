## What changed

<!-- one or two lines, and the ticket id -->

## Type

- [ ] feature
- [ ] bugfix
- [ ] hotfix
- [ ] infrastructure / helm / gitops
- [ ] chore

## Checklist

- [ ] Branch is short-lived and rebased on `main`
- [ ] Unit tests pass locally
- [ ] No image tag hardcoded to `latest`
- [ ] Helm changes validated: `./ci/lint.sh && ./ci/template.sh && ./ci/validate.sh`
- [ ] Terraform changes validated: `terraform fmt -recursive && terraform validate`
- [ ] Secrets go to AWS Secrets Manager (ExternalSecret), never to Git
- [ ] Resource requests/limits set for any new workload

## Rollout

Which environments does this touch, and how do we roll it back?
