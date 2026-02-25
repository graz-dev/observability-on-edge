#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}🔌 Restoring Satellite Link...${NC}"
echo "=========================================="

EDGE_NODE="k3d-edge-observability-agent-0"

if [ ! -f /tmp/otel-collector-pod-ip ]; then
  echo -e "${RED}❌ Pod IP file not found. Run simulate-network-failure.sh first.${NC}"
  exit 1
fi

POD_IP=$(cat /tmp/otel-collector-pod-ip)

echo -e "\n${GREEN}✓ Removing iptables DROP rules for OTel Collector (${POD_IP})...${NC}"

# Remove the three FORWARD DROP rules (exact match on rule spec)
docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 4317 -j DROP 2>/dev/null || true

docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 9090 -j DROP 2>/dev/null || true

docker exec "$EDGE_NODE" iptables -D FORWARD \
  -s "$POD_IP" -p tcp --dport 3100 -j DROP 2>/dev/null || true

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
