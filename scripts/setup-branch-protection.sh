#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# setup-branch-protection.sh
#
# Trunk-based development needs exactly one protected branch. Run once, with a
# GitHub token that has admin rights on the repo:
#
#   export GH_TOKEN=...
#   ./scripts/setup-branch-protection.sh manikanta-gitops/roboshop-enterprise
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="${1:-}"
[[ -z "$REPO" ]] && { echo "usage: $0 <owner/repo>" >&2; exit 1; }
command -v gh >/dev/null || { echo "error: gh CLI is required" >&2; exit 1; }

echo "protecting main on $REPO"

gh api -X PUT "repos/${REPO}/branches/main/protection" \
  --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "security / repository policy",
      "security / gitleaks",
      "security / dependency audit",
      "security / helm validation",
      "security / terraform static",
      "security / application tests",
      "app-ci / ci gate"
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
JSON

# Tags are the release contract - nobody moves or deletes them.
gh api -X POST "repos/${REPO}/rulesets" --input - <<'JSON' || echo "tag ruleset already exists"
{
  "name": "protect-release-tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["refs/tags/v*"], "exclude": [] } },
  "rules": [{ "type": "deletion" }, { "type": "update" }]
}
JSON

echo "done."
echo "Next: ./scripts/setup-environments.sh ${REPO}  (creates dev/qa/staging/production"
echo "with reviewers on production and lists the per-environment secrets)."
