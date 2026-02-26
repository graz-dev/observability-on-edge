#!/bin/bash
# ============================================================
#  demo.sh — Orchestrated live demo
#  "Making Observability Work at the Edge" — KubeCon EU 2026
#
#  Usage:
#    ./scripts/demo.sh [--env local|civo] [1|2|3]
#    ./scripts/demo.sh          # full run (Act 1 → 2 → 3), local
#    ./scripts/demo.sh 2        # start from Act 2
#    ./scripts/demo.sh --env civo 3  # Act 3 on Civo
#
#  Requires: kubectl, curl, python3
# ============================================================

set -euo pipefail

# ── Arg parsing ─────────────────────────────────────────────
DEMO_ENV="local"
START_ACT="1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) DEMO_ENV="$2"; shift 2;;
    [123]) START_ACT="$1"; shift;;
    *) shift;;
  esac
done

if [[ "$DEMO_ENV" != "local" && "$DEMO_ENV" != "civo" ]]; then
  echo "Usage: $(basename "$0") [--env local|civo] [1|2|3]"
  exit 1
fi

if ! [[ "$START_ACT" =~ ^[123]$ ]]; then
  echo "Usage: $(basename "$0") [--env local|civo] [1|2|3]"
  echo "  1  Full run: pre-flight → Act 1 → Act 2 → Act 3  (default)"
  echo "  2  Start at Act 2 (sampling)"
  echo "  3  Start at Act 3 (failure/restore only)"
  exit 1
fi

# ── Constants ──────────────────────────────────────────────
NAMESPACE="observability"
PROM_LOCAL_PORT=19090
TESTRUN_NAME="vessel-monitoring"
FAILURE_DURATION=90   # seconds to hold the link down
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Access URLs (env-dependent) ─────────────────────────────
if [[ "$DEMO_ENV" == "civo" ]]; then
  GRAFANA_LB=$(kubectl get svc grafana -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  JAEGER_LB=$(kubectl get svc jaeger -n "${NAMESPACE}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  GRAFANA_URL="http://${GRAFANA_LB}:3000"
  JAEGER_URL="http://${JAEGER_LB}:16686"
else
  GRAFANA_URL="http://localhost:30300"
  JAEGER_URL="http://localhost:30686"
fi

# ── Colors ─────────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
DIM='\033[2m';  NC='\033[0m';   BOLD='\033[1m'

# ── State ──────────────────────────────────────────────────
PROM_PF_PID=""
FAILURE_START=0
FAILURE_END=0
RESTORE_TIME=0
CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()

# ── Formatting ─────────────────────────────────────────────
header() {
  local title="$1"
  local width=56
  local pad=$(( (width - ${#title} - 2) / 2 ))
  echo ""
  echo -e "${W}╔$(printf '═%.0s' $(seq 1 $width))╗${NC}"
  printf "${W}║%*s${BOLD}%s${W}%*s║${NC}\n" $pad "" "$title" $(( width - pad - ${#title} )) ""
  echo -e "${W}╚$(printf '═%.0s' $(seq 1 $width))╝${NC}"
}

section() {
  echo -e "\n${C}${BOLD}▶ $1${NC}"
  echo -e "${DIM}$(printf '─%.0s' $(seq 1 56))${NC}"
}

ok()   { echo -e "  ${G}✓${NC} $1"; (( CHECKS_PASSED++ )) || true; }
fail() { echo -e "  ${R}✗${NC} $1"; (( CHECKS_FAILED++ )) || true; FAILED_CHECKS+=("$1"); }
warn() { echo -e "  ${Y}⚠${NC} $1"; }
info() { echo -e "  ${B}ℹ${NC} $1"; }

grafana_box() {
  echo -e "\n  ${Y}┌─ 🖥  GRAFANA ─────────────────────────────────────┐${NC}"
  while IFS= read -r line; do
    echo -e "  ${Y}│${NC}  $line"
  done <<< "$1"
  echo -e "  ${Y}└───────────────────────────────────────────────────┘${NC}"
}

press_enter() {
  echo -e "\n  ${DIM}Press Enter when ready to continue...${NC}"
  read -r
}

# ── Prometheus helpers ──────────────────────────────────────
start_prom_pf() {
  kubectl port-forward -n "${NAMESPACE}" svc/prometheus \
    "${PROM_LOCAL_PORT}":9090 &>/dev/null &
  PROM_PF_PID=$!
  sleep 2
}

# Returns a single float value for a PromQL query, or 0.0 on error
prom_value() {
  local query="$1"
  curl -sf -X POST "http://localhost:${PROM_LOCAL_PORT}/api/v1/query" \
    --data-urlencode "query=${query}" 2>/dev/null \
  | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  r = d.get('data', {}).get('result', [])
  print(float(r[0]['value'][1]) if r else 0.0)
except:
  print(0.0)
" 2>/dev/null || echo "0"
}

# Poll a metric until it satisfies a numeric condition or times out.
# op: gt | lt | eq | ge
# Returns 0 on success, 1 on timeout.
wait_for_metric() {
  local query="$1" op="$2" threshold="$3" timeout="$4" label="$5"
  local start=$SECONDS last_val=0

  while true; do
    last_val=$(prom_value "${query}")

    local ok_flag=0
    case "$op" in
      gt) python3 -c "exit(0 if ${last_val} >  ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      lt) python3 -c "exit(0 if ${last_val} <  ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      ge) python3 -c "exit(0 if ${last_val} >= ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
      eq) python3 -c "exit(0 if ${last_val} == ${threshold} else 1)" 2>/dev/null && ok_flag=1 || true ;;
    esac

    if [[ $ok_flag -eq 1 ]]; then
      ok "${label} (value=${last_val})"
      return 0
    fi

    if [[ $(( SECONDS - start )) -ge $timeout ]]; then
      warn "${label} — timeout ${timeout}s, last value=${last_val}"
      return 1
    fi

    sleep 5
  done
}

# Countdown with live queue-depth and throughput display
countdown_monitoring() {
  local total=$1
  local start=$SECONDS
  echo ""
  while [[ $(( SECONDS - start )) -lt $total ]]; do
    local remaining=$(( total - SECONDS + start ))
    local queue
    local throughput
    queue=$(prom_value 'sum(otelcol_exporter_queue_size) or vector(0)')
    throughput=$(prom_value 'rate(otelcol_exporter_sent_spans{exporter="otlp/jaeger"}[30s])')
    printf "  ${Y}⏱ %3ds${NC}  │  ${B}Log queue: %3s batches${NC}  │  ${R}Span throughput: %5.1f /s${NC}  \r" \
      "$remaining" "$queue" "$throughput"
    sleep 5
  done
  printf "\n"
}

# ── Pre-flight ──────────────────────────────────────────────
preflight() {
  section "Pre-flight checks"

  # kubectl context
  local ctx
  ctx=$(kubectl config current-context 2>/dev/null || echo "none")
  if [[ "$DEMO_ENV" == "local" ]]; then
    if [[ "$ctx" == *"edge-observability"* ]]; then
      ok "kubectl context: ${ctx}"
    else
      fail "Wrong context '${ctx}'. Expected 'k3d-edge-observability'. Run setup.sh."
      exit 1
    fi
  else
    ok "kubectl context: ${ctx}"
  fi

  # Namespace
  kubectl get namespace "${NAMESPACE}" &>/dev/null \
    && ok "Namespace '${NAMESPACE}' exists" \
    || { fail "Namespace '${NAMESPACE}' missing — run ./scripts/setup.sh --env ${DEMO_ENV}"; exit 1; }

  # All pods Running
  local not_running
  not_running=$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
    | { grep -v -E "(Running|Completed|Succeeded)" || true; } \
    | { grep -v "^$" || true; } \
    | wc -l | tr -d ' ')
  if [[ "$not_running" -eq 0 ]]; then
    ok "All pods Running"
  else
    warn "${not_running} pod(s) not Running — check: kubectl get pods -n ${NAMESPACE}"
    kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null \
      | { grep -v -E "(Running|Completed|Succeeded)" || true; } | sed 's/^/    /'
  fi

  # App health
  if kubectl exec -n "${NAMESPACE}" deployment/prometheus -- \
       wget -qO- http://edge-demo-app.observability.svc.cluster.local:8080/health \
       &>/dev/null; then
    ok "edge-demo-app is responding"
  else
    fail "edge-demo-app not responding — check app pod logs"
  fi

  # OTel Collector metrics visible in Prometheus
  local spans_rcvd
  spans_rcvd=$(prom_value 'otelcol_receiver_accepted_spans')
  if python3 -c "exit(0 if float('${spans_rcvd}') > 0 else 1)" 2>/dev/null; then
    ok "OTel Collector metrics in Prometheus (accepted_spans=${spans_rcvd})"
  else
    warn "OTel Collector metrics not yet in Prometheus — data may be starting up"
  fi

  # Grafana
  local grafana_code
  grafana_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    "${GRAFANA_URL}/api/health" 2>/dev/null || echo "000")
  if [[ "$grafana_code" == "200" ]]; then
    ok "Grafana accessible at ${GRAFANA_URL}"
  else
    fail "Grafana not accessible (HTTP ${grafana_code})"
  fi

  # Jaeger
  local jaeger_code
  jaeger_code=$(curl -sf -o /dev/null -w "%{http_code}" \
    "${JAEGER_URL}/" 2>/dev/null || echo "000")
  if [[ "$jaeger_code" == "200" ]]; then
    ok "Jaeger accessible at ${JAEGER_URL}"
  else
    warn "Jaeger not accessible (HTTP ${jaeger_code})"
  fi

  # No stale iptables rules from a previous run
  local CHAOS_POD
  CHAOS_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=network-chaos \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [[ -n "$CHAOS_POD" ]]; then
    local stale_rules
    # Check both iptables backends (nft and legacy) — k3d may use either.
    # Use { grep -c DROP || true; } so grep's exit-1-on-no-match doesn't trigger
    # the outer || echo 0, which would produce "0\n0" and break [[ -eq 0 ]].
    stale_rules=$(kubectl exec -n "${NAMESPACE}" "$CHAOS_POD" -- sh -c \
      '{ iptables -L FORWARD -n 2>/dev/null; iptables-legacy -L FORWARD -n 2>/dev/null; } | { grep -c DROP || true; }' \
      2>/dev/null || echo 0)
    if [[ "$stale_rules" -eq 0 ]]; then
      ok "No stale iptables DROP rules on edge node"
    else
      warn "${stale_rules} DROP rule(s) still in FORWARD chain — run ./scripts/restore-network.sh"
    fi
  else
    warn "network-chaos pod not found — cannot check iptables rules"
  fi
}

# ── Load test ───────────────────────────────────────────────
ensure_load_test() {
  section "Load test (k6 Operator)"

  local stage
  stage=$(kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.stage}' 2>/dev/null || echo "not-found")

  case "$stage" in
    "started")
      local runner_pod
      runner_pod=$(kubectl get pods -n "${NAMESPACE}" -l "k6_cr=${TESTRUN_NAME}" \
        --no-headers 2>/dev/null | head -1 | awk '{print $1}')
      ok "TestRun '${TESTRUN_NAME}' is running (pod: ${runner_pod:-?})"
      ;;
    "finished"|"stopped"|"error")
      warn "TestRun stage is '${stage}'. Recreating..."
      bash "${SCRIPT_DIR}/load-generator.sh"
      ;;
    "not-found")
      info "TestRun not found — starting load test..."
      bash "${SCRIPT_DIR}/load-generator.sh"
      ;;
    *)
      info "TestRun stage: '${stage}' (still initializing, waiting up to 60s)..."
      local start=$SECONDS
      while [[ $(( SECONDS - start )) -lt 60 ]]; do
        stage=$(kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" \
          -o jsonpath='{.status.stage}' 2>/dev/null || echo "")
        [[ "$stage" == "started" ]] && { ok "TestRun started"; return 0; }
        sleep 5
      done
      warn "TestRun not yet started after 60s — continuing anyway"
      ;;
  esac
}

# ── Baseline wait ───────────────────────────────────────────
wait_baseline() {
  echo ""
  echo -e "  ${DIM}Waiting 30s for baseline data to accumulate in Grafana...${NC}"
  for ((i=30; i>0; i--)); do
    printf "  %3ds remaining\r" "$i"; sleep 1
  done
  printf "\n"
}

# ── Act 1 ───────────────────────────────────────────────────
act1_guide() {
  header "ACT 1 — The system works (~5 min)"

  grafana_box "Open: ${GRAFANA_URL}
Dashboard: 'Vessel Operations'"

  echo ""
  echo -e "  ${W}Stat panels (top row):${NC}"
  echo -e "    ${G}Request Rate${NC}     total req/s across all endpoints"
  echo -e "    ${G}Error Rate${NC}       expect ~1.5–2%  (alerts endpoint, 20% fail rate)"
  echo -e "    ${G}P95 Latency${NC}      dominated by diagnostics (300–1500ms)"
  echo -e "    ${G}Diagnostics Run${NC}  counter of complex analysis runs"
  echo ""
  echo -e "  ${W}Time series (middle row):${NC}"
  echo -e "    ${G}Request Rate by Endpoint${NC}  4 lines — sensor endpoints higher volume"
  echo -e "    ${G}Latency P50/P95${NC}           diagnostics visually much slower"
  echo ""
  echo -e "  ${W}Logs panel (bottom):${NC}"
  echo -e "    Structured JSON with ${Y}trace_id${NC} — click to open trace in Jaeger"
  echo -e "    ${Y}Key point${NC}: ONLY errors + slow requests. Fast sensor reads are absent."
  echo ""

  local drop_pct
  drop_pct=$(prom_value \
    '(1 - sum(rate(otelcol_exporter_sent_spans[2m])) / sum(rate(otelcol_receiver_accepted_spans[2m]))) * 100')
  printf "  ${DIM}Live: tail sampling is dropping %.0f%% of spans right now${NC}\n" "$drop_pct"

  echo ""
  echo -e "  ${DIM}\"Every log entry here represents something worth looking at.${NC}"
  echo -e "  ${DIM}The thousands of 'engine reading normal' logs never leave the edge node.\"${NC}"

  press_enter
}

# ── Act 2 ───────────────────────────────────────────────────
act2_guide() {
  header "ACT 2 — We don't send everything (~7 min)"

  grafana_box "Dashboard: 'Edge Pipeline' → section: SAMPLING"

  echo ""
  echo -e "  ${W}Trace Data Reduction gauge (top-left):${NC}"
  local drop_pct
  drop_pct=$(prom_value \
    '(1 - sum(rate(otelcol_exporter_sent_spans[2m])) / sum(rate(otelcol_receiver_accepted_spans[2m]))) * 100')
  printf "    ${Y}Current: %.0f%%${NC} of spans dropped  (target: ~70–80%%)\n" "$drop_pct"
  echo ""
  echo -e "  ${W}Trace Flow: Received vs Exported (top-right):${NC}"
  echo -e "    Blue > green — the gap is what tail sampling drops"
  echo ""
  echo -e "  ${W}Sampling policies (otel-collector-config.yaml):${NC}"
  echo -e "    ${G}error-policy${NC}    → keep 100% of ERROR traces"
  echo -e "    ${G}latency-policy${NC}  → keep 100% of traces >200ms"
  echo -e "    ${R}everything else${NC} → dropped (~80% of traffic)"
  echo ""
  echo -e "  ${W}Log Flow: Fluent Bit Input vs Forwarded (bottom-left):${NC}"
  echo -e "    Filtering happens at Fluent Bit — before the OTel Collector"
  echo -e "    Identical criteria → ${Y}every sampled trace has a log entry${NC}"
  echo ""
  echo -e "  ${DIM}\"Two deterministic policies. No random sampling —${NC}"
  echo -e "  ${DIM}no blind spots for things that matter.\"${NC}"

  press_enter
}

# ── Act 3: failure ──────────────────────────────────────────
act3_failure() {
  header "ACT 3 — Link failure simulation"

  grafana_box "Dashboard: 'Edge Pipeline' → section: RESILIENCE
Watch 'Export Throughput' drop to zero.
Watch 'Trace Queue Depth' start rising."

  echo ""
  echo -e "  ${DIM}Press Enter to apply iptables DROP rules and cut the link...${NC}"
  read -r

  echo ""
  echo -e "  ${B}→ Blocking OTel Collector → Jaeger:4317, Prometheus:9090, Loki:3100${NC}"
  bash "${SCRIPT_DIR}/simulate-network-failure.sh"
  FAILURE_START=$(date +%s)

  echo ""
  echo -e "  ${R}$(printf '━%.0s' $(seq 1 56))${NC}"
  echo -e "  ${R}  LINK DOWN — collector cannot reach any hub backend${NC}"
  echo -e "  ${R}$(printf '━%.0s' $(seq 1 56))${NC}"

  # Verify throughput drops to 0
  echo ""
  echo -e "  ${B}→ Verifying export throughput drops to ~0 (timeout 60s)...${NC}"
  wait_for_metric \
    'rate(otelcol_exporter_sent_spans{exporter="otlp/jaeger"}[30s])' \
    "lt" "0.1" 60 "Export throughput dropped to ~0" || true

  # Show file storage immediately after detection
  sleep 8
  echo ""
  echo -e "  ${B}→ File storage on edge node (queued batches):${NC}"
  local COLLECTOR_POD CHAOS_POD_ACT3
  COLLECTOR_POD=$(kubectl get pod -n "${NAMESPACE}" -l app=otel-collector \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  CHAOS_POD_ACT3=$(kubectl get pod -n "${NAMESPACE}" -l app=network-chaos \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  # On local (k3d): chaos pod mounts the same hostPath as the collector → can list files.
  # On Civo: collector is distroless (no ls/find) and chaos pod mounts a hostPath that
  # is separate from the PVC where the collector actually writes → show PVC usage instead.
  _show_file_storage() {
    if [[ "$DEMO_ENV" == "local" ]]; then
      { [[ -n "$COLLECTOR_POD" ]] && \
          kubectl exec -n "${NAMESPACE}" "$COLLECTOR_POD" -- \
            ls -lah /var/lib/otelcol/file_storage/ 2>/dev/null; } || \
      { [[ -n "$CHAOS_POD_ACT3" ]] && \
          kubectl exec -n "${NAMESPACE}" "$CHAOS_POD_ACT3" -- \
            ls -lah /var/lib/otelcol/file_storage/ 2>/dev/null; } || \
      echo "    (file storage not readable)"
    else
      # Civo: collector writes to PVC (civo-volume block storage).
      # The collector image is distroless — no shell to exec into.
      # Show PVC capacity and the collector's accepted-vs-exported span delta instead.
      local pvc_capacity accepted exported queued
      pvc_capacity=$(kubectl get pvc otelcol-file-storage -n "${NAMESPACE}" \
        -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "?")
      accepted=$(prom_value 'sum(increase(otelcol_receiver_accepted_spans[2m]))')
      exported=$(prom_value 'sum(increase(otelcol_exporter_sent_spans[2m]))')
      queued=$(python3 -c "print(int(max(0, float('${accepted}') - float('${exported}'))))" 2>/dev/null || echo "?")
      echo "    PVC otelcol-file-storage (${pvc_capacity}) — writing bbolt files"
      echo "    ~${queued} spans accumulated in queue since link went down"
    fi
  }
  _show_file_storage | sed 's/^/    /'

  echo ""
  echo -e "  ${Y}Holding for ${FAILURE_DURATION}s — watch the queue depth rise in Grafana${NC}"
  countdown_monitoring "${FAILURE_DURATION}"

  # Snapshot file storage at end of outage
  echo ""
  echo -e "  ${B}→ File storage after ${FAILURE_DURATION}s outage:${NC}"
  _show_file_storage | sed 's/^/    /'

  FAILURE_END=$(date +%s)
  local duration=$(( FAILURE_END - FAILURE_START ))
  echo ""
  info "Failure window: $(date -r "$FAILURE_START" '+%H:%M:%S') → $(date -r "$FAILURE_END" '+%H:%M:%S') (${duration}s)"
}

# ── Act 3: restore ──────────────────────────────────────────
act3_restore() {
  echo ""
  echo -e "  ${DIM}Press Enter to restore the satellite link...${NC}"
  read -r

  echo ""
  echo -e "  ${B}→ Removing iptables DROP rules...${NC}"
  bash "${SCRIPT_DIR}/restore-network.sh"
  RESTORE_TIME=$(date +%s)

  echo ""
  echo -e "  ${G}$(printf '━%.0s' $(seq 1 56))${NC}"
  echo -e "  ${G}  LINK RESTORED — file-backed queue draining now${NC}"
  echo -e "  ${G}$(printf '━%.0s' $(seq 1 56))${NC}"

  grafana_box "Watch 'Export Throughput' spike above baseline.
After spike settles → queues have fully drained.
Watch 'Queue Depth' drop back to 0 (log queue draining).
Set time range to 'last 30m' to see the gap."

  # ── Check 1: trace queue drains to 0
  echo ""
  echo -e "  ${B}→ Waiting for trace queue to drain (timeout 120s)...${NC}"
  wait_for_metric \
    'sum(otelcol_exporter_queue_size) or vector(0)' \
    "lt" "1" 120 "Queue drained (traces + logs = 0)" || true

  # ── Check 2: export throughput spiked above baseline
  sleep 10
  echo ""
  echo -e "  ${B}→ Verifying throughput spike (queue drain burst)...${NC}"
  local peak baseline
  peak=$(prom_value \
    'max_over_time(rate(otelcol_exporter_sent_spans{exporter="otlp/jaeger"}[30s])[3m:])')
  baseline=$(prom_value \
    'avg_over_time(rate(otelcol_exporter_sent_spans{exporter="otlp/jaeger"}[2m])[10m:2m])')

  if python3 -c "exit(0 if float('${peak}') > max(float('${baseline}') * 1.5, 0.5) else 1)" \
       2>/dev/null; then
    ok "Throughput spike confirmed (peak=${peak}, baseline≈${baseline} spans/s)"
  else
    warn "Spike not conclusive (peak=${peak}, baseline≈${baseline}) — may have settled already"
  fi

  # ── Check 3: Jaeger has traces from failure window
  echo ""
  echo -e "  ${B}→ Checking Jaeger for failure-window traces...${NC}"
  local start_us=$(( FAILURE_START * 1000000 ))
  local end_us=$(( FAILURE_END * 1000000 ))
  local trace_count
  # Note: Jaeger requires service= param for time-range queries; python3 handles JSON errors.
  trace_count=$(curl -sf \
    "${JAEGER_URL}/api/traces?service=edge-demo-app&start=${start_us}&end=${end_us}&limit=10" \
    | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  print(len(d.get('data', [])))
except:
  print(0)
" 2>/dev/null) || true
  trace_count=${trace_count:-0}

  if [[ "$trace_count" -gt 0 ]]; then
    ok "Jaeger has ${trace_count} trace(s) from the failure window"
    info "Open: ${JAEGER_URL} → filter time range $(date -r "$FAILURE_START" '+%H:%M')–$(date -r "$FAILURE_END" '+%H:%M')"
  else
    warn "No traces found yet in Jaeger failure window (may need a few more seconds)"
    info "Open: ${JAEGER_URL} → set time range to 'last 30m' and look for the gap"
  fi

  # ── Dashboard summary
  echo ""
  echo -e "  ${W}What to show now:${NC}"
  echo -e ""
  echo -e "  ${G}Vessel Operations dashboard:${NC}"
  echo -e "    • Metrics: flat gap during outage, then resumes  ${Y}(gap stays — expected)${NC}"
  echo -e "    • Logs: entries from the failure window reappear with original timestamps"
  echo -e "    • Logs: click a trace_id → open in Jaeger → failure-window trace"
  echo -e ""
  echo -e "  ${G}Edge Pipeline → RESILIENCE:${NC}"
  echo -e "    • Export Throughput: spiked and settled back to baseline"
  echo -e "    • Trace Queue Depth: 0  (queue fully drained)"
  echo ""
  echo -e "  ${DIM}\"Two of three signals fully recover. Traces and logs arrive with${NC}"
  echo -e "  ${DIM}original timestamps — the gap fills. Metrics resume but the gap stays:${NC}"
  echo -e "  ${DIM}the Prometheus remote-write endpoint silently skips out-of-order${NC}"
  echo -e "  ${DIM}samples. The gap itself tells the story.\"${NC}"
}

# ── Summary ─────────────────────────────────────────────────
show_summary() {
  header "Demo Summary"
  echo ""

  if [[ ${CHECKS_FAILED} -eq 0 ]]; then
    echo -e "  ${G}${BOLD}All checks passed${NC} (${CHECKS_PASSED} total)"
  else
    echo -e "  ${Y}${CHECKS_PASSED} passed  ${R}${CHECKS_FAILED} failed${NC}"
    for c in "${FAILED_CHECKS[@]}"; do
      echo -e "    ${R}✗${NC} ${c}"
    done
  fi

  echo ""
  if [[ $FAILURE_START -gt 0 ]]; then
    echo -e "  Failure window : $(date -r "$FAILURE_START" '+%H:%M:%S') → $(date -r "$FAILURE_END" '+%H:%M:%S') (${FAILURE_DURATION}s)"
    echo -e "  Link restored  : $(date -r "$RESTORE_TIME" '+%H:%M:%S')"
    echo -e "  Queue drain    : ~$((RESTORE_TIME - FAILURE_END))s after restore"
  fi

  echo ""
  echo -e "  ${DIM}Load test still running. To stop:${NC}"
  echo -e "  ${DIM}  kubectl delete testrun ${TESTRUN_NAME} -n ${NAMESPACE}${NC}"
  echo ""
}

# ── Cleanup ─────────────────────────────────────────────────
cleanup() {
  [[ -n "$PROM_PF_PID" ]] && kill "$PROM_PF_PID" 2>/dev/null || true
}
trap 'cleanup' EXIT
trap 'cleanup; echo -e "\n${Y}Demo interrupted.${NC}"; exit 1' INT TERM

# ── Entry point ─────────────────────────────────────────────
header "Making Observability Work at the Edge"
echo -e "  ${DIM}KubeCon EU 2026 — orchestrated demo runner [env: ${DEMO_ENV}]${NC}"
echo -e "  ${DIM}Grafana: ${GRAFANA_URL}  |  Jaeger: ${JAEGER_URL}${NC}"

start_prom_pf   # must come before preflight (preflight calls prom_value)
preflight

case "$START_ACT" in
  1)
    ensure_load_test
    wait_baseline
    act1_guide
    act2_guide
    act3_failure
    act3_restore
    ;;
  2)
    ensure_load_test
    act2_guide
    act3_failure
    act3_restore
    ;;
  3)
    act3_failure
    act3_restore
    ;;
esac

show_summary
