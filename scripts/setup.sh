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
CIVO_SIZE="g4s.kube.large"   # 4 vCPU / 8 GB — comfortable for live demo
SETUP_AKAMAS=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    DEMO_ENV="$2";    shift 2;;
    --region) CIVO_REGION="$2"; shift 2;;
    --size)   CIVO_SIZE="$2";   shift 2;;
    --akamas) SETUP_AKAMAS=true; shift;;
    *) shift;;
  esac
done

if [[ "$DEMO_ENV" != "local" && "$DEMO_ENV" != "civo" ]]; then
  echo -e "${RED}❌ Unknown --env value '${DEMO_ENV}'. Use 'local' or 'civo'.${NC}"
  exit 1
fi

echo -e "${GREEN}🚀 Edge Observability Demo - Setup [env: ${DEMO_ENV}]${NC}"
echo "=========================================="

# ── Prerequisites ────────────────────────────────────────────
echo -e "\n${YELLOW}📋 Checking prerequisites...${NC}"

command -v kubectl >/dev/null 2>&1 || { echo -e "${RED}❌ kubectl is required but not installed.${NC}" >&2; exit 1; }

if [[ "$DEMO_ENV" == "local" ]]; then
  command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ docker is required but not installed.${NC}" >&2; exit 1; }
  command -v k3d >/dev/null 2>&1    || { echo -e "${RED}❌ k3d is required but not installed.${NC}" >&2; exit 1; }
else
  command -v civo >/dev/null 2>&1   || { echo -e "${RED}❌ civo CLI is required. Install: https://github.com/civo/cli${NC}" >&2; exit 1; }
  command -v docker >/dev/null 2>&1 || { echo -e "${RED}❌ docker is required (for pre-pulling images).${NC}" >&2; exit 1; }
fi

echo -e "${GREEN}✓ Prerequisites installed${NC}"

# ── Local path ───────────────────────────────────────────────
if [[ "$DEMO_ENV" == "local" ]]; then

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

  # Deploy everything via local overlay (includes namespace, hub, edge, network-chaos)
  echo -e "\n${YELLOW}☸️  Applying local overlay (hub + edge + network-chaos)...${NC}"
  kubectl apply -k overlays/local
  echo -e "${GREEN}✓ Resources applied${NC}"

  echo -e "\n${YELLOW}⏳ Waiting for hub components to be ready...${NC}"
  kubectl wait --for=condition=ready pod -l app=jaeger -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=prometheus -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=loki -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=grafana -n observability --timeout=300s
  echo -e "${GREEN}✓ Hub components ready${NC}"

  echo -e "\n${YELLOW}⏳ Waiting for edge components to be ready...${NC}"
  kubectl wait --for=condition=ready pod -l app=otel-collector -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=edge-demo-app -n observability --timeout=180s
  kubectl wait --for=condition=ready pod -l app=network-chaos -n observability --timeout=120s
  echo -e "${GREEN}✓ Edge components ready (including network-chaos)${NC}"

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

# ── Civo path ────────────────────────────────────────────────
else

  echo -e "\n${YELLOW}☸️  Creating Civo K3s cluster 'edge-observability'...${NC}"
  echo "  Region: ${CIVO_REGION}  |  Size: ${CIVO_SIZE} (4 vCPU / 8 GB)  |  Nodes: 2"

  # Delete cluster if it already exists (idempotent re-run)
  if civo kubernetes show edge-observability --region "$CIVO_REGION" &>/dev/null; then
    echo -e "${YELLOW}⚠️  Cluster 'edge-observability' already exists — deleting first...${NC}"
    civo kubernetes remove edge-observability --region "$CIVO_REGION" --yes
    echo -e "${YELLOW}   Waiting for deletion to complete...${NC}"
    sleep 15
  fi

  civo kubernetes create edge-observability \
    --nodes 2 \
    --size "$CIVO_SIZE" \
    --region "$CIVO_REGION" \
    --save --switch --wait
  echo -e "${GREEN}✓ Cluster created and kubeconfig merged${NC}"

  # Switch context
  kubectl config use-context "edge-observability" 2>/dev/null || true

  # Wait for nodes to be Ready
  # Civo marks the cluster ACTIVE before nodes register in the K8s API.
  # kubectl wait --all fails with "no matching resources" on an empty node list,
  # so first poll until at least 2 nodes appear, then wait for Ready.
  echo -e "\n${YELLOW}⏳ Waiting for nodes to register in the API...${NC}"
  for i in $(seq 1 36); do
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$node_count" -ge 2 ]]; then
      echo -e "${GREEN}✓ ${node_count} node(s) registered${NC}"
      break
    fi
    printf "  %d/2 nodes found, waiting... (%ds)\r" "$node_count" $(( i * 5 ))
    sleep 5
  done
  echo -e "\n${YELLOW}⏳ Waiting for nodes to be Ready...${NC}"
  kubectl wait --for=condition=Ready nodes --all --timeout=120s

  # Label nodes automatically (first = edge, second = hub)
  echo -e "\n${YELLOW}🏷️  Labeling nodes (first=edge, second=hub)...${NC}"
  NODES=($(kubectl get nodes --no-headers -o custom-columns=NAME:.metadata.name))

  if [ ${#NODES[@]} -lt 2 ]; then
    echo -e "${RED}❌ Expected 2 nodes, found ${#NODES[@]}${NC}"
    exit 1
  fi

  kubectl label node "${NODES[0]}" node-role=edge --overwrite
  kubectl label node "${NODES[1]}" node-role=hub --overwrite
  echo -e "${GREEN}✓ Nodes labeled${NC}"
  echo "  - ${NODES[0]} = edge"
  echo "  - ${NODES[1]} = hub"

  # Pre-pull the custom OTel Collector image (Civo nodes pull directly from ghcr.io)
  echo -e "\n${YELLOW}📦 Pre-pulling OTel Collector image...${NC}"
  ARCH=$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')
  docker pull --platform "linux/${ARCH}" ghcr.io/graz-dev/otel-collector-edge:0.1.0 2>&1 | tail -1
  echo -e "${GREEN}✓ OTel Collector image cached on Docker host${NC}"

  # Install k6 Operator
  echo -e "\n${YELLOW}📦 Installing k6 Operator...${NC}"
  kubectl apply --server-side \
    -f https://raw.githubusercontent.com/grafana/k6-operator/main/bundle.yaml
  echo -e "${GREEN}✓ k6 Operator deployed${NC}"

  # Wait for k6 Operator controller to be ready
  echo -e "\n${YELLOW}⏳ Waiting for k6 Operator controller...${NC}"
  kubectl wait --for=condition=available deployment/k6-operator-controller-manager \
    -n k6-operator-system --timeout=120s
  echo -e "${GREEN}✓ k6 Operator ready${NC}"

  # Deploy everything via Civo overlay (namespace + hub + edge + PVC + network-chaos)
  echo -e "\n${YELLOW}☸️  Applying Civo overlay (hub + edge + PVC + network-chaos)...${NC}"
  kubectl apply -k overlays/civo
  echo -e "${GREEN}✓ Resources applied${NC}"

  echo -e "\n${YELLOW}⏳ Waiting for hub components to be ready...${NC}"
  kubectl wait --for=condition=ready pod -l app=jaeger -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=prometheus -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=loki -n observability --timeout=300s
  kubectl wait --for=condition=ready pod -l app=grafana -n observability --timeout=300s
  echo -e "${GREEN}✓ Hub components ready${NC}"

  # On Civo, the otel-collector PVC uses local-path (WaitForFirstConsumer):
  # the PV is only provisioned once the pod is scheduled, then the image must
  # be pulled from ghcr.io. Allow 600s total for this sequence.
  echo -e "\n${YELLOW}⏳ Waiting for otelcol PVC to be bound...${NC}"
  for i in $(seq 1 24); do
    pvc_phase=$(kubectl get pvc otelcol-file-storage -n observability \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$pvc_phase" == "Bound" ]]; then
      echo -e "${GREEN}✓ PVC bound${NC}"
      break
    fi
    printf "  PVC phase: %s (%ds)\r" "${pvc_phase:-Pending}" $(( i * 5 ))
    sleep 5
  done

  echo -e "\n${YELLOW}⏳ Waiting for edge components to be ready...${NC}"
  kubectl wait --for=condition=ready pod -l app=otel-collector -n observability --timeout=600s
  kubectl wait --for=condition=ready pod -l app=edge-demo-app -n observability --timeout=180s
  kubectl wait --for=condition=ready pod -l app=network-chaos -n observability --timeout=120s
  echo -e "${GREEN}✓ Edge components ready (including network-chaos)${NC}"

  # Wait for LoadBalancer IPs (Civo assigns them within ~60s)
  echo -e "\n${YELLOW}⏳ Waiting for LoadBalancer IPs (Grafana + Jaeger)...${NC}"
  GRAFANA_LB=""
  JAEGER_LB=""
  for i in $(seq 1 30); do
    GRAFANA_LB=$(kubectl get svc grafana -n observability \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    JAEGER_LB=$(kubectl get svc jaeger -n observability \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -n "$GRAFANA_LB" && -n "$JAEGER_LB" ]]; then
      echo -e "\n${GREEN}✓ LoadBalancer IPs assigned${NC}"
      break
    fi
    printf "  Waiting... (%ds)\r" $(( i * 10 ))
    sleep 10
  done

  if [[ -z "$GRAFANA_LB" || -z "$JAEGER_LB" ]]; then
    echo -e "${YELLOW}⚠️  LoadBalancer IPs not yet assigned. Check with:${NC}"
    echo "    kubectl get svc -n observability"
  fi

  # Display access information
  echo -e "\n${GREEN}✅ Setup Complete!${NC}"
  echo "=========================================="
  echo -e "\n${YELLOW}📊 Access URLs:${NC}"
  if [[ -n "$GRAFANA_LB" ]]; then
    echo "  - Grafana:     http://${GRAFANA_LB}:3000"
  else
    echo "  - Grafana:     (LB IP pending — kubectl get svc grafana -n observability)"
  fi
  echo "    Username: admin"
  echo "    Password: admin"
  echo ""
  if [[ -n "$JAEGER_LB" ]]; then
    echo "  - Jaeger:      http://${JAEGER_LB}:16686"
  else
    echo "  - Jaeger:      (LB IP pending — kubectl get svc jaeger -n observability)"
  fi
  echo ""
  echo ""

  # ── Optional: Akamas optimisation runner ────────────────────────────────
  if [[ "$SETUP_AKAMAS" == "true" ]]; then
    echo -e "\n${YELLOW}🔬 Setting up Akamas optimisation runner...${NC}"

    # Expose Prometheus as LoadBalancer so the Akamas server (EKS) can scrape it.
    # Applied here and not in the base Civo overlay to avoid a public endpoint
    # during normal demo runs.
    echo -e "\n${YELLOW}📡 Exposing Prometheus via LoadBalancer (Akamas telemetry)...${NC}"
    kubectl apply -f overlays/civo/patches/prometheus-lb.yaml
    echo -e "${GREEN}✓ Prometheus LoadBalancer service applied${NC}"

    # Generate SSH key pair if not already present
    KEY_FILE="akamas-runner-key"
    if [[ ! -f "$KEY_FILE" ]]; then
      ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "akamas-runner"
      echo -e "${GREEN}✓ SSH key pair generated: ${KEY_FILE} / ${KEY_FILE}.pub${NC}"
    else
      echo -e "${YELLOW}⚠️  Using existing SSH key: ${KEY_FILE}${NC}"
    fi

    # Create / update the SSH public-key Secret in the cluster
    kubectl create secret generic akamas-runner-pubkey \
      -n observability \
      --from-file=authorized_keys="${KEY_FILE}.pub" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo -e "${GREEN}✓ SSH public key stored in Secret 'akamas-runner-pubkey'${NC}"

    # Deploy runner RBAC, Deployment, Service, and ConfigMaps
    kubectl apply -f akamas/k8s/runner-rbac.yaml
    kubectl apply -f akamas/k8s/runner-scripts-configmap.yaml
    kubectl apply -f akamas/k8s/runner-deployment.yaml
    kubectl apply -f akamas/k8s/k6-optimization-configmap.yaml
    echo -e "${GREEN}✓ Akamas runner resources deployed${NC}"

    # Wait for the runner pod to be ready
    echo -e "\n${YELLOW}⏳ Waiting for akamas-runner pod...${NC}"
    kubectl wait --for=condition=ready pod \
      -l app=akamas-runner -n observability --timeout=180s
    echo -e "${GREEN}✓ Runner pod ready${NC}"

    # Retrieve LoadBalancer IPs for Prometheus and the runner
    echo -e "\n${YELLOW}⏳ Waiting for Prometheus and akamas-runner LoadBalancer IPs...${NC}"
    PROMETHEUS_LB=""
    RUNNER_LB=""
    for i in $(seq 1 18); do
      PROMETHEUS_LB=$(kubectl get svc prometheus -n observability \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      RUNNER_LB=$(kubectl get svc akamas-runner -n observability \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
      [[ -n "$PROMETHEUS_LB" && -n "$RUNNER_LB" ]] && break
      printf "  Waiting... (%ds)\r" $(( i * 10 ))
      sleep 10
    done

    # Inject Grafana collector footprint dashboard
    echo -e "\n${YELLOW}📊 Injecting collector footprint dashboard into Grafana...${NC}"
    kubectl patch configmap grafana-dashboards -n observability \
      --type=merge \
      -p "$(python3 -c "
import json, sys
with open('akamas/k8s/grafana-collector-dashboard.json') as f:
    dash = f.read()
print(json.dumps({'data': {'otelcol-footprint.json': dash}}))
")"
    echo -e "${GREEN}✓ Dashboard ConfigMap patched${NC}"

    # Restart Grafana so it picks up the new dashboard immediately.
    # (ConfigMap mounts update eventually via kubelet, but a rollout restart
    # is faster and ensures verify-setup.sh finds the dashboard on first run.)
    echo -e "\n${YELLOW}🔄 Restarting Grafana to load the new dashboard...${NC}"
    kubectl rollout restart deployment/grafana -n observability
    kubectl rollout status deployment/grafana -n observability --timeout=90s
    echo -e "${GREEN}✓ Grafana restarted — dashboard 'OTel Collector — Footprint & Go Runtime' loaded${NC}"

    echo -e "\n${GREEN}✅ Akamas Setup Complete!${NC}"
    echo "────────────────────────────────────────────"
    echo -e "${YELLOW}Next steps to activate the study:${NC}"
    echo ""
    echo "  1. Copy the private key to the Akamas server:"
    echo "       scp ${KEY_FILE} <akamas-server>:/opt/akamas/keys/akamas-runner-key"
    echo ""
    echo "  2. Fill in the two placeholder IPs in the Akamas config files:"
    echo "       Prometheus LB IP   → akamas/telemetry-instance.yaml"
    if [[ -n "$PROMETHEUS_LB" ]]; then
      echo "         value: ${PROMETHEUS_LB}"
    fi
    echo "       Runner LB IP       → akamas/workflow.yaml (both Executor tasks)"
    if [[ -n "$RUNNER_LB" ]]; then
      echo "         value: ${RUNNER_LB}"
    fi
    echo ""
    echo "  3. Install the optimization pack and create study resources on Akamas:"
    echo "       akamas build optimization-pack akamas/optimization-pack/"
    echo "       akamas install optimization-pack descriptor.json"
    echo "       akamas create system                   --file akamas/system.yaml"
    echo "       akamas create component                --file akamas/component.yaml  \\"
    echo "                                              --system edge-observability-stack"
    echo "       akamas create telemetry-instance       --file akamas/telemetry-instance.yaml"
    echo "       akamas create workflow                 --file akamas/workflow.yaml"
    echo "       akamas create study                    --file akamas/study.yaml"
    echo ""
    echo "  4. Open Grafana → 'OTel Collector — Footprint & Go Runtime' to verify baseline"
    if [[ -n "$GRAFANA_LB" ]]; then
      echo "       http://${GRAFANA_LB}:3000"
    fi
    echo ""
    echo "  5. Verify the full setup end-to-end:"
    echo "       ./akamas/scripts/verify-setup.sh"
    echo "       (auto-detects IPs; add --key path/to/akamas-runner-key if the key is not in the current dir)"
    echo ""
    echo "  ⚠️  Run the Akamas study SEPARATELY from the demo (the study restarts"
    echo "      the collector every ~7 min and would disrupt a live demonstration)."
    echo ""
  fi

fi

echo -e "\n${YELLOW}🔍 Cluster Status:${NC}"
kubectl get nodes -o wide
echo ""
kubectl get pods -n observability -o wide

echo -e "\n${YELLOW}📝 Next Steps:${NC}"
echo "  1. Start load test (k6 Operator):  ./scripts/load-generator.sh"
echo "  2. Run the orchestrated demo:       ./scripts/demo.sh --env ${DEMO_ENV}"
echo "     (or manually: simulate → restore)"
echo "  3. Simulate network failure:        ./scripts/simulate-network-failure.sh"
echo "  4. Restore network:                 ./scripts/restore-network.sh"
echo ""
