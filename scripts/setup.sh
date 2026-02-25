#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}🚀 Edge Observability Demo - Setup${NC}"
echo "=========================================="

# Check prerequisites
echo -e "\n${YELLOW}📋 Checking prerequisites...${NC}"

command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ docker is required but not installed.${NC}" >&2; exit 1; }
command -v k3d >/dev/null 2>&1 || { echo -e "${RED}❌ k3d is required but not installed.${NC}" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}❌ kubectl is required but not installed.${NC}" >&2; exit 1; }

echo -e "${GREEN}✓ All prerequisites installed${NC}"

# Build application Docker image
echo -e "\n${YELLOW}🏗️  Building application Docker image...${NC}"
cd app
docker build -t edge-demo-app:latest .
cd ..
echo -e "${GREEN}✓ Application image built${NC}"

# Create k3d cluster with 2 nodes
echo -e "\n${YELLOW}☸️  Creating k3d cluster with 2 nodes...${NC}"

# Delete cluster if it exists
k3d cluster delete edge-observability 2>/dev/null || true

# Create cluster with 2 agents (worker nodes)
k3d cluster create edge-observability \
  --agents 2 \
  --port "30300:30300@server:0" \
  --port "30686:30686@server:0" \
  --wait

echo -e "${GREEN}✓ Cluster created${NC}"

# Wait for cluster to be ready
echo -e "\n${YELLOW}⏳ Waiting for cluster to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=120s

# Label nodes
echo -e "\n${YELLOW}🏷️  Labeling nodes...${NC}"
NODES=($(kubectl get nodes -o name | grep agent))

if [ ${#NODES[@]} -lt 2 ]; then
  echo -e "${RED}❌ Expected 2 agent nodes, found ${#NODES[@]}${NC}"
  exit 1
fi

kubectl label ${NODES[0]} node-role=edge --overwrite
kubectl label ${NODES[1]} node-role=hub --overwrite

echo -e "${GREEN}✓ Nodes labeled${NC}"
echo "  - ${NODES[0]} = edge"
echo "  - ${NODES[1]} = hub"

# Import application image to k3d
echo -e "\n${YELLOW}📦 Importing application image to k3d...${NC}"
k3d image import edge-demo-app:latest -c edge-observability
echo -e "${GREEN}✓ Image imported${NC}"

# Pre-pull the custom OTel Collector image on the Docker host so it is cached locally.
# k3d image import fails for ghcr.io multi-arch images with BuildKit attestation
# manifests (containerd cannot validate missing platform blobs). The pod will pull
# directly from ghcr.io instead — the image is ~30 MB so this is fast enough.
echo -e "\n${YELLOW}📦 Pre-pulling OTel Collector image (will pull from ghcr.io at pod start)...${NC}"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
docker pull --platform "linux/${ARCH}" ghcr.io/graz-dev/otel-collector-edge:0.1.0 2>&1 | tail -1
echo -e "${GREEN}✓ OTel Collector image cached on Docker host${NC}"

# Create namespace
echo -e "\n${YELLOW}📁 Creating namespace...${NC}"
kubectl apply -f k8s/namespace.yaml
echo -e "${GREEN}✓ Namespace created${NC}"

# Install k6 Operator
echo -e "\n${YELLOW}📦 Installing k6 Operator...${NC}"
kubectl apply --server-side \
  -f https://raw.githubusercontent.com/grafana/k6-operator/main/bundle.yaml
echo -e "${GREEN}✓ k6 Operator deployed${NC}"

# Pre-import k6 runner image so the TestRun pod starts without pulling from internet.
# grafana/k6 is a multi-arch manifest — k3d's containerd cannot import multi-arch manifests
# directly. Pull the platform-specific image first so Docker resolves to a single digest.
echo -e "\n${YELLOW}📦 Importing k6 runner image into cluster...${NC}"
ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
docker pull --platform "linux/${ARCH}" grafana/k6:latest 2>&1 | tail -1
if k3d image import grafana/k6:latest -c edge-observability 2>/dev/null; then
  echo -e "${GREEN}✓ k6 runner image pre-loaded into cluster${NC}"
else
  echo -e "${YELLOW}⚠  k6 image import skipped (containerd digest issue) — runner pod will pull from Docker Hub${NC}"
fi

# Wait for k6 Operator controller to be ready
echo -e "\n${YELLOW}⏳ Waiting for k6 Operator controller...${NC}"
kubectl wait --for=condition=available deployment/k6-operator-controller-manager \
  -n k6-operator-system --timeout=120s
echo -e "${GREEN}✓ k6 Operator ready${NC}"

# Apply k6 script ConfigMap (TestRun is created separately via load-generator.sh)
kubectl apply -f k8s/load-test/k6-script-configmap.yaml
echo -e "${GREEN}✓ k6 script ConfigMap applied${NC}"

# Deploy hub node components first (backends)
echo -e "\n${YELLOW}🎯 Deploying hub node components (backends)...${NC}"
kubectl apply -f k8s/hub-node/

echo -e "${YELLOW}⏳ Waiting for hub components to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=jaeger -n observability --timeout=300s
kubectl wait --for=condition=ready pod -l app=prometheus -n observability --timeout=300s
kubectl wait --for=condition=ready pod -l app=loki -n observability --timeout=300s
kubectl wait --for=condition=ready pod -l app=grafana -n observability --timeout=300s

echo -e "${GREEN}✓ Hub components ready${NC}"

# Deploy edge node components
echo -e "\n${YELLOW}⚡ Deploying edge node components...${NC}"
kubectl apply -f k8s/edge-node/

echo -e "${YELLOW}⏳ Waiting for edge components to be ready...${NC}"
kubectl wait --for=condition=ready pod -l app=otel-collector -n observability --timeout=300s
kubectl wait --for=condition=ready pod -l app=edge-demo-app -n observability --timeout=180s

echo -e "${GREEN}✓ Edge components ready${NC}"

# Display cluster information
echo -e "\n${GREEN}✅ Setup Complete!${NC}"
echo "=========================================="
echo -e "\n${YELLOW}📊 Access URLs:${NC}"
echo "  - Grafana:     http://localhost:30300"
echo "    Username: admin"
echo "    Password: admin"
echo ""
echo "  - Jaeger:      http://localhost:30686"
echo ""
echo "  To access Prometheus (port-forward required):"
echo "    kubectl port-forward -n observability svc/prometheus 9090:9090"
echo "    Then open: http://localhost:9090"
echo ""

echo -e "\n${YELLOW}🔍 Cluster Status:${NC}"
kubectl get nodes -o wide
echo ""
kubectl get pods -n observability -o wide

echo -e "\n${YELLOW}📝 Next Steps:${NC}"
echo "  1. Start load test (k6 Operator):  ./scripts/load-generator.sh"
echo "  2. Run the orchestrated demo:       ./scripts/demo.sh"
echo "     (or manually: simulate → restore)"
echo "  3. Simulate network failure:        ./scripts/simulate-network-failure.sh"
echo "  4. Restore network:                 ./scripts/restore-network.sh"
echo ""
