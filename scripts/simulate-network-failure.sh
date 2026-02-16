#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔌 Simulating Network Failure (config approach)...${NC}"
echo "=========================================="

echo -e "\n${RED}⚠️  Modifying OTel Collector config to use invalid endpoints...${NC}"

# Patch the collector config to point to non-existent services
kubectl get configmap otel-collector-config -n observability -o yaml | \
  sed 's|jaeger\.observability\.svc\.cluster\.local:4317|invalid-jaeger\.invalid:4317|g' | \
  sed 's|http://prometheus\.observability\.svc\.cluster\.local:9090|http://invalid-prometheus\.invalid:9090|g' | \
  sed 's|http://loki\.observability\.svc\.cluster\.local:3100|http://invalid-loki\.invalid:3100|g' | \
  kubectl apply -f -

echo -e "\n${YELLOW}⏳ Restarting OTel Collector to apply changes...${NC}"
kubectl rollout restart deployment otel-collector -n observability
kubectl rollout status deployment otel-collector -n observability --timeout=60s

echo -e "\n${GREEN}✓ Network failure simulated${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  OTel Collector CANNOT reach backends${NC}"
echo -e "${RED}  (endpoints configured to invalid addresses)${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📊 What's happening:${NC}"
echo "  ✓ Application continues to run"
echo "  ✓ OTel Collector receives telemetry"
echo "  ✗ Cannot resolve invalid backend addresses"
echo "  ✓ Data queued in persistent file storage"
echo "  ✓ Backends still running (Grafana works!)"

echo -e "\n${YELLOW}💡 Monitor the queue buildup:${NC}"
echo "  Open Grafana dashboard: http://localhost:30300"
echo "  Navigate to: 'Edge Observability System'"
echo "  Watch these panels:"
echo "    - 'Persistent Queues' - Queue size will grow"
echo "    - 'Network Resilience: Queue Size' - Gauge will increase"
echo "    - 'Export Failures' - Will show failed export attempts"
echo ""

echo -e "${YELLOW}🔄 To restore network:${NC}"
echo "  Run: ./scripts/restore-network-config.sh"
echo ""
