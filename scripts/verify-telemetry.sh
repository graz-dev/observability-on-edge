#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}🔍 Verifying Telemetry Data Flow${NC}"
echo "========================================"

# Generate some traffic
echo -e "\n${YELLOW}1. Generating test traffic...${NC}"
for i in {1..5}; do
  kubectl exec -n observability deployment/edge-demo-app -- wget -qO- http://localhost:8080/api/users >/dev/null 2>&1
  kubectl exec -n observability deployment/edge-demo-app -- wget -qO- http://localhost:8080/api/checkout >/dev/null 2>&1
done
echo -e "${GREEN}✓ Traffic generated${NC}"

sleep 15

# Check Prometheus
echo -e "\n${YELLOW}2. Checking Prometheus metrics...${NC}"
METRIC_COUNT=$(kubectl exec -n observability deployment/prometheus -- wget -qO- 'http://localhost:9090/api/v1/label/__name__/values' 2>/dev/null | grep -c "http_server" || echo "0")
if [ "$METRIC_COUNT" -gt 0 ]; then
  echo -e "${GREEN}✓ Found $METRIC_COUNT http_server metrics${NC}"
else
  echo -e "${RED}✗ No http_server metrics found${NC}"
fi

# Check Jaeger
echo -e "\n${YELLOW}3. Checking Jaeger traces...${NC}"
SERVICES=$(kubectl exec -n observability deployment/jaeger -- wget -qO- 'http://localhost:16686/api/services' 2>/dev/null)
if echo "$SERVICES" | grep -q "edge-demo-app"; then
  echo -e "${GREEN}✓ Traces found for edge-demo-app${NC}"
else
  echo -e "${RED}✗ No traces found${NC}"
fi

# Check Loki
echo -e "\n${YELLOW}4. Checking Loki logs...${NC}"
LABELS=$(kubectl exec -n observability deployment/loki -- wget -qO- 'http://localhost:3100/loki/api/v1/labels' 2>/dev/null)
if echo "$LABELS" | grep -q "namespace"; then
  echo -e "${GREEN}✓ Logs found in Loki${NC}"
else
  echo -e "${RED}✗ No logs found${NC}"
fi

echo -e "\n${YELLOW}5. Component Status:${NC}"
kubectl get pods -n observability | grep -E "NAME|edge-demo|otel|fluent|jaeger|prometheus|loki|grafana"

echo -e "\n${GREEN}✅ Verification Complete${NC}"
echo ""
echo "Access Grafana: http://localhost:30300 (admin/admin)"
echo ""
