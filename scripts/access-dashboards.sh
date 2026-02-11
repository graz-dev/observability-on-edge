#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting port-forwarding for Observability Dashboards...${NC}"

# Kill any existing port-forwards (optional, but good practice if re-running)
pkill -f "kubectl port-forward" || true

echo -e "${GREEN}Forwarding Prometheus on port 9090...${NC}"
kubectl port-forward -n monitoring-hub svc/prometheus 9090:9090 > /dev/null 2>&1 &
PID_PROM=$!

echo -e "${GREEN}Forwarding Jaeger on port 16686...${NC}"
kubectl port-forward -n monitoring-hub svc/jaeger 16686:16686 > /dev/null 2>&1 &
PID_JAEGER=$!

echo -e "${GREEN}Forwarding Grafana on port 3000...${NC}"
kubectl port-forward -n monitoring-hub svc/grafana 3000:3000 > /dev/null 2>&1 &
PID_GRAFANA=$!

echo -e "${BLUE}Dashboards are now accessible at:${NC}"
echo -e "Prometheus: http://localhost:9090"
echo -e "Jaeger:     http://localhost:16686"
echo -e "Grafana:    http://localhost:3000"
echo -e ""
echo -e "${BLUE}Press Ctrl+C to stop all forwarding.${NC}"

# Wait for user to interrupt
wait $PID_PROM $PID_JAEGER $PID_GRAFANA
