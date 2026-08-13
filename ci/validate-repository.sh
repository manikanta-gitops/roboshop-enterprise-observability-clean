#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> checking for unresolved production placeholders"
if grep -RniE 'REPLACE_ME|your-org/|your_org' charts infrastructure gitops .github --exclude='*.md'; then
  echo "::error::unresolved production placeholder detected"
  exit 1
fi

echo "==> checking for hardcoded credential fallbacks"
if grep -RniE 'RoboShop@1|roboshop-dev-secret-change-me|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID' apps charts infrastructure --exclude='*.md'; then
  echo "::error::hardcoded credential pattern detected"
  exit 1
fi

echo "==> checking for mutable latest image tags"
if grep -RniE "(^|[/:])latest([[:space:]\"']|$)" charts apps infrastructure --include="*.yaml" --include="*.yml" --include="Dockerfile*"; then
  echo "::error::latest image tag detected"
  exit 1
fi

echo "Repository policy checks passed."
