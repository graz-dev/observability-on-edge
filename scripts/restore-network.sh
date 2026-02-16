#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🔌 Restoring Network Connectivity...${NC}"
echo "=========================================="

echo -e "\n${GREEN}✓ Restoring OTel Collector config to valid endpoints...${NC}"

# Restore the collector config to point to real services
kubectl get configmap otel-collector-config -n observability -o yaml | \
  sed 's|invalid-jaeger\.invalid:4317|jaeger\.observability\.svc\.cluster\.local:4317|g' | \
  sed 's|http://invalid-prometheus\.invalid:9090|http://prometheus\.observability\.svc\.cluster\.local:9090|g' | \
  sed 's|http://invalid-loki\.invalid:3100|http://loki\.observability\.svc\.cluster\.local:3100|g' | \
  kubectl apply -f -

echo -e "\n${YELLOW}⏳ Restarting OTel Collector to apply changes...${NC}"
kubectl rollout restart deployment otel-collector -n observability
kubectl rollout status deployment otel-collector -n observability --timeout=60s

echo -e "\n${GREEN}✓ Network connectivity restored${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  OTel Collector can now reach backends${NC}"
echo -e "${GREEN}  (endpoints configured to valid addresses)${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📊 What's happening:${NC}"
echo "  ✓ Network connectivity restored"
echo "  ✓ OTel Collector draining queued data"
echo "  ✓ Telemetry flowing to backends"
echo "  ✓ No data loss!"

echo -e "\n${YELLOW}⏳ Queue should now be draining...${NC}"
echo "  Watch the recovery in Grafana in real-time!"
echo ""
sleep 3

echo -e "\n${GREEN}✅ Network Restored!${NC}"
echo ""
echo -e "${YELLOW}💡 Verify in Grafana:${NC}"
echo "  Open: http://localhost:30300"
echo ""
echo "  Dashboard: 'Edge Observability System'"
echo "    - 'Persistent Queues' panel → Queue should decrease to 0"
echo "    - 'Network Resilience: Queue Size' → Gauge returns to green"
echo "    - 'Export Failures' → Should stop increasing"
echo ""
echo "  Dashboard: 'Application Observability'"
echo "    - Check for data continuity (no gaps)"
echo "    - All queued telemetry should now be visible"
echo ""
