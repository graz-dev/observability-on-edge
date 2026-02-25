#!/bin/bash

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

NAMESPACE="observability"
TESTRUN_NAME="vessel-monitoring"

echo -e "${GREEN}⚓ Starting Maritime Vessel Monitoring Load Test${NC}"
echo "=================================================="

# Verify k6 Operator CRD is installed
if ! kubectl get crd testruns.k6.io &>/dev/null; then
  echo -e "${RED}❌ k6 Operator not installed (CRD 'testruns.k6.io' missing).${NC}"
  echo "   Run ./scripts/setup.sh first."
  exit 1
fi

# Delete existing TestRun if present (operator keeps finished runs around)
if kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" &>/dev/null; then
  echo -e "\n${YELLOW}⚠️  Existing TestRun '${TESTRUN_NAME}' found — deleting it...${NC}"
  kubectl delete testrun "${TESTRUN_NAME}" -n "${NAMESPACE}"
  # Wait for runner pods to terminate
  echo -e "${YELLOW}⏳ Waiting for runner pods to terminate...${NC}"
  kubectl wait --for=delete pod -l "k6_cr=${TESTRUN_NAME}" \
    -n "${NAMESPACE}" --timeout=60s 2>/dev/null || true
  sleep 2
fi

# Apply ConfigMap (script) and TestRun
echo -e "\n${YELLOW}📦 Applying k6 ConfigMap and TestRun...${NC}"
kubectl apply -f k8s/load-test/k6-script-configmap.yaml
kubectl apply -f k8s/load-test/testrun.yaml
echo -e "${GREEN}✓ TestRun '${TESTRUN_NAME}' created${NC}"

# Wait for the TestRun to reach 'started' stage
echo -e "\n${YELLOW}⏳ Waiting for k6 runner to start (up to 120s)...${NC}"
echo "   (operator creates initializer job → runner pod → k6 starts)"

TIMEOUT=120
START=$SECONDS
while [[ $((SECONDS - START)) -lt $TIMEOUT ]]; do
  STAGE=$(kubectl get testrun "${TESTRUN_NAME}" -n "${NAMESPACE}" \
    -o jsonpath='{.status.stage}' 2>/dev/null || echo "pending")

  case "$STAGE" in
    "started")
      echo -e "${GREEN}✓ TestRun started${NC}"
      break
      ;;
    "error")
      echo -e "${RED}❌ TestRun entered error state${NC}"
      kubectl describe testrun "${TESTRUN_NAME}" -n "${NAMESPACE}"
      exit 1
      ;;
    "finished")
      echo -e "${YELLOW}⚠️  TestRun finished immediately — check the script${NC}"
      break
      ;;
  esac

  printf "  Stage: %-20s (%ds elapsed)\r" "${STAGE}" "$((SECONDS - START))"
  sleep 5
done
printf "\n"

if [[ $((SECONDS - START)) -ge $TIMEOUT ]]; then
  echo -e "${RED}❌ TestRun did not start within ${TIMEOUT}s${NC}"
  echo "   Check: kubectl get testrun -n ${NAMESPACE}"
  echo "   Logs:  kubectl logs -n ${NAMESPACE} -l k6_cr=${TESTRUN_NAME}"
  exit 1
fi

# Show runner pod
RUNNER_POD=$(kubectl get pods -n "${NAMESPACE}" -l "k6_cr=${TESTRUN_NAME}" \
  --no-headers 2>/dev/null | head -1 | awk '{print $1}' || echo "")

echo ""
echo -e "${GREEN}✅ Load test running${NC}"
echo "   TestRun:    ${TESTRUN_NAME} (40 min, 8 VU sustained)"
echo "   Runner pod: ${RUNNER_POD:-<starting>}"
echo ""
echo -e "${YELLOW}📊 Monitor:${NC}"
echo "   kubectl get testrun ${TESTRUN_NAME} -n ${NAMESPACE}"
echo "   kubectl logs -f -n ${NAMESPACE} ${RUNNER_POD:--l k6_cr=${TESTRUN_NAME}}"
echo ""
echo -e "${YELLOW}🛑 To stop:${NC}"
echo "   kubectl delete testrun ${TESTRUN_NAME} -n ${NAMESPACE}"
echo ""
