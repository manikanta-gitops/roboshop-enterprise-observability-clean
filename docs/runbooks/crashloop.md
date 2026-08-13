# CrashLoopBackOff Runbook

1. Identify the namespace/pod: `kubectl -n <env> get pods`.
2. Inspect events: `kubectl -n <env> describe pod <pod>`.
3. Inspect previous logs: `kubectl -n <env> logs <pod> --previous`.
4. Check the deployment rollout: `kubectl -n <env> rollout status deployment/<name>`.
5. Compare the image digest with the release manifest in `releases/<version>.yaml`.
6. If the release is unhealthy, promote the last known-good version through GitOps using `scripts/rollback.sh`; do not use `kubectl edit` as a permanent fix.
