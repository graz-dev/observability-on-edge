#!/bin/bash
# verify-setup.sh — End-to-end verification of the Akamas integration.
# Run from the repo root after: ./scripts/setup.sh --env civo --akamas
#
# Usage:
#   ./akamas/scripts/verify-setup.sh [options]
#
# Options:
#   --prometheus-ip IP   Override auto-detected Prometheus LB IP
#   --grafana-ip    IP   Override auto-detected Grafana LB IP
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
GRAFANA_IP_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prometheus-ip) PROMETHEUS_IP_OVERRIDE="$2"; shift 2;;
    --grafana-ip)    GRAFANA_IP_OVERRIDE="$2";    shift 2;;
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
  PROMETHEUS_LB=$(kubectl get svc prometheus -n hub-obs \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

if [[ -n "$GRAFANA_IP_OVERRIDE" ]]; then
  GRAFANA_LB="$GRAFANA_IP_OVERRIDE"
else
  GRAFANA_LB=$(kubectl get svc grafana -n hub-obs \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
fi

echo "  Prometheus LB : ${PROMETHEUS_LB:-<not found>}"
echo "  Grafana LB    : ${GRAFANA_LB:-<not found>}"
echo ""

# ── Check helpers ─────────────────────────────────────────────────────────────
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
echo -n "  [1/9] Prometheus health endpoint... "
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
echo -n "  [2/9] Collector target UP in Prometheus... "
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
    run_check "Collector target UP" "fail" "No collector scrape target found (check prometheus job)"
  fi
fi

# ── Check 3: container_memory_working_set_bytes ────────────────────────────────
echo -n "  [3/9] working_set metric present... "
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
echo -n "  [4/9] process_rss metric present... "
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
echo -n "  [5/9] cpu metric present... "
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

# ── Check 6: kubeconfig / cluster reachable ───────────────────────────────────
echo -n "  [6/9] kubectl cluster reachable... "
node_out=$(kubectl get nodes -o name 2>/dev/null || echo "")
node_count=$(echo "$node_out" | grep -c "^node/" 2>/dev/null || echo "0")
if [[ "$node_count" -ge 2 ]]; then
  run_check "kubectl cluster reachable" "pass" "${node_count} nodes visible"
else
  run_check "kubectl cluster reachable" "fail" "Expected >= 2 nodes, got: '${node_out}'"
fi

# ── Check 7: ConfigMap otel-collector-config present ─────────────────────────
echo -n "  [7/9] ConfigMap otel-collector-config present... "
cm_out=$(kubectl get configmap otel-collector-config -n edge-obs -o name 2>/dev/null || echo "")
if echo "$cm_out" | grep -q "configmap/otel-collector-config"; then
  run_check "ConfigMap otel-collector-config" "pass" "configmap/otel-collector-config found in edge-obs"
else
  run_check "ConfigMap otel-collector-config" "fail" "ConfigMap not found in edge-obs namespace"
fi

# ── Check 8: k6 TestRun CRD present ──────────────────────────────────────────
echo -n "  [8/9] k6 TestRun CRD present... "
crd_out=$(kubectl api-resources --api-group=k6.io 2>/dev/null || echo "")
if echo "$crd_out" | grep -qi "testrun"; then
  run_check "k6 CRD present" "pass" "k6.io/TestRun CRD found"
else
  run_check "k6 CRD present" "fail" "k6.io CRDs not found — k6 Operator not installed or not ready"
fi

# ── Check 9: Grafana dashboard loaded ────────────────────────────────────────
echo -n "  [9/9] Grafana dashboard 'otelcol-footprint-akamas' loaded... "
if [[ -z "$GRAFANA_LB" ]]; then
  run_check "Grafana dashboard loaded" "fail" "Grafana LB IP not available"
else
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
    run_check "Grafana dashboard loaded" "fail" "Dashboard not found — was the ConfigMap patched? (check: kubectl get cm grafana-dashboards -n hub-obs)"
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
  echo -e "\n${GREEN}${BOLD}All 9 checks passed.${NC} The Akamas setup is ready."
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
  echo "  • Prometheus LB not found: kubectl get svc prometheus -n hub-obs"
  echo "  • No collector metrics: check otel-collector pod is running in edge-obs namespace"
  echo "  • Dashboard missing: re-run the kubectl patch cm grafana-dashboards step in setup.sh"
  exit 1
fi
