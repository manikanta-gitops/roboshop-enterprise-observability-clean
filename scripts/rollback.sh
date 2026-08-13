#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# rollback.sh <environment> <version> [service ...]
#
# Rollback is just a promotion backwards: rewrite the values files to a version
# that was already released, commit, let ArgoCD sync. No rebuild, no kubectl.
#
#   ./scripts/rollback.sh production 2.0.0
#   ./scripts/rollback.sh production 2.0.0 cart catalogue
#
# For an emergency rollback that cannot wait for a sync (rare), use:
#   argocd app rollback roboshop-production-cart
# and then run this script so Git matches the cluster again - otherwise
# self-heal reverts your manual rollback within minutes.
# ---------------------------------------------------------------------------
set -euo pipefail

ENVIRONMENT="${1:-}"
VERSION="${2:-}"
shift 2 || true
SERVICES=("$@")

if [[ -z "$ENVIRONMENT" || -z "$VERSION" ]]; then
  echo "usage: $0 <dev|qa|staging|production> <version> [service ...]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="releases/${VERSION}.yaml"
[[ -f "$MANIFEST" ]] || { echo "error: $MANIFEST not found - unknown version" >&2; exit 1; }

command -v yq >/dev/null || { echo "error: yq is required" >&2; exit 1; }

if [[ ${#SERVICES[@]} -eq 0 ]]; then
  SERVICES=(cart catalogue user shipping payment frontend)
fi

for svc in "${SERVICES[@]}"; do
  f="charts/${svc}/values-${ENVIRONMENT}.yaml"
  [[ -f "$f" ]] || { echo "skip ${svc}: $f missing"; continue; }
  tag=$(yq -r ".images.${svc}.tag" "$MANIFEST")
  digest=$(yq -r ".images.${svc}.digest" "$MANIFEST")
  [[ "$tag" == "null" ]] && { echo "skip ${svc}: not in $MANIFEST"; continue; }
  yq -i ".image.repository = \"roboshop/${svc}\"
       | .image.tag = \"${tag}\"
       | .image.digest = \"${digest}\"" "$f"
  echo "rolled back ${svc} -> ${tag}"
done

cat > "environments/${ENVIRONMENT}/version.yaml" <<EOF
# Live release in ${ENVIRONMENT}. Written by scripts/rollback.sh.
environment: ${ENVIRONMENT}
version: "${VERSION}"
promotedAt: "$(date -u +%FT%TZ)"
promotedBy: "rollback"
EOF

echo
echo "Review the Git diff, then submit the rollback through protected main:"
echo "  GH_TOKEN=... ./scripts/create-gitops-pr.sh automation/rollback-${ENVIRONMENT}-${VERSION} \"revert: ${ENVIRONMENT} -> ${VERSION}\" \"revert: rollback ${ENVIRONMENT} to ${VERSION}\" \"Automated GitOps rollback.\""
echo "ArgoCD will sync the previous artifact after the PR is merged; no image is rebuilt."
