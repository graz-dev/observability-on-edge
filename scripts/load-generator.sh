#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}⚓ Starting Maritime Vessel Monitoring Simulation${NC}"
echo "=========================================="

# Check if k6 is installed
if ! command -v k6 &> /dev/null; then
    echo -e "${RED}❌ k6 is not installed${NC}"
    echo ""
    echo -e "${YELLOW}Install k6:${NC}"
    echo "  macOS:   brew install k6"
    echo "  Linux:   https://k6.io/docs/getting-started/installation/"
    echo "  Windows: choco install k6"
    echo ""
    echo -e "${YELLOW}Alternative: Run load test in Docker${NC}"
    echo '  docker run --rm -i --network=host grafana/k6 run - <load-tests/k6-script.js'
    exit 1
fi

# Port-forward to application (in background)
echo -e "\n${YELLOW}🔌 Setting up port-forward to application...${NC}"
kubectl port-forward -n observability svc/edge-demo-app 8080:8080 >/dev/null 2>&1 &
PF_PID=$!

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🧹 Cleaning up...${NC}"
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

# Wait for port-forward to be ready
sleep 3

echo -e "${GREEN}✓ Port-forward established${NC}"

# Run k6 load test
echo -e "\n${YELLOW}🚀 Simulating vessel sensor monitoring...${NC}"
echo "  Duration: ~6 minutes"
echo "  Patterns:"
echo "    - Continuous engine & navigation sensor reads (fast)"
echo "    - Periodic diagnostic analysis (slow)"
echo "    - Occasional system alerts (error-prone)"
echo ""

BASE_URL="http://localhost:8080" k6 run load-tests/k6-script.js

echo -e "\n${GREEN}✅ Load test completed${NC}"
echo ""
echo -e "${YELLOW}📊 Check results in Grafana:${NC}"
echo "  - Application Observability dashboard"
echo "  - Monitoring System Health dashboard"
echo ""
