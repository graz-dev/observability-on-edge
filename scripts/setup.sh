#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting Ultra-Optimized Edge Observability Demo Setup...${NC}"

# 1. Create K3d Cluster
echo -e "${GREEN}Creating K3d Cluster...${NC}"
k3d cluster create --config .k3d/config.yaml --agents-memory 512m

# 1.1 Apply CPU limits to Edge Nodes (Workaround)
echo -e "${GREEN}Applying CPU limits to Edge Nodes...${NC}"
# Wait for the cluster to fully register so nodes are reachable by name
sleep 5
for node in $(docker ps --format "{{.Names}}" | grep "k3d-edge-observability-demo-agent"); do
  docker update --cpus 0.5 $node
done

# 2. Wait for cluster to be ready
echo -e "${GREEN}Waiting for cluster to be ready...${NC}"
kubectl wait --for=condition=Ready nodes --all --timeout=60s

# 3. Create Namespaces
echo -e "${GREEN}Creating Namespaces...${NC}"
kubectl create namespace monitoring-hub --dry-run=client -o yaml | kubectl apply -f -

# 4. Deploy Observability Stack (Hub)
echo -e "${GREEN}Deploying Monitoring Hub (Prometheus, Jaeger, Grafana)...${NC}"
kubectl apply -f manifests/01-infra/

# 5. Deploy Edge Collector (OTel & Fluent Bit)
echo -e "${GREEN}Deploying Edge Collectors...${NC}"
kubectl apply -f manifests/02-otel/

# 6. Build & Deploy Demo Application
echo -e "${GREEN}Building Noise Generator App...${NC}"
docker build -t noise-generator:latest src/

echo -e "${GREEN}Importing image to K3d cluster...${NC}"
k3d image import noise-generator:latest -c edge-observability-demo

echo -e "${GREEN}Deploying Noise Generator App...${NC}"
kubectl apply -f manifests/03-app/

# 7. Wait for everything
echo -e "${GREEN}Waiting for pods to be ready...${NC}"
kubectl wait --for=condition=ready pod --all --all-namespaces --timeout=300s

echo -e "${BLUE}Setup Complete!${NC}"
echo -e "${BLUE}To access the dashboards, run the following command in a separate terminal:${NC}"
echo -e "./scripts/access-dashboards.sh"
