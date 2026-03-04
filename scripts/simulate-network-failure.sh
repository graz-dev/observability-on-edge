#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}🔌 Simulating Satellite Link Loss...${NC}"
echo "=========================================="

# Get the network-chaos pod (privileged, hostNetwork — iptables commands affect the node directly)
CHAOS_POD=$(kubectl get pod -n testing -l app=network-chaos \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$CHAOS_POD" ]; then
  echo -e "${RED}❌ network-chaos pod not found. Is the demo running?${NC}"
  exit 1
fi

# Get the OTel Collector pod IP (traffic blocking is per-source-IP so we only
# affect the collector, not kubelet or Prometheus scraping from the hub)
POD_IP=$(kubectl get pod -n edge-obs -l app=otel-collector \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null)

if [ -z "$POD_IP" ]; then
  echo -e "${RED}❌ OTel Collector pod not found. Is the demo running?${NC}"
  exit 1
fi

# Save pod IP so restore-network.sh can reference the same rules
echo "$POD_IP" > /tmp/otel-collector-pod-ip

echo -e "\n${RED}⚠️  Blocking OTel Collector (${POD_IP}) → hub backends...${NC}"

# Helper: insert a DROP rule via BOTH iptables backends.
# k3d/k3s may use iptables-nft OR iptables-legacy depending on host kernel.
# Applying to both guarantees the rule is evaluated regardless of which
# backend the kernel's netfilter uses for the FORWARD chain.
_drop() {
  local dport="$1"
  kubectl exec -n testing "$CHAOS_POD" -- sh -c \
    "iptables        -I FORWARD -s ${POD_IP} -p tcp --dport ${dport} -j DROP 2>/dev/null || true
     iptables-legacy -I FORWARD -s ${POD_IP} -p tcp --dport ${dport} -j DROP 2>/dev/null || true"
}

_drop 4317   # Jaeger OTLP gRPC
_drop 9090   # Prometheus remote-write
_drop 3100   # Loki push

# Flush conntrack entries for the collector so that already-ESTABLISHED gRPC
# connections are not kept alive through the conntrack ESTABLISHED bypass.
# Without this, in-flight long-lived connections survive the DROP rule.
# Redirect stdout: conntrack -D prints each deleted entry, which is noisy.
kubectl exec -n testing "$CHAOS_POD" -- \
  conntrack -D -s "$POD_IP" >/dev/null 2>&1 || true

echo -e "\n${GREEN}✓ Network failure simulated (NO pod restart — collector keeps running)${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  Collector CANNOT reach: Jaeger / Prometheus / Loki${NC}"
echo -e "${RED}  All three backends are unreachable from edge${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${YELLOW}📊 What is happening right now:${NC}"
echo "  ✓ Application (vessel sensors) continues running normally"
echo "  ✓ OTel Collector receives all telemetry from the app"
echo "  ✓ Fluent Bit still forwards logs to the OTel Collector"
echo "  ✗ OTel Collector cannot export to Jaeger (TCP blocked)"
echo "  ✗ OTel Collector cannot export to Prometheus (TCP blocked)"
echo "  ✗ OTel Collector cannot export to Loki (TCP blocked)"
echo "  ✓ Data queues to disk at /var/lib/otelcol/file_storage"
echo "  ✓ Grafana and Jaeger still accessible (on hub node, unaffected)"

echo -e "\n${YELLOW}👀 Open Grafana → 'Edge Pipeline' dashboard → RESILIENCE section:${NC}"
echo "  - 'Export Throughput' drops to zero (traces and logs)"
echo "  - 'Trace Queue Depth' rises (batches accumulating on disk)"
echo "  - Let it run for 90+ seconds for a visible queue drain spike on restore"

echo -e "\n${YELLOW}🔄 When ready to restore:${NC}"
echo "  ./scripts/restore-network.sh"
echo ""
