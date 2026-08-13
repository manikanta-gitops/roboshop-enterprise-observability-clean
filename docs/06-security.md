> **Documentation status:** historical design/review material. For the current implementation, see `docs/README.md` and `docs/15-production-standard.md`.

# Phase 7 — DevSecOps

> **Current State:** Checkov on rendered manifests (with SARIF upload) — and nothing else.
> Excellent pod-level hardening in the charts, ESO/Secrets Manager for secrets.
> **Score: build-time 5/10, runtime 4/10, supply chain 2/10.**

Security must be applied at **four gates**. A control at only one gate is theatre.

```text
 GATE 1: DEVELOPER          GATE 2: CI                GATE 3: REGISTRY        GATE 4: RUNTIME
 pre-commit hooks           SAST · SCA · secrets      scan-on-push            admission control
 gitleaks, tf fmt           IaC scan · image scan     signing · SBOM          Kyverno / Gatekeeper
 IDE linters                license scan              immutable tags          Falco · PSA · netpol
 ───────────────────────────────────────────────────────────────────────────────────────────►
 cheapest to fix                                                          most expensive to fix
```

---

## 7.1 Tool-by-tool: what it is, why it exists, where it runs

### Static analysis (your code)

| Tool | What it finds | Why you need it here | Gate |
|---|---|---|---|
| **CodeQL** | Semantic dataflow bugs: SQLi, command injection, SSRF, path traversal, XSS | `shipping` builds SQL against MySQL; `user`/`cart` take untrusted input; `frontend` renders it | CI, PR |
| **Semgrep** | Pattern-based rules, including **your own org rules** | Enforce "no `eval`", "no `child_process.exec` with template strings", "no hardcoded ARN/account id" — CodeQL can't express house rules as cheaply | CI, PR |
| **SonarQube** | Maintainability, duplication, coverage, quality gate | Enterprise reporting + trend; the "quality gate" is a merge blocker leadership understands | CI, PR (optional) |

```yaml
# security/scanners/semgrep.yml — house rules
rules:
  - id: no-hardcoded-aws-account
    pattern-regex: '\b\d{12}\b'
    paths: { include: ["charts/**", "gitops/**"] }
    message: "Hardcoded AWS account id — use a values variable."
    severity: ERROR
  - id: node-exec-injection
    languages: [javascript]
    pattern: child_process.exec(`...${$X}...`)
    message: "Command injection risk — use execFile with an argv array."
    severity: ERROR
```

### Dependencies (other people's code — where 80% of CVEs live)

| Tool | What it finds | Note |
|---|---|---|
| **Trivy (fs mode)** | CVEs in `package-lock.json`, `pom.xml`, `requirements.txt`; also IaC + secrets | One tool, three jobs. Use `--ignore-unfixed` so you don't block on unpatchable CVEs |
| **OWASP Dependency-Check** | NVD-backed CVE matching, esp. strong on Java | Your `shipping` service is Spring Boot — this is the Java-native answer |
| **Snyk** | CVEs + license + **fix PRs** + reachability analysis | Commercial; the reachability filter cuts noise dramatically |
| **Dependabot / Renovate** | Opens upgrade PRs automatically | Not a scanner — the *remediation* engine. Without it, scanners just generate a backlog |

### Secrets

| Tool | Why both? |
|---|---|
| **Gitleaks** | Fast regex+entropy, great as a **pre-commit hook** — stops the leak before it exists |
| **TruffleHog** | **Verifies** candidate secrets by calling the provider's API — near-zero false positives, and scans full Git history |

> **Critical:** a secret in Git history is compromised even after you delete the file. The
> response is always *rotate the credential*, then rewrite history. Both tools scan history
> because of this.

### Infrastructure & Kubernetes

| Tool | Layer | Why |
|---|---|---|
| **Checkov** *(you have this)* | Terraform + rendered K8s | Broad policy library, CIS-mapped, SARIF output |
| **tfsec / Trivy config** | Terraform | Second opinion; catches unencrypted S3, open SGs, public RDS |
| **kube-linter / Polaris** | rendered K8s | Best-practice checks Checkov misses (missing probes, `:latest`, no PDB) |
| **kubeconform** *(you have this)* | rendered K8s | Schema correctness — different question from policy |
| **kube-bench** | live cluster | **CIS Kubernetes Benchmark** compliance evidence. Run as a scheduled Job, export results to S3 |
| **kube-hunter** | live cluster | Offensive: actively probes for exposed kubelet, etcd, dashboards. Run from *outside* the cluster in a pen-test window |

### Runtime

| Tool | Role | Why it is not optional |
|---|---|---|
| **Kyverno** | Admission control, YAML-native policies | Checkov runs in CI. **Nothing today stops `kubectl apply` of a privileged pod.** Kyverno is the enforcement backstop |
| **OPA Gatekeeper** | Admission control, Rego | Alternative to Kyverno; choose one. Rego is more expressive, Kyverno is far easier to maintain. **Recommendation: Kyverno**, Gatekeeper only if you already have Rego expertise |
| **Pod Security Admission** | Built-in namespace-level baseline | Free, zero-dependency `restricted` enforcement. Use *with* Kyverno, not instead of |
| **Falco** | Runtime threat detection (eBPF syscalls) | Detects what admission cannot: a shell spawned in a container, `/etc/shadow` read, outbound connection to a mining pool, package manager run at runtime |

### Supply chain

| Tool | Role |
|---|---|
| **Cosign** | Keyless (OIDC/Fulcio/Rekor) signing of images and Helm charts. Proves "this artifact was built by *this* workflow from *this* commit" |
| **Syft** | Generates the SBOM (SPDX/CycloneDX) |
| **Cosign attest** | Binds the SBOM (and SLSA provenance) to the image digest as a signed attestation |
| **Rekor** | Public transparency log — tamper-evident record of every signature |
| **Kyverno `verifyImages`** | Closes the loop: the cluster **refuses to run an unsigned image** |

---

## 7.2 Kyverno policies to ship on day one

```yaml
# security/policies/kyverno/01-require-signed-images.yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-signed-images
spec:
  validationFailureAction: Enforce      # start Audit for 2 weeks, then flip
  background: false
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any: [{ resources: { kinds: [Pod], namespaces: ["roboshop*"] } }]
      verifyImages:
        - imageReferences: ["*.dkr.ecr.*.amazonaws.com/roboshop/*"]
          mutateDigest: true            # rewrites tag → digest at admission. Huge win.
          required: true
          attestors:
            - entries:
                - keyless:
                    subject: "https://github.com/roboshop/roboshop-platform/.github/workflows/app-ci.yaml@refs/heads/main"
                    issuer: "https://token.actions.githubusercontent.com"
                    rekor: { url: https://rekor.sigstore.dev }
```

```yaml
# 02-registry-and-tags.yaml — blocks Docker Hub and :latest (fixes findings W8/W9)
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: trusted-registry-only }
spec:
  validationFailureAction: Enforce
  rules:
    - name: only-ecr
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Images must come from the roboshop ECR registry."
        pattern:
          spec:
            =(initContainers): [{ image: "123456789012.dkr.ecr.ap-south-1.amazonaws.com/*" }]
            containers:        [{ image: "123456789012.dkr.ecr.ap-south-1.amazonaws.com/*" }]
    - name: disallow-latest
      match: { any: [{ resources: { kinds: [Pod] } }] }
      validate:
        message: "Mutable tag ':latest' is forbidden — pin a version or digest."
        pattern: { spec: { containers: [{ image: "!*:latest" }] } }
```

```yaml
# 03-baseline-hardening.yaml — enforces what your charts already do, for everything else
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata: { name: pod-hardening }
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-non-root-and-limits
      match: { any: [{ resources: { kinds: [Pod], namespaces: ["roboshop*"] } }] }
      validate:
        message: "Pods must run non-root, drop all caps, and declare resource requests/limits."
        pattern:
          spec:
            securityContext: { runAsNonRoot: true }
            containers:
              - securityContext:
                  allowPrivilegeEscalation: false
                  privileged: false
                  capabilities: { drop: ["ALL"] }
                resources:
                  requests: { cpu: "?*", memory: "?*" }
                  limits:   { memory: "?*" }
    - name: require-probes
      match: { any: [{ resources: { kinds: [Deployment, StatefulSet] } }] }
      validate:
        message: "Every container needs readiness and liveness probes."
        pattern:
          spec: { template: { spec: { containers: [{ readinessProbe: "?*", livenessProbe: "?*" }] } } }
    - name: require-ownership-labels
      match: { any: [{ resources: { kinds: [Deployment, StatefulSet, Service] } }] }
      validate:
        message: "app.kubernetes.io/name and roboshop.io/owner are mandatory."
        pattern:
          metadata: { labels: { "app.kubernetes.io/name": "?*", "roboshop.io/owner": "?*" } }
```

> **Rollout discipline:** ship every policy with `validationFailureAction: Audit` first, watch
> `PolicyReport` for two weeks, fix violations, *then* flip to `Enforce`. Flipping straight to
> Enforce in a live cluster is how you cause the outage you were trying to prevent.
> Always exclude `kube-system`, `argocd`, and your monitoring namespaces.

---

## 7.3 Falco — runtime detection

```yaml
# security/falco/rules-custom.yaml
- rule: Shell spawned in Roboshop container
  desc: Interactive shell in a production container — nothing legitimate does this
  condition: >
    spawned_process and container
    and k8s.ns.name startswith "roboshop"
    and proc.name in (bash, sh, zsh, ash, dash)
  output: >
    Shell in container (user=%user.name ns=%k8s.ns.name pod=%k8s.pod.name
    image=%container.image.repository cmd=%proc.cmdline)
  priority: WARNING
  tags: [container, shell, mitre_execution]

- rule: Outbound connection to non-VPC destination
  desc: Possible data exfiltration or C2 beacon
  condition: >
    outbound and container and k8s.ns.name startswith "roboshop"
    and not fd.sip in (rfc_1918_addresses)
    and not fd.sport in (443, 53)
  output: "Unexpected egress (pod=%k8s.pod.name dest=%fd.rip:%fd.rport)"
  priority: CRITICAL

- rule: Write below /etc in a read-only-rootfs container
  condition: open_write and container and fd.name startswith /etc
  output: "Write to /etc (pod=%k8s.pod.name file=%fd.name)"
  priority: CRITICAL
```

Route Falco → **Falcosidekick** → Alertmanager/Slack/ + S3 for retention.

---

## 7.4 Compliance jobs

```yaml
# security/compliance/kube-bench-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata: { name: kube-bench, namespace: security }
spec:
  schedule: "0 3 * * 0"                 # weekly
  jobTemplate:
    spec:
      template:
        spec:
          hostPID: true
          serviceAccountName: kube-bench   # IRSA → s3:PutObject
          restartPolicy: Never
          tolerations: [{ operator: Exists }]
          containers:
            - name: kube-bench
              image: docker.io/aquasec/kube-bench:v0.9.3
              command: ["kube-bench","run","--targets","node","--benchmark","eks-1.5.0","--json"]
              volumeMounts:
                - { name: var-lib-kubelet, mountPath: /var/lib/kubelet, readOnly: true }
                - { name: etc-kubernetes,  mountPath: /etc/kubernetes,  readOnly: true }
```

Ship results to S3 as **compliance evidence** — when an auditor asks "prove your nodes meet
CIS EKS 1.5", you hand them a dated JSON, not a screenshot.

---

## 7.5 RBAC & identity

| Principle | Implementation |
|---|---|
| Workloads need no API access | `automountServiceAccountToken: false` ✅ *already done* |
| One identity per service | One `ServiceAccount` per chart + one IRSA role per SA (fixes S11) |
| Humans get least privilege | EKS **Access Entries**: devs → `view` in `roboshop-dev`; SRE → `edit`; `cluster-admin` only via a break-glass role that fires a CloudTrail alarm |
| No shared credentials | SSO/OIDC into ArgoCD and the AWS console; disable ArgoCD's local `admin` |
| Audit everything | EKS audit logs → CloudWatch → metric filter on `system:masters` usage → alarm |

---

## 7.6 Specific remediations for this repository

| # | Finding | Fix |
|---|---|---|
| S1 | `mysql/Dockerfile` bakes `MYSQL_ROOT_PASSWORD="RoboShop@1"` | Delete the `ARG` default; `ENV` only from runtime; add a Semgrep rule banning `PASSWORD` in Dockerfiles |
| S2 | Unsigned mutable Docker Hub images in prod | ECR + `IMMUTABLE` tags + digest pin + Cosign + Kyverno `verifyImages` |
| S3 | CI-only policy | Deploy Kyverno + PSA `restricted` label on `roboshop*` |
| S4 | Docker Hub is a prod dependency | ECR pull-through cache for upstream `mongo`, `mysql`, `redis`, `rabbitmq`, `nginx` |
| S5 | AppProject allows all namespaced kinds | Add `namespaceResourceBlacklist` for ClusterRole/Binding/ResourceQuota (Phase 5 §5.4) |
| S6 | Actions pinned to mutable tags | Pin to commit SHA; enable Dependabot for `github-actions` ecosystem |
| S7 | No secret scanning | Gitleaks in pre-commit + CI; TruffleHog nightly over full history |
| S8 | No SBOM/provenance | Syft + `cosign attest`; target SLSA Build L3 via GitHub's reusable-workflow provenance |
| S9 | `payment/__pycache__/*.pyc` committed | `git rm --cached` + `.gitignore` + `check-added-large-files` pre-commit |
| S10 | No egress restriction | Default-deny egress NetworkPolicy + explicit allows (Phase 4 §4.11) |
| S11 | One shared ServiceAccount | Per-service SA + per-service IRSA |
| S12 | No CloudTrail/GuardDuty/Config | Terraform Phase 3 §3.8; add GuardDuty EKS Runtime Monitoring + Security Hub aggregation |

---

## 7.7 Layered defence summary (the interview answer)

> "We defend at four gates. **Pre-commit** stops secrets before they exist. **CI** runs SAST
> (CodeQL, Semgrep), SCA (Trivy, OWASP DC), IaC policy (Checkov, tfsec) and image scanning
> (Trivy) — and the image is scanned *before* it is pushed, so a vulnerable artifact never
> reaches the registry. At the **registry** we use immutable tags, scan-on-push, Cosign
> keyless signatures and an attached SBOM attestation. At **runtime**, Pod Security Admission
> sets the `restricted` baseline, Kyverno enforces signed-image + trusted-registry +
> hardening policies and mutates tags to digests at admission, default-deny NetworkPolicies
> constrain lateral movement and egress, and Falco watches syscalls for anything that gets
> through. Secrets never enter Git — External Secrets pulls from AWS Secrets Manager via
> IRSA, and etcd is envelope-encrypted with a customer-managed KMS key. Every control emits
> evidence: SARIF to GitHub Security, PolicyReports from Kyverno, kube-bench JSON to S3."

---

**Next:** [Phase 8 — Observability](./07-observability.md)
