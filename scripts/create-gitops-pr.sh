#!/usr/bin/env bash
set -euo pipefail

# Usage: create-gitops-pr.sh <branch> <commit-message> <pr-title> <pr-body>
# Creates a short-lived automation branch and enables auto-merge. A PAT or
# GitHub App token should be supplied as GH_TOKEN so merged PRs trigger CI.

BRANCH="${1:?branch required}"
COMMIT_MESSAGE="${2:?commit message required}"
PR_TITLE="${3:?PR title required}"
PR_BODY="${4:?PR body required}"

command -v gh >/dev/null || { echo "gh CLI is required" >&2; exit 1; }

git config user.name "roboshop-ci[bot]"
git config user.email "ci@roboshop.internal"
git checkout -B "$BRANCH"
git add charts environments releases
if git diff --cached --quiet; then
  echo "No GitOps changes to submit."
  exit 0
fi

git commit -m "$COMMIT_MESSAGE"
git push --force-with-lease origin "$BRANCH"

PR_NUMBER=$(gh pr list --head "$BRANCH" --state open --json number --jq '.[0].number // empty')
if [[ -z "$PR_NUMBER" ]]; then
  PR_URL=$(gh pr create --base main --head "$BRANCH" --title "$PR_TITLE" --body "$PR_BODY")
  PR_NUMBER="${PR_URL##*/}"
fi

gh pr merge "$PR_NUMBER" --auto --squash --delete-branch

for _ in $(seq 1 60); do
  state=$(gh pr view "$PR_NUMBER" --json state --jq '.state' 2>/dev/null || true)
  [[ "$state" == "MERGED" ]] && exit 0
  [[ "$state" == "CLOSED" ]] && { echo "PR was closed without merge" >&2; exit 1; }
  sleep 10
done

echo "Timed out waiting for PR $BRANCH to merge" >&2
exit 1
