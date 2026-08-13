#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smoke-test.sh - post-deployment sanity check.
#
# Runs after a promotion, against the environment that was just deployed. It
# answers one question: "is the release actually serving traffic?" Anything
# deeper belongs in the app test suite, not here.
#
#   ./scripts/smoke-test.sh https://dev.roboshop.example.com [expected-version]
#
# Exit 0 = healthy, exit 1 = roll back.
# ---------------------------------------------------------------------------
set -uo pipefail

BASE_URL="${1:-${SMOKE_BASE_URL:-}}"
EXPECTED_VERSION="${2:-}"
RETRIES="${SMOKE_RETRIES:-20}"
SLEEP="${SMOKE_SLEEP:-15}"
TIMEOUT="${SMOKE_TIMEOUT:-10}"

[[ -z "$BASE_URL" ]] && { echo "usage: $0 <base-url> [expected-version]" >&2; exit 1; }
BASE_URL="${BASE_URL%/}"

# path:expected-http-status - the public surface of the shop.
CHECKS=(
  "/:200"
  "/api/catalogue/health:200"
  "/api/catalogue/categories:200"
  "/api/user/health:200"
  "/api/cart/health:200"
  "/api/shipping/health:200"
  "/api/payment/health:200"
)

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# 1. Wait for the frontend to answer at all - ArgoCD may still be syncing.
log "waiting for $BASE_URL to come up (max $((RETRIES * SLEEP))s)"
ready=0
for i in $(seq 1 "$RETRIES"); do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE_URL/" || echo 000)
  if [[ "$code" == "200" ]]; then ready=1; log "frontend up after ${i} attempt(s)"; break; fi
  log "attempt $i/$RETRIES -> HTTP $code, retrying in ${SLEEP}s"
  sleep "$SLEEP"
done
if [[ "$ready" -ne 1 ]]; then
  echo "::error::frontend never returned 200 at $BASE_URL" >&2
  exit 1
fi

# 2. Endpoint checks.
failed=0
for check in "${CHECKS[@]}"; do
  path="${check%:*}"; want="${check##*:}"
  got=$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$TIMEOUT" "$BASE_URL$path" || echo 000)
  if [[ "$got" == "$want" ]]; then
    log "PASS  $path ($got)"
  else
    log "FAIL  $path (expected $want, got $got)"
    failed=$((failed + 1))
  fi
done

# 3. Optional: confirm the deployed version is the one we promoted.
if [[ -n "$EXPECTED_VERSION" ]]; then
  served=$(curl -sS --max-time "$TIMEOUT" "$BASE_URL/api/catalogue/health" 2>/dev/null \
    | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | cut -d'"' -f4 || true)
  if [[ -z "$served" ]]; then
    log "SKIP  version check (service does not report a version)"
  elif [[ "$served" == "$EXPECTED_VERSION" ]]; then
    log "PASS  version $served"
  else
    log "FAIL  version mismatch: expected $EXPECTED_VERSION, serving $served"
    failed=$((failed + 1))
  fi
fi

if [[ "$failed" -gt 0 ]]; then
  echo "::error::smoke test failed: $failed check(s)" >&2
  echo "rollback: ./scripts/rollback.sh <environment> <previous-version>" >&2
  exit 1
fi

log "smoke test passed"
