#!/bin/bash

# Configuration
CLUSTER_NAME="edge-observability-demo"
SERVER_CONTAINER="k3d-${CLUSTER_NAME}-server-0"
AGENT_CONTAINERS=$(docker ps --format "{{.Names}}" | grep "k3d-${CLUSTER_NAME}-agent")

# Function to get Server IP
function get_server_ip() {
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $SERVER_CONTAINER
}

# Function to get Hub IPs
function get_hub_ips() {
    kubectl get svc -n monitoring-hub -o jsonpath='{.items[*].spec.clusterIP}'
    kubectl get pods -n monitoring-hub -o jsonpath='{.items[*].status.podIP}'
}

SERVER_IP=$(get_server_ip)
HUB_IPS=$(get_hub_ips)

function start_outage() {
    echo "🔌 Simulating Network Blackout on ALL Nodes..."
    for node in $SERVER_CONTAINER $AGENT_CONTAINERS; do
        echo "   -> Cutting connection on $node to Hub ($HUB_IPS) and Server ($SERVER_IP)..."
        # Block Server Host IP
        docker exec --privileged $node sh -c "iptables -I OUTPUT -d $SERVER_IP -j DROP" 2>/dev/null
        docker exec --privileged $node sh -c "iptables -I FORWARD -d $SERVER_IP -j DROP" 2>/dev/null
        # Block ClusterIPs and PodIPs of Monitoring Hub
        for ip in $HUB_IPS; do
            docker exec --privileged $node sh -c "iptables -I OUTPUT -d $ip -j DROP" 2>/dev/null
            docker exec --privileged $node sh -c "iptables -I FORWARD -d $ip -j DROP" 2>/dev/null
        done
    done
    echo "⚠️  Blackout Active! Check queues filling up."
}

function stop_outage() {
    echo "📡 Restoring Network Connection..."
    for node in $SERVER_CONTAINER $AGENT_CONTAINERS; do
        echo "   -> Cleaning ALL drop rules on $node..."
        # Robustly delete all DROP rules to the Hub/Server
        docker exec --privileged $node sh -c "iptables -S OUTPUT | grep DROP | sed 's/-A/-D/' | while read line; do iptables \$line 2>/dev/null; done"
        docker exec --privileged $node sh -c "iptables -S FORWARD | grep DROP | sed 's/-A/-D/' | while read line; do iptables \$line 2>/dev/null; done"
    done
    echo "✅ Connectivity Restored! Watch the queues drain."
}

# Interface
if [ "$1" == "start" ]; then
    start_outage
elif [ "$1" == "stop" ]; then
    stop_outage
else
    echo "Usage: $0 [start|stop]"
    exit 1
fi
