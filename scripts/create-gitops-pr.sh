#!/usr/bin/env bash
set -euo pipefail

# Usage:
# create-gitops-pr.sh <branch> <commit-message> <pr-title> <pr-body>
#
# Creates a short-lived GitOps automation branch and pull request.
#
# IMPORTANT:
# This script intentionally DOES NOT auto-merge the PR.
#
# Flow:
#   GitHub Actions
#       ↓
#   GitOps branch
#       ↓
#   GitOps PR
#       ↓
#   Manual review + merge
#       ↓
#   ArgoCD
#       ↓
#   EKS

BRANCH="${1:?branch required}"
COMMIT_MESSAGE="${2:?commit message required}"
PR_TITLE="${3:?PR title required}"
PR_BODY="${4:?PR body required}"

command -v gh >/dev/null || {
  echo "gh CLI is required" >&2
  exit 1
}

git config user.name "roboshop-ci[bot]"
git config user.email "ci@roboshop.internal"

# ---------------------------------------------------------------------------
# Fetch remote automation branch if it already exists.
#
# This makes retries safe and prevents us from starting from stale state.
# ---------------------------------------------------------------------------
git fetch origin "$BRANCH" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Reuse existing automation branch when available.
# Otherwise create it from the current checkout.
# ---------------------------------------------------------------------------
if git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null 2>&1; then
  git checkout -B "$BRANCH" "origin/$BRANCH"
else
  git checkout -B "$BRANCH"
fi

# ---------------------------------------------------------------------------
# Stage only GitOps files.
# ---------------------------------------------------------------------------
git add charts environments releases

# ---------------------------------------------------------------------------
# Nothing changed.
# ---------------------------------------------------------------------------
if git diff --cached --quiet; then
  echo "::notice::No GitOps changes to submit."

  PR_NUMBER="$(
    gh pr list \
      --head "$BRANCH" \
      --state open \
      --json number \
      --jq '.[0].number // empty'
  )"

  if [[ -n "$PR_NUMBER" ]]; then
    echo "::notice::Existing GitOps PR: #$PR_NUMBER"
  fi

  exit 0
fi

# ---------------------------------------------------------------------------
# Commit GitOps change.
# ---------------------------------------------------------------------------
git commit -m "$COMMIT_MESSAGE"

# ---------------------------------------------------------------------------
# Refresh remote branch before push.
# ---------------------------------------------------------------------------
git fetch origin "$BRANCH" 2>/dev/null || true

git push --force-with-lease origin "$BRANCH"

# ---------------------------------------------------------------------------
# Reuse an existing open PR when possible.
# ---------------------------------------------------------------------------
PR_NUMBER="$(
  gh pr list \
    --head "$BRANCH" \
    --state open \
    --json number \
    --jq '.[0].number // empty'
)"

# ---------------------------------------------------------------------------
# Create PR if one does not already exist.
# ---------------------------------------------------------------------------
if [[ -z "$PR_NUMBER" ]]; then

  PR_URL="$(
    gh pr create \
      --base main \
      --head "$BRANCH" \
      --title "$PR_TITLE" \
      --body "$PR_BODY"
  )"

  PR_NUMBER="${PR_URL##*/}"

  echo "::notice::Created GitOps PR #$PR_NUMBER"
  echo "::notice::$PR_URL"

else

  PR_URL="$(
    gh pr view "$PR_NUMBER" \
      --json url \
      --jq '.url'
  )"

  echo "::notice::Reusing existing GitOps PR #$PR_NUMBER"
  echo "::notice::$PR_URL"

fi

# ---------------------------------------------------------------------------
# IMPORTANT:
#
# Do NOT auto-merge.
#
# The GitOps PR must be reviewed and manually merged.
#
# After merge:
#
#   GitHub
#      ↓
#   GitOps main
#      ↓
#   ArgoCD
#      ↓
#   EKS
# ---------------------------------------------------------------------------

echo ""
echo "============================================================"
echo "GitOps PR created successfully"
echo "============================================================"
echo "PR: $PR_URL"
echo "Number: #$PR_NUMBER"
echo ""
echo "Next step:"
echo "1. Review the GitOps PR"
echo "2. Merge the PR"
echo "3. ArgoCD will reconcile the change"
echo "4. Verify the application in EKS"
echo "============================================================"

exit 0
