#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-environments.sh
#
# Creates the four GitHub Environments the promote/terraform workflows target,
# with the protection rules that make promotion safe, and lists the secrets
# each one needs. Run once with an admin token:
#
#   export GH_TOKEN=...
#   ./scripts/setup-environments.sh manikanta-gitops/roboshop-enterprise [reviewer-team-slug]
#
# Rules applied:
#   dev         no gate, deploys freely
#   qa          no gate
#   staging     5 minute wait timer (time to abort a bad promotion)
#   production  required reviewers + main-branch-only + 5 minute wait
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${1:-}"
REVIEWER_TEAM="${2:-platform-engineering}"
[[ -z "$REPO" ]] && { echo "usage: $0 <owner/repo> [reviewer-team-slug]" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh CLI is required" >&2; exit 1; }

OWNER="${REPO%%/*}"

put_env() { # $1 env name, $2 json body
  gh api -X PUT "repos/${REPO}/environments/$1" --input - <<<"$2" >/dev/null
  echo "  environment '$1' configured"
}

echo "configuring environments on $REPO"

put_env dev '{"wait_timer":0,"deployment_branch_policy":null}'
put_env qa  '{"wait_timer":0,"deployment_branch_policy":null}'
put_env staging '{"wait_timer":5,"deployment_branch_policy":null}'

# production: reviewers + only protected branches/tags may deploy.
team_id=$(gh api "orgs/${OWNER}/teams/${REVIEWER_TEAM}" --jq .id 2>/dev/null || true)
if [[ -n "$team_id" ]]; then
  put_env production "$(cat <<JSON
{
  "wait_timer": 5,
  "prevent_self_review": true,
  "reviewers": [{"type": "Team", "id": ${team_id}}],
  "deployment_branch_policy": {"protected_branches": true, "custom_branch_policies": false}
}
JSON
)"
else
  echo "  warning: team '${REVIEWER_TEAM}' not found - creating production without reviewers"
  put_env production '{"wait_timer":5,"deployment_branch_policy":{"protected_branches":true,"custom_branch_policies":false}}'
  echo "  add required reviewers manually: Settings > Environments > production"
fi

cat <<'TXT'

Environment-scoped secrets to set (each environment gets its OWN values, so a
dev credential can never reach production):

  gh secret set AWS_OIDC_ROLE_ARN --env dev --body 'arn:aws:iam::<dev-account>:role/roboshop-dev-github-actions'
  gh secret set AWS_OIDC_ROLE_ARN_DEV --body 'arn:aws:iam::<dev-account>:role/roboshop-dev-github-actions'
  gh secret set AWS_OIDC_ROLE_ARN_PRODUCTION --body 'arn:aws:iam::<prod-account>:role/roboshop-production-github-actions'
  gh secret set SMOKE_BASE_URL    --env <env> --body 'https://<env>.roboshop.example.com'

Repository-level (shared, non-sensitive per environment):

  gh secret set SLACK_WEBHOOK_URL --body 'https://hooks.slack.com/services/...'
  gh secret set SONAR_HOST_URL    --body 'https://sonarqube.example.com'
  gh secret set SONAR_TOKEN       --body '...'
  gh secret set GITOPS_TOKEN      --body '...'   # only if the default token cannot push to main

Environment variables (non-secret, visible in logs):

  gh variable set ECR_REGISTRY --env <env> --body '<account>.dkr.ecr.<region>.amazonaws.com'
  gh variable set SMOKE_BASE_URL --env <env> --body 'https://<env>.roboshop.example.com'
  gh variable set DEV_AWS_REGION --body 'ap-south-1'
  gh variable set DEV_SMOKE_BASE_URL --body 'https://dev.shop.example.com'
TXT

echo "done."
