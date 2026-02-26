#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔌 Restoring Satellite Link...${NC}"
echo "=========================================="

# Get the network-chaos pod (privileged, hostNetwork — iptables commands affect the node directly)
CHAOS_POD=$(kubectl get pod -n observability -l app=network-chaos \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$CHAOS_POD" ]; then
  echo -e "${RED}❌ network-chaos pod not found. Is the demo running?${NC}"
  exit 1
fi

if [ ! -f /tmp/otel-collector-pod-ip ]; then
  echo -e "${RED}❌ Pod IP file not found. Run simulate-network-failure.sh first.${NC}"
  exit 1
fi

POD_IP=$(cat /tmp/otel-collector-pod-ip)

echo -e "\n${GREEN}✓ Removing iptables DROP rules for OTel Collector (${POD_IP})...${NC}"

# Helper: remove DROP rule from BOTH iptables backends (mirrors the dual-insert in simulate).
_undrop() {
  local dport="$1"
  kubectl exec -n observability "$CHAOS_POD" -- sh -c \
    "iptables        -D FORWARD -s ${POD_IP} -p tcp --dport ${dport} -j DROP 2>/dev/null || true
     iptables-legacy -D FORWARD -s ${POD_IP} -p tcp --dport ${dport} -j DROP 2>/dev/null || true"
}

_undrop 4317   # Jaeger OTLP gRPC
_undrop 9090   # Prometheus remote-write
_undrop 3100   # Loki push

rm -f /tmp/otel-collector-pod-ip

echo -e "\n${GREEN}✓ Link restored — OTel Collector can reach all backends again${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  OTel Collector draining file-backed queues now${NC}"
echo -e "${GREEN}  Expect a burst of data flowing to all three backends${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📊 What is happening right now:${NC}"
echo "  ✓ OTel Collector detects backends are reachable again"
echo "  ✓ File-backed queues draining: traces → Jaeger"
echo "  ✓ File-backed queues draining: logs → Loki"
echo "  ✓ File-backed queues draining: metrics → Prometheus"
echo "  ✓ Grafana gaps fill in (out-of-order ingestion enabled)"

echo -e "\n${YELLOW}👀 Open Grafana → 'Edge Pipeline' dashboard → RESILIENCE section:${NC}"
echo "  - 'Export Throughput': spike above baseline (queue drain burst), then settles"
echo "  - 'Trace Queue Depth': drops back to 0 (queue fully drained)"

echo -e "\n${YELLOW}👀 Open Grafana → 'Vessel Operations' dashboard (time range: last 30m):${NC}"
echo "  - Logs: entries from the failure window reappear with original timestamps"
echo "  - Metrics: flat gap during outage, then resumes  (gap stays — expected)"

echo -e "\n${YELLOW}👀 Open Jaeger:${NC}"
echo "  - Traces from the failure window appear with original timestamps"
echo "  - Logs in Grafana: click a trace_id to jump to the corresponding Jaeger trace"
echo ""
