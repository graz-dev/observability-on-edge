#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${RED}🧹 Cleaning Up Edge Observability Demo${NC}"
echo "=========================================="

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
echo -e "${YELLOW}💡 To redeploy:${NC}"
echo "  Run: ./scripts/setup.sh"
echo ""
