# Rollback Runbook

1. Identify the last known-good release in `releases/`.
2. Run `./scripts/rollback.sh <environment> <version>`.
3. Review the generated Git diff.
4. Commit and push the rollback GitOps change.
5. Wait for Argo CD self-heal/auto-sync.
6. Run `./scripts/smoke-test.sh <base-url> <version>`.
7. Record the incident and root cause before re-promoting a new release.
