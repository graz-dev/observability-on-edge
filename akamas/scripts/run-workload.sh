#!/bin/bash
# run-workload.sh — called by Akamas after apply-config.sh.
# Creates a k6 TestRun in the Civo cluster and waits for it to finish.
# Akamas then queries Prometheus over the steady-state measurement window.
#
# Runs on the Akamas toolbox with the Civo kubeconfig available.
# KUBECONFIG is inherited from the Akamas environment; fall back to
# /work/kubeconfig if not already set.
export KUBECONFIG="${KUBECONFIG:-/work/kubeconfig}"

set -euo pipefail

NAMESPACE="${NAMESPACE:-testing}"
TESTRUN_NAME="akamas-opt-workload"
TIMEOUT_SECONDS=1080  # 18 min hard timeout — k6 runs 12m30s + ~3min scheduling/cleanup overhead

START_TS=$(date +%s)
log() { echo "[run-workload] $(date '+%H:%M:%S') $*"; }

log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Starting workload run  (namespace: ${NAMESPACE})"
log "  TestRun: ${TESTRUN_NAME}"
log "  Timeout: ${TIMEOUT_SECONDS}s"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── 1. Clean up any previous run ────────────────────────────────────────────
log "Step 1/4 — deleting previous TestRun (if any)..."
kubectl delete testrun "$TESTRUN_NAME" -n "$NAMESPACE" --ignore-not-found=true

# Wait for the old runner pods to terminate before starting a new test.
kubectl wait pod \
  -n "$NAMESPACE" \
  -l "k6_cr=${TESTRUN_NAME}" \
  --for=delete \
  --timeout=60s 2>/dev/null || true
log "  ✓ Cleanup done"

# ── 2. Create the optimisation TestRun ──────────────────────────────────────
# Uses a dedicated ConfigMap (k6-optimization-script) with a shortened test:
#   30s ramp-up → 5 min steady (8 VUs) → 30s ramp-down  ≈ 6 min total.
log "Step 2/4 — creating TestRun..."
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: k6.io/v1alpha1
kind: TestRun
metadata:
  name: ${TESTRUN_NAME}
  namespace: ${NAMESPACE}
spec:
  parallelism: 1
  script:
    configMap:
      name: k6-optimization-script
      file: k6-optimization.js
  runner:
    image: grafana/k6:latest
    imagePullPolicy: IfNotPresent
    nodeSelector:
      node-role: load-test
    env:
      - name: BASE_URL
        value: http://edge-demo-app.app.svc.cluster.local:8080
    resources:
      requests:
        cpu: "200m"
        memory: "128Mi"
      limits:
        cpu: "500m"
        memory: "256Mi"
EOF
log "  ✓ TestRun created"

# ── 3. Wait for the runner pod to appear ────────────────────────────────────
log "Step 3/4 — waiting for runner pod to be scheduled..."
DEADLINE=$((SECONDS + 60))
POD=""
while [[ $SECONDS -lt $DEADLINE ]]; do
  POD=$(kubectl get pod -n "$NAMESPACE" -l "k6_cr=${TESTRUN_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$POD" ]] && break
  sleep 3
done

if [[ -z "$POD" ]]; then
  log "ERROR: runner pod did not appear within 60s"
  exit 1
fi

log "  ✓ Runner pod: ${POD}"

# ── 4. Wait for the pod to complete ─────────────────────────────────────────
log "Step 4/4 — waiting for k6 test to complete (timeout: ${TIMEOUT_SECONDS}s)..."

kubectl wait pod "$POD" \
  -n "$NAMESPACE" \
  --for=condition=Ready \
  --timeout=30s 2>/dev/null || true

kubectl wait pod "$POD" \
  -n "$NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout="${TIMEOUT_SECONDS}s"

EXIT_CODE=$(kubectl get pod "$POD" -n "$NAMESPACE" \
  -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || echo "0")

if [[ "$EXIT_CODE" != "0" ]]; then
  log "ERROR: k6 test failed (exit code ${EXIT_CODE})"
  kubectl logs "$POD" -n "$NAMESPACE" --tail=50 || true
  exit 1
fi

ELAPSED=$(( $(date +%s) - START_TS ))
log "  ✓ k6 test completed successfully"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "Workload complete — Akamas will now collect metrics  (total: ${ELAPSED}s)"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
