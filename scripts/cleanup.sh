#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ── Arg parsing ─────────────────────────────────────────────
DEMO_ENV="local"
CIVO_REGION="LON1"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    DEMO_ENV="$2";    shift 2;;
    --region) CIVO_REGION="$2"; shift 2;;
    *) shift;;
  esac
done

if [[ "$DEMO_ENV" != "local" && "$DEMO_ENV" != "civo" ]]; then
  echo -e "${RED}❌ Unknown --env value '${DEMO_ENV}'. Use 'local' or 'civo'.${NC}"
  exit 1
fi

echo -e "${RED}🧹 Cleaning Up Edge Observability Demo [env: ${DEMO_ENV}]${NC}"
echo "=========================================="

# ── Local path ───────────────────────────────────────────────
if [[ "$DEMO_ENV" == "local" ]]; then
  echo -e "\n${YELLOW}⚠️  This will delete:${NC}"
  echo "  - k3d cluster 'edge-observability'"
  echo "  - All deployed resources"
  echo "  - All data (metrics, logs, traces)"
  echo ""

  read -p "Are you sure? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cleanup cancelled${NC}"
    exit 0
  fi

  echo -e "\n${YELLOW}🗑️  Deleting k3d cluster...${NC}"
  k3d cluster delete edge-observability
  echo -e "\n${GREEN}✅ Cleanup complete${NC}"
  echo ""
  echo -e "${YELLOW}💡 To redeploy: ./scripts/setup.sh${NC}"
  echo ""

# ── Civo path ────────────────────────────────────────────────
else
  command -v civo >/dev/null 2>&1 || { echo -e "${RED}❌ civo CLI is required. Install: https://github.com/civo/cli${NC}" >&2; exit 1; }

  echo -e "\n${YELLOW}⚠️  This will delete:${NC}"
  echo "  - Civo Kubernetes cluster 'edge-observability' (region: ${CIVO_REGION})"
  echo "  - All LoadBalancers, PVCs, and deployed resources"
  echo "  - All data (metrics, logs, traces)"
  echo ""

  read -p "Delete cluster 'edge-observability'? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Cleanup cancelled${NC}"
    exit 0
  fi

  # Check the cluster exists before trying to delete
  if ! civo kubernetes show edge-observability --region "$CIVO_REGION" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Cluster 'edge-observability' not found in region ${CIVO_REGION} — nothing to delete${NC}"
    exit 0
  fi

  echo -e "\n${YELLOW}🗑️  Deleting Civo cluster 'edge-observability' (region: ${CIVO_REGION})...${NC}"
  echo "  (This also removes all LoadBalancers and PVCs automatically)"
  civo kubernetes remove edge-observability --region "$CIVO_REGION" --yes
  echo -e "${GREEN}✓ Cluster deleted${NC}"

  # Clean up kubeconfig
  if kubectl config get-contexts edge-observability &>/dev/null 2>&1; then
    kubectl config delete-context edge-observability 2>/dev/null || true
    echo -e "${GREEN}✓ kubeconfig context removed${NC}"
  fi

  echo -e "\n${GREEN}✅ Cleanup complete${NC}"
  echo ""
  echo -e "${YELLOW}💡 To redeploy: ./scripts/setup.sh --env civo [--region ${CIVO_REGION}]${NC}"
  echo ""
fi
