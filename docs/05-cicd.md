> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 6 — Enterprise CI/CD (GitHub Actions)

> **Current State:** `helm-ci.yaml` (lint → template+kubeconform → checkov+SARIF) and
> `release.yaml` (tag → promote immutable images → GitOps PR).
> **Score: platform CI 6/10, application CI 0/10.**
>
> **Three defects:**
> 1. `helm-release.yaml` sets `WORKDIR: roboshop-helm` and `defaults.run.working-directory:
>    ${{ env.WORKDIR }}` — that directory does not exist, and `env` is not resolvable in
>    `defaults` at job scope. **Every step fails.**
> 2. `paths:` filters only `charts/** | ci/** | environments/**`. A change to
>    `apps/cart/server.js` triggers **nothing**.
> 3. There is no `docker build`, no test, no image scan, no ECR push, no GitOps write-back —
>    **code can never reach the cluster.**

---

## 6.1 Pipeline topology

```text
                     ┌──────────── PR opened ────────────┐
                     │                                    │
       app-ci.yaml (matrix per service)        helm-ci.yaml        terraform-plan.yaml
       ├ checkout                              ├ helm lint          ├ fmt / validate
       ├ setup + cache deps                    ├ helm template      ├ tflint / checkov
       ├ lint + format                         ├ kubeconform        └ plan → PR comment
       ├ unit test + coverage                  └ checkov → SARIF
       ├ integration test (services:)
       ├ SonarQube / CodeQL / Semgrep
       ├ Gitleaks / Trufflehog
       ├ dependency + license scan
       ├ docker build (no push on PR)
       └ Trivy image scan  ───────► PR must be green to merge
                     │
                     ▼  merge to main
       ┌──────────── app-cd.yaml ─────────────────────────────────┐
       │ build+push ECR (immutable tag + digest) → Cosign sign     │
       │ → Syft SBOM + Cosign attest → Trivy gate on digest        │
       │ → write gitops/environments/dev/images.yaml → auto-merge  │
       └────────────────────────┬─────────────────────────────────┘
                                ▼
                          ArgoCD syncs dev  → PostSync smoke test
                                ▼  promotion PR (manual, CODEOWNERS)
                          qa → staging → production (2 approvals + sync window)
```

**Design principle:** CI **builds and publishes artifacts**; CI **never deploys**. The only
cluster-touching credential in the whole system belongs to ArgoCD, which pulls.

---

## 6.2 Every stage, explained

| # | Stage | Tool | Mandatory? | Fails build? | Why it exists |
|---:|---|---|---|---|---|
| 1 | Checkout | `actions/checkout` (pin SHA) | ✅ | — | `fetch-depth: 0` needed for Sonar/Gitleaks history |
| 2 | Setup + dep restore | `setup-node/java/python` + cache | ✅ | yes | Cache cuts 3–5 min/run; `npm ci` (not `install`) for lockfile fidelity |
| 3 | Lint | eslint / ruff / checkstyle | ✅ | yes | Cheapest defect class to catch; fail fast |
| 4 | Format check | prettier / black / spotless | ✅ | yes | Removes style noise from code review |
| 5 | Unit tests | jest / pytest / junit | ✅ | yes | Fast feedback (<2 min) |
| 6 | Coverage gate | jest --coverage, jacoco | ⚠️ recommended | yes, on **new code** | Gate on *diff coverage* ≥80%, not total — total gates block legacy refactors |
| 7 | Integration tests | testcontainers / `services:` | ✅ | yes | Your services talk to Mongo/Redis/MySQL/RabbitMQ — mocks won't catch wiring bugs |
| 8 | SAST — CodeQL | `github/codeql-action` | ✅ | yes on High | Deep dataflow: injection, SSRF, path traversal. Free on public repos |
| 9 | SAST — Semgrep | `semgrep ci` | ⚠️ optional | on High | Fast, custom org rules (e.g. "no `eval`", "no hardcoded ARNs") |
| 10 | SonarQube | `sonarqube-scan-action` | ⚠️ optional | on quality gate | Maintainability, duplication, code smells — enterprise reporting |
| 11 | Secret scan | Gitleaks + TruffleHog | ✅ | **always** | A leaked key in one commit is leaked forever; also add a pre-commit hook |
| 12 | Dependency scan | `npm audit`, Trivy fs, OWASP DC, Snyk | ✅ | on Critical | Log4Shell class of risk; SCA is where most CVEs live |
| 13 | License scan | `license-checker`, ScanCode | ⚠️ optional | on GPL/AGPL | Legal risk — copyleft in a proprietary product |
| 14 | Docker build | Buildx + GHA cache | ✅ | yes | Multi-arch (`amd64,arm64`) if you plan Graviton |
| 15 | Image scan | **Trivy** on the built image | ✅ | on Critical/High fixable | Base-image CVEs; scan **before** push |
| 16 | Push image | ECR, immutable tag + digest | ✅ | yes | OIDC, no static keys |
| 17 | Sign + SBOM | Cosign keyless + Syft + attest | ⚠️ strongly recommended | yes | Supply-chain provenance; enables Kyverno `verifyImages` |
| 18 | Helm lint | `helm lint --strict` × env | ✅ | yes | *already implemented — good* |
| 19 | Helm template | `helm template` × env | ✅ | yes | Catches nil-pointer template bugs *already implemented* |
| 20 | Kubeconform | schema validation | ✅ | yes | *already implemented — good* |
| 21 | Checkov / kube-linter | policy on rendered YAML | ✅ | on High | *already implemented — good* |
| 22 | Package Helm | `helm package` | ✅ | yes | Immutable versioned artifact |
| 23 | Argo CD Helm source | `repoURL + path: charts/*` | ✅ | yes | Single application deployment source |
| 24 | GitOps update | write `images.yaml`, open PR | ✅ | yes | **The missing link in this repo** |
| 25 | Deploy validation | `argocd app wait --health` | ✅ | yes | Confirms the desired state actually converged |
| 26 | Smoke test | k6 / newman against the env URL | ✅ | yes | 6 requests proving the critical path works |
| 27 | Notification | Slack / Teams | ⚠️ optional | no | On failure always; on success prod only |
| 28 | Release | `softprops/action-gh-release` + changelog | ⚠️ optional | no | Traceability: tag ↔ image digest ↔ chart version |
| 29 | Rollback | `git revert` of the images.yaml commit | ✅ | — | GitOps rollback = revert. Fast, audited, idempotent |

**Mandatory minimum for production:** 1,2,3,5,7,11,12,14,15,16,18,19,20,21,24,25,26,29.
**Optional / maturity:** 6,9,10,13,17,27,28 — add them as the team grows.

---

## 6.3 `app-ci.yaml` — matrix build, test, scan, push

```yaml
name: app-ci
on:
  pull_request:
    paths: ["apps/**", ".github/workflows/app-ci.yaml"]
  push:
    branches: [main]
    paths: ["apps/**"]

permissions:
  contents: read
  id-token: write            # OIDC → AWS
  packages: write
  security-events: write     # SARIF upload
  pull-requests: write

concurrency:                  # cancel superseded runs — saves minutes and avoids race pushes
  group: app-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  changes:                     # only build what changed
    runs-on: ubuntu-latest
    outputs: { services: ${{ steps.filter.outputs.changes }} }
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683   # v4.2.2 pinned by SHA
      - uses: dorny/paths-filter@v3
        id: filter
        with:
          filters: |
            catalogue: ['apps/catalogue/**']
            user:      ['apps/user/**']
            cart:      ['apps/cart/**']
            payment:   ['apps/payment/**']
            shipping:  ['apps/shipping/**']
            frontend:  ['apps/frontend/**']

  build:
    needs: changes
    if: needs.changes.outputs.services != '[]'
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false                       # one service failing shouldn't hide the others
      matrix: { service: ${{ fromJSON(needs.changes.outputs.services) }} }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }

      # ---------- language toolchain + cache ----------
      - uses: actions/setup-node@v4
        if: contains(fromJSON('["catalogue","user","cart"]'), matrix.service)
        with:
          node-version: '20'
          cache: npm
          cache-dependency-path: apps/${{ matrix.service }}/package-lock.json
      - uses: actions/setup-java@v4
        if: matrix.service == 'shipping'
        with: { distribution: temurin, java-version: '21', cache: maven }
      - uses: actions/setup-python@v5
        if: matrix.service == 'payment'
        with: { python-version: '3.12', cache: pip }

      # ---------- lint · test · coverage ----------
      - name: Install & test
        working-directory: apps/${{ matrix.service }}
        run: make ci        # each service exposes the same 'make ci' contract

      - uses: actions/upload-artifact@v4
        if: always()
        with: { name: coverage-${{ matrix.service }}, path: apps/${{ matrix.service }}/coverage }

      # ---------- security: code, secrets, deps ----------
      - uses: github/codeql-action/init@v3
        with: { languages: ${{ matrix.service == 'shipping' && 'java' || 'javascript' }} }
      - uses: github/codeql-action/analyze@v3

      - uses: gitleaks/gitleaks-action@v2
        env: { GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }} }

      - name: Trivy filesystem (deps + IaC + secrets)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          scan-type: fs
          scan-ref: apps/${{ matrix.service }}
          scanners: vuln,secret,misconfig
          severity: CRITICAL,HIGH
          exit-code: '1'
          ignore-unfixed: true          # don't block on CVEs with no patch available

      # ---------- build ----------
      - uses: docker/setup-buildx-action@v3
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_OIDC_ECR_ROLE }}
          aws-region: ${{ vars.AWS_REGION }}
      - uses: aws-actions/amazon-ecr-login@v2
        id: ecr

      - name: Compute tag
        id: meta
        run: |
          echo "tag=v$(date -u +%Y%m%d).${GITHUB_RUN_NUMBER}.${GITHUB_SHA::7}" >> "$GITHUB_OUTPUT"

      - name: Build (load locally, do NOT push yet)
        uses: docker/build-push-action@v6
        with:
          context: apps/${{ matrix.service }}
          load: true
          tags: local/${{ matrix.service }}:scan
          cache-from: type=gha,scope=${{ matrix.service }}
          cache-to:   type=gha,scope=${{ matrix.service }},mode=max
          provenance: true
          sbom: true

      - name: Trivy image scan (gate BEFORE push)
        uses: aquasecurity/trivy-action@0.28.0
        with:
          image-ref: local/${{ matrix.service }}:scan
          severity: CRITICAL,HIGH
          exit-code: '1'
          ignore-unfixed: true
          format: sarif
          output: trivy-image.sarif
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with: { sarif_file: trivy-image.sarif }

      # ---------- publish (main only) ----------
      - name: Push to ECR
        if: github.event_name == 'push'
        id: push
        uses: docker/build-push-action@v6
        with:
          context: apps/${{ matrix.service }}
          push: true
          platforms: linux/amd64,linux/arm64
          tags: ${{ steps.ecr.outputs.registry }}/roboshop/${{ matrix.service }}:${{ steps.meta.outputs.tag }}
          cache-from: type=gha,scope=${{ matrix.service }}

      - uses: sigstore/cosign-installer@v3
        if: github.event_name == 'push'
      - name: Sign + attest SBOM (keyless, OIDC)
        if: github.event_name == 'push'
        env:
          IMG: ${{ steps.ecr.outputs.registry }}/roboshop/${{ matrix.service }}@${{ steps.push.outputs.digest }}
        run: |
          cosign sign --yes "$IMG"
          syft "$IMG" -o spdx-json > sbom.spdx.json
          cosign attest --yes --predicate sbom.spdx.json --type spdxjson "$IMG"

      - name: Emit image coordinates for CD
        if: github.event_name == 'push'
        run: |
          mkdir -p out
          printf '%s %s %s\n' "${{ matrix.service }}" "${{ steps.meta.outputs.tag }}" \
            "${{ steps.push.outputs.digest }}" > out/${{ matrix.service }}.txt
      - uses: actions/upload-artifact@v4
        if: github.event_name == 'push'
        with: { name: images, path: out/, overwrite: false }
```

**Why build → scan → *then* push:** a vulnerable image never enters the registry. Scanning
after push means the bad artifact is already pullable and already in your lifecycle policy.

---

## 6.4 `app-cd.yaml` — the missing GitOps write-back

```yaml
name: app-cd
on:
  workflow_run:
    workflows: [app-ci]
    types: [completed]
    branches: [main]

permissions: { contents: write, pull-requests: write }

jobs:
  bump-dev:
    if: github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: images, path: out, run-id: ${{ github.event.workflow_run.id }},
                github-token: ${{ secrets.GITHUB_TOKEN }} }

      - name: Update dev image pins
        run: |
          set -euo pipefail
          F=gitops/environments/dev/images.yaml
          while read -r svc tag digest; do
            yq -i ".images.${svc}.tag = \"${tag}\"    | .images.${svc}.digest = \"${digest}\"" "$F"
          done < <(cat out/*.txt)

      - uses: peter-evans/create-pull-request@v7
        with:
          branch: bot/bump-dev-images
          title: "chore(dev): bump image pins"
          commit-message: "chore(dev): bump image pins [skip ci]"
          body: |
            Automated image promotion to **dev**.
            Digests are immutable; ArgoCD will sync on merge.
          labels: automated, dev-promotion
```

Promotion to qa/staging/production is a **separate manual `workflow_dispatch`** that copies
the block from the lower environment's `images.yaml` and opens a PR — so a human always sees
the exact diff going to production.

```yaml
# promote.yaml (excerpt)
on:
  workflow_dispatch:
    inputs:
      from: { type: choice, options: [dev, qa, staging], required: true }
      to:   { type: choice, options: [qa, staging, production], required: true }
jobs:
  promote:
    environment: ${{ inputs.to }}      # ← GitHub Environment protection = required reviewers
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: yq ea 'select(fi==0).images = select(fi==1).images | select(fi==0)' \
               gitops/environments/${{ inputs.to }}/images.yaml \
               gitops/environments/${{ inputs.from }}/images.yaml \
               -i gitops/environments/${{ inputs.to }}/images.yaml
      - uses: peter-evans/create-pull-request@v7
        with: { branch: bot/promote-${{ inputs.from }}-to-${{ inputs.to }},
                title: "release: promote ${{ inputs.from }} → ${{ inputs.to }}" }
```

---

## 6.5 Helm deployment ownership

Helm is the application packaging and rendering mechanism. CI runs `helm lint`,
`helm template`, kubeconform and policy checks. CI does **not** package or push
application charts to a second OCI registry. Argo CD consumes the Git repository
chart paths directly and is the only normal application deployment controller.

This avoids two competing deployment sources:

```text
Git repository / charts/<service>
        ↓
Argo CD
        ↓
EKS
```

Container images are the promoted immutable artifacts; Helm chart source remains
version-controlled with the GitOps desired state.

---

## 6.6 Deployment validation & smoke test

```yaml
  validate:
    needs: sync
    runs-on: ubuntu-latest
    steps:
      - name: Wait for ArgoCD convergence
        run: |
          argocd app wait roboshop-production-cart \
            --health --sync --operation --timeout 600 \
            --server "$ARGOCD_SERVER" --auth-token "$ARGOCD_TOKEN"

      - name: Smoke test the critical path
        run: |
          BASE="https://roboshop.example.com"
          set -euo pipefail
          curl -fsS  "$BASE/health"                    -o /dev/null
          curl -fsS  "$BASE/api/catalogue/products"    | jq -e 'length > 0'
          curl -fsS  "$BASE/api/user/uniqueid"         | jq -e '.uuid'
          curl -fsS -X POST "$BASE/api/cart/add/$(uuidgen)/Watson/1" | jq -e '.total >= 0'
          curl -fsS  "$BASE/api/shipping/codes/IN"     | jq -e 'length > 0'

      - name: k6 load smoke (p95 < 500ms, error rate < 1%)
        run: k6 run --vus 20 --duration 60s tests/load/critical-path.js

      - uses: slackapi/slack-github-action@v2
        if: failure()
        with: { payload: '{"text":"🚨 production validation FAILED — rolling back"}' }

  rollback:
    needs: validate
    if: failure()
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          git revert --no-edit HEAD          # revert the images.yaml bump
          git push                            # ArgoCD self-heals to the previous digest
```

---

## 6.7 Caching, matrices, artifacts, OIDC — the four force multipliers

**Caching.** `actions/setup-*` `cache:` for language deps; `type=gha` for Buildx layers;
`~/.m2`, `~/.npm`, `~/.cache/pip`. Realistic saving: 8 min → 2.5 min per run. Always include a
restore-key fallback and **never cache a directory that CI writes secrets into**.

**Matrices.** `strategy.matrix.service` with `fail-fast: false` + `dorny/paths-filter` so a
frontend CSS change does not rebuild the Java service. Also matrix Node versions for libraries.

**Artifacts.** Coverage reports, SARIF, rendered manifests (`ci/_rendered`), SBOMs, k6 results.
Set `retention-days` (7 for debug, 90 for SBOM/compliance evidence).

**OIDC.** Already used in `helm-release.yaml` — correct and rare. Extend it to *every* AWS job
and delete any long-lived `AWS_ACCESS_KEY_ID` secret. Scope each role's trust policy to a
specific `environment:` (see Phase 3 §3.5).

---

## 6.8 Hardening the workflows themselves

- **Pin actions to commit SHAs**, not tags. `actions/checkout@v4` is a *mutable* ref — a
  compromised tag is a supply-chain attack (`tj-actions/changed-files`, March 2025).
- **`permissions:` least-privilege at workflow level**, elevate per job. Default should be
  `contents: read`.
- **Never use `pull_request_target`** with a checkout of the PR head — that is remote code
  execution with your secrets.
- **`concurrency`** groups to prevent two deploys racing to the same environment.
- **GitHub Environments** (`dev`/`qa`/`staging`/`production`) with required reviewers, wait
  timers, and environment-scoped secrets. This is where the deploy gate actually lives.
- **Reusable workflows** (`workflow_call`) for the shared build/test/scan skeleton — six
  services should not have six copies.
- **Required status checks** on `main`; block merge on red.
- **Nightly `security-nightly.yaml`**: Trivy repo scan, CodeQL full, `terraform plan
  -detailed-exitcode` drift detection, `argocd app diff` drift detection, base-image staleness.

---

## 6.9 Required GitHub configuration

**Secrets** (repository or environment scoped):

| Name | Scope | Purpose |
|---|---|---|
| `AWS_OIDC_ECR_ROLE` | repo | push images |
| `AWS_OIDC_TF_PLAN_ROLE` / `AWS_OIDC_TF_APPLY_ROLE` | env | Terraform |
| `ARGOCD_AUTH_TOKEN` | env | `argocd app wait` only (read/sync scope) |
| `SONAR_TOKEN`, `SEMGREP_APP_TOKEN`, `SNYK_TOKEN` | repo | optional scanners |
| `SLACK_WEBHOOK_URL` | repo | notifications |
| `GITOPS_APP_ID` + `GITOPS_APP_PRIVATE_KEY` | repo | GitHub App to open PRs (better than PAT) |

**Variables:** `AWS_REGION`, `AWS_ACCOUNT_ID`, `ECR_REGISTRY`, `CLUSTER_NAME`,
`ARGOCD_SERVER`, `BASE_URL_DEV|QA|STAGING|PROD`, `HELM_VERSION`, `KUBE_VERSION`.

> Note there are **no long-lived AWS keys and no kubeconfig** in that list. That is the goal.

---

**Next:** [Phase 7 — Security](./06-security.md)
