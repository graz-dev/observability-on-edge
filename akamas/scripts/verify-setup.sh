#!/bin/bash
# verify-setup.sh — End-to-end verification of the Akamas integration.
# Run from the repo root after: ./scripts/setup.sh --env civo --akamas
#
# Usage:
#   ./akamas/scripts/verify-setup.sh [options]
#
# Options:
#   --prometheus-ip IP   Override auto-detected Prometheus LB IP
#   --runner-ip     IP   Override auto-detected akamas-runner LB IP
#   --grafana-ip    IP   Override auto-detected Grafana LB IP
#   --key           PATH Path to the SSH private key (default: ./akamas-runner-key)
#
# Exit codes: 0 = all checks passed, 1 = one or more checks failed

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Arg parsing ───────────────────────────────────────────────────────────────
PROMETHEUS_IP_OVERRIDE=""
RUNNER_IP_OVERRIDE=""
GRAFANA_IP_OVERRIDE=""
KEY_FILE="akamas-runner-key"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prometheus-ip) PROMETHEUS_IP_OVERRIDE="$2"; shift 2;;
    --runner-ip)     RUNNER_IP_OVERRIDE="$2";     shift 2;;
    --grafana-ip)    GRAFANA_IP_OVERRIDE="$2";    shift 2;;
    --key)           KEY_FILE="$2";               shift 2;;
    *) shift;;
  esac
done

# ── Auto-detect LB IPs ────────────────────────────────────────────────────────
echo -e "${CYAN}${BOLD}Akamas Setup Verifier${NC}"
echo "=============================="
echo ""
echo -e "${YELLOW}Detecting LoadBalancer IPs...${NC}"

if [[ -n "$PROMETHEUS_IP_OVERRIDE" ]]; then
  PROMETHEUS_LB="$PROMETHEUS_IP_OVERRIDE"
else
  PROMETHEUS_LB=$(kubectl get svc prometheus -n observability \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [[ -n "$RUNNER_IP_OVERRIDE" ]]; then
  RUNNER_LB="$RUNNER_IP_OVERRIDE"
else
  RUNNER_LB=$(kubectl get svc akamas-runner -n observability \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [[ -n "$GRAFANA_IP_OVERRIDE" ]]; then
  GRAFANA_LB="$GRAFANA_IP_OVERRIDE"
else
  GRAFANA_LB=$(kubectl get svc grafana -n observability \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

echo "  Prometheus LB : ${PROMETHEUS_LB:-<not found>}"
echo "  Runner LB     : ${RUNNER_LB:-<not found>}"
echo "  Grafana LB    : ${GRAFANA_LB:-<not found>}"
echo "  SSH key       : ${KEY_FILE}"
echo ""

# ── Check runner ─────────────────────────────────────────────────────────────
# Array of: "check_name" "pass|fail" "detail"
declare -a RESULTS=()
FAILED=0

run_check() {
  local name="$1"
  local result="$2"   # "pass" or "fail"
  local detail="$3"
  RESULTS+=("$name" "$result" "$detail")
  if [[ "$result" == "fail" ]]; then
    FAILED=1
    echo -e "  ${RED}✗${NC} ${name}: ${detail}"
  else
    echo -e "  ${GREEN}✓${NC} ${name}: ${detail}"
  fi
}

# Helper: query PromQL and check result is non-empty
promql_query() {
  local ip="$1"
  local query="$2"
  curl -sf --max-time 10 \
    "http://${ip}:9090/api/v1/query?query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$query")" \
    2>/dev/null || echo ""
}

promql_has_data() {
  local response="$1"
  # Returns true if result array is non-empty
  echo "$response" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    result = d.get('data', {}).get('result', [])
    sys.exit(0 if result else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null
}

echo -e "${YELLOW}Running checks...${NC}"
echo ""

# ── Check 1: Prometheus reachable ─────────────────────────────────────────────
echo -n "  [1/11] Prometheus health endpoint... "
if [[ -z "$PROMETHEUS_LB" ]]; then
  run_check "Prometheus reachable" "fail" "LB IP not available"
else
  if curl -sf --max-time 10 "http://${PROMETHEUS_LB}:9090/-/healthy" >/dev/null 2>&1; then
    run_check "Prometheus reachable" "pass" "http://${PROMETHEUS_LB}:9090/-/healthy → 200"
  else
    run_check "Prometheus reachable" "fail" "http://${PROMETHEUS_LB}:9090/-/healthy unreachable"
  fi
fi

# ── Check 2: Collector scrape target UP ───────────────────────────────────────
echo -n "  [2/11] Collector target UP in Prometheus... "
if [[ -z "$PROMETHEUS_LB" ]]; then
  run_check "Collector target UP" "fail" "Prometheus LB not available"
else
  response=$(promql_query "$PROMETHEUS_LB" 'up{job=~".*collector.*"}')
  if promql_has_data "$response"; then
    value=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
results = d.get('data', {}).get('result', [])
vals = [r['value'][1] for r in results]
print(','.join(vals))
" 2>/dev/null || echo "?")
    run_check "Collector target UP" "pass" "up{job=~\".*collector.*\"} = ${value}"
  else
    run_check "Collector target UP" "fail" "No collector scrape target found (check ServiceMonitor / prometheus job)"
  fi
fi

# ── Check 3: container_memory_working_set_bytes ────────────────────────────────
echo -n "  [3/11] working_set metric present... "
if [[ -z "$PROMETHEUS_LB" ]]; then
  run_check "working_set metric present" "fail" "Prometheus LB not available"
else
  response=$(promql_query "$PROMETHEUS_LB" 'container_memory_working_set_bytes{pod=~"otel-collector.*"}')
  if promql_has_data "$response"; then
    value=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['data']['result'][0]
print('{:.1f} MB'.format(float(r['value'][1]) / 1e6))
" 2>/dev/null || echo "present")
    run_check "working_set metric present" "pass" "container_memory_working_set_bytes = ${value}"
  else
    run_check "working_set metric present" "fail" "no data — cAdvisor not scraped (check kubelet/cadvisor scrape job)"
  fi
fi

# ── Check 4: otelcol_process_memory_rss ────────────────────────────────────────
echo -n "  [4/11] process_rss metric present... "
if [[ -z "$PROMETHEUS_LB" ]]; then
  run_check "process_rss metric present" "fail" "Prometheus LB not available"
else
  response=$(promql_query "$PROMETHEUS_LB" 'otelcol_process_memory_rss')
  if promql_has_data "$response"; then
    value=$(echo "$response" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d['data']['result'][0]
print('{:.1f} MB'.format(float(r['value'][1]) / 1e6))
" 2>/dev/null || echo "present")
    run_check "process_rss metric present" "pass" "otelcol_process_memory_rss = ${value}"
  else
    run_check "process_rss metric present" "fail" "no data — collector not exposing internal metrics"
  fi
fi

# ── Check 5: container_cpu_usage_seconds_total ─────────────────────────────────
echo -n "  [5/11] cpu metric present... "
if [[ -z "$PROMETHEUS_LB" ]]; then
  run_check "cpu metric present" "fail" "Prometheus LB not available"
else
  response=$(promql_query "$PROMETHEUS_LB" 'container_cpu_usage_seconds_total{pod=~"otel-collector.*"}')
  if promql_has_data "$response"; then
    run_check "cpu metric present" "pass" "container_cpu_usage_seconds_total present"
  else
    run_check "cpu metric present" "fail" "no data — cAdvisor not scraped"
  fi
fi

# ── Check 6: SSH to runner ─────────────────────────────────────────────────────
echo -n "  [6/11] SSH to akamas-runner... "
if [[ -z "$RUNNER_LB" ]]; then
  run_check "SSH to runner" "fail" "Runner LB IP not available"
elif [[ ! -f "$KEY_FILE" ]]; then
  run_check "SSH to runner" "fail" "Key file '${KEY_FILE}' not found (use --key path/to/key)"
else
  ssh_out=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "akamas@${RUNNER_LB}" "echo SSH_OK" 2>/dev/null || echo "")
  if [[ "$ssh_out" == "SSH_OK" ]]; then
    run_check "SSH to runner" "pass" "akamas@${RUNNER_LB} → SSH_OK"
  else
    run_check "SSH to runner" "fail" "Could not connect to akamas@${RUNNER_LB} (response: '${ssh_out}')"
  fi
fi

# ── Check 7: kubectl in runner ────────────────────────────────────────────────
echo -n "  [7/11] kubectl in runner (get nodes)... "
if [[ -z "$RUNNER_LB" || ! -f "$KEY_FILE" ]]; then
  run_check "kubectl in runner" "fail" "Skipped (SSH prerequisites failed)"
else
  node_out=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "akamas@${RUNNER_LB}" "kubectl get nodes -o name 2>/dev/null" 2>/dev/null || echo "")
  node_count=$(echo "$node_out" | grep -c "^node/" 2>/dev/null || echo "0")
  if [[ "$node_count" -ge 2 ]]; then
    run_check "kubectl in runner" "pass" "${node_count} nodes visible from runner"
  else
    run_check "kubectl in runner" "fail" "Expected >= 2 nodes, got: '${node_out}'"
  fi
fi

# ── Check 8: ConfigMap accessible from runner ─────────────────────────────────
echo -n "  [8/11] ConfigMap otel-collector-config accessible from runner... "
if [[ -z "$RUNNER_LB" || ! -f "$KEY_FILE" ]]; then
  run_check "ConfigMap accessible" "fail" "Skipped (SSH prerequisites failed)"
else
  cm_out=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "akamas@${RUNNER_LB}" \
    "kubectl get configmap otel-collector-config -n observability -o name 2>/dev/null" 2>/dev/null || echo "")
  if echo "$cm_out" | grep -q "configmap/otel-collector-config"; then
    run_check "ConfigMap accessible" "pass" "configmap/otel-collector-config visible"
  else
    run_check "ConfigMap accessible" "fail" "ConfigMap not found from runner (RBAC issue?)"
  fi
fi

# ── Check 9: DaemonSet patchable (dry-run) ────────────────────────────────────
echo -n "  [9/11] DaemonSet patchable (dry-run from runner)... "
if [[ -z "$RUNNER_LB" || ! -f "$KEY_FILE" ]]; then
  run_check "DaemonSet patchable" "fail" "Skipped (SSH prerequisites failed)"
else
  patch_out=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=15 \
    -o BatchMode=yes \
    "akamas@${RUNNER_LB}" \
    "kubectl patch daemonset otel-collector -n observability --dry-run=server -p '{\"spec\":{}}' 2>&1" 2>/dev/null || echo "ERROR")
  if echo "$patch_out" | grep -qiE "(daemonset.apps|dry run|no change)"; then
    run_check "DaemonSet patchable" "pass" "dry-run patch accepted"
  else
    run_check "DaemonSet patchable" "fail" "Patch rejected: ${patch_out}"
  fi
fi

# ── Check 10: k6 TestRun CRD present ─────────────────────────────────────────
echo -n "  [10/11] k6 TestRun CRD present... "
if [[ -z "$RUNNER_LB" || ! -f "$KEY_FILE" ]]; then
  run_check "k6 CRD present" "fail" "Skipped (SSH prerequisites failed)"
else
  crd_out=$(ssh -i "$KEY_FILE" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    "akamas@${RUNNER_LB}" \
    "kubectl api-resources --api-group=k6.io 2>/dev/null" 2>/dev/null || echo "")
  if echo "$crd_out" | grep -qi "testrun"; then
    run_check "k6 CRD present" "pass" "k6.io/TestRun CRD found"
  else
    run_check "k6 CRD present" "fail" "k6.io CRDs not found — k6 Operator not installed or not ready"
  fi
fi

# ── Check 11: Grafana dashboard loaded ────────────────────────────────────────
echo -n "  [11/11] Grafana dashboard 'otelcol-footprint-akamas' loaded... "
if [[ -z "$GRAFANA_LB" ]]; then
  run_check "Grafana dashboard loaded" "fail" "Grafana LB IP not available"
else
  # Grafana 10.x requires authentication for all API endpoints.
  dash_out=$(curl -sf --max-time 10 \
    -u admin:admin \
    "http://${GRAFANA_LB}:3000/api/dashboards/uid/otelcol-footprint-akamas" \
    2>/dev/null || echo "")
  if echo "$dash_out" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    assert d.get('dashboard', {}).get('uid') == 'otelcol-footprint-akamas'
    sys.exit(0)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    run_check "Grafana dashboard loaded" "pass" "uid=otelcol-footprint-akamas found"
  else
    run_check "Grafana dashboard loaded" "fail" "Dashboard not found — was the ConfigMap patched? (check: kubectl get cm grafana-dashboards -n observability)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────────────────"
echo -e "${BOLD}Summary${NC}"
echo "────────────────────────────────────────────────"
printf "  %-45s  %s\n" "Check" "Status"
printf "  %-45s  %s\n" "─────" "──────"

idx=0
while [[ $idx -lt ${#RESULTS[@]} ]]; do
  name="${RESULTS[$idx]}"
  result="${RESULTS[$((idx+1))]}"
  detail="${RESULTS[$((idx+2))]}"
  if [[ "$result" == "pass" ]]; then
    printf "  %-45s  ${GREEN}PASS${NC}\n" "$name"
  else
    printf "  %-45s  ${RED}FAIL${NC}  — %s\n" "$name" "$detail"
  fi
  idx=$((idx+3))
done

echo "────────────────────────────────────────────────"

if [[ "$FAILED" -eq 0 ]]; then
  echo -e "\n${GREEN}${BOLD}All 11 checks passed.${NC} The Akamas setup is ready."
  echo ""
  echo "Next steps:"
  echo "  • Start the load test:  ./scripts/load-generator.sh"
  echo "  • Verify baseline in Grafana → 'OTel Collector — Footprint & Go Runtime'"
  echo "  • Then create and start the Akamas study"
  exit 0
else
  echo -e "\n${RED}${BOLD}One or more checks failed.${NC} Fix the issues above before starting the study."
  echo ""
  echo "Common fixes:"
  echo "  • Prometheus LB not found: kubectl get svc prometheus -n observability"
  echo "  • No collector metrics: check otel-collector pod is running and ServiceMonitor is present"
  echo "  • SSH fails: ensure the key file exists and matches the deployed public key"
  echo "  • Dashboard missing: re-run the kubectl patch cm grafana-dashboards step in setup.sh"
  exit 1
fi
