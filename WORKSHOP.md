# Edge Observability Workshop Guide

This guide details the "Edge Observability on Kubernetes" demo, explaining the architecture, how to run it, and what key observability patterns to look for.

## 1. Overview
This demo simulates a resource-constrained **Edge Computing** environment using `k3d`. It showcases an optimized observability stack designed for edge nodes with limited CPU and Memory, ensuring critical data is captured without impacting the node's performance.

### Architecture
- **Cluster**: A 3-node K3s cluster (1 Server, 2 Agents).
  - **Server (Control Plane)**: Hosts the central monitoring hub.
  - **Agents (Edge Nodes)**: Host the lightweight collectors and applications.
- **Edge Layer (The "Agents")**:
  - **OpenTelemetry Collector (DaemonSet)**: Runs on every edge node.
    - **Resource Limits**: Hard limit of **60MiB RAM** and **0.5 CPU**.
    - **Smart Features**: Tail Sampling (only keeping interesting traces) and Persistent Queues (buffering data during outages).
  - **Fluent Bit**: Lightweight log forwarder.
  - **Noise Generator**: A demo app generating random traffic (Success, Error, Slow requests) to simulate a workload.
- **Hub Layer (The "Server")**:
  - **Prometheus**: Metrics storage.
  - **Jaeger**: Trace storage and visualization.
  - **Grafana**: Modern dashboarding (modern dashboarding).

## 2. Getting Started

### Prerequisites
- Docker
- Kubectl
- K3d

### Setup
The environment is automated. Run this once to create the cluster and deploy everything:
```bash
./scripts/setup.sh
```

### Accessing Dashboards
Because this is a local cluster, we use port-forwarding to access the UIs securely.
Run this command in a **separate terminal** and keep it running:
```bash
./scripts/access-dashboards.sh
```

You can now access:
- **Grafana (Dashboards)**: [http://localhost:3000](http://localhost:3000)
- **Jaeger (Traces)**: [http://localhost:16686](http://localhost:16686)
- **Prometheus (Metrics)**: [http://localhost:9090](http://localhost:9090)

---

## 3. Workshop Scenarios & Findings

Follow these steps to understand the value of this architecture.

### Scenario A: Resource Efficiency (The "Lean" Collector)
**Goal**: Verify that the observability stack is lightweight and respects edge constraints.

1.  Open **Grafana** ([http://localhost:3000](http://localhost:3000)).
2.  Navigate to the **Edge Node Health** dashboard.
3.  **Findings**:
    -   **Memory Usage**: Notice the OpenTelemetry Collector uses very little RAM (typically < 30-40MiB).
    -   **CPU Usage**: CPU usage should be minimal, spiking only slightly during batch processing.
    -   **Why?**: This proves that we can run full observability on small devices (like Raspberry Pis or Industrial PCs) without 'stealing' resources from the main application.

### Scenario B: Intelligent Tail Sampling (The "Smart" Collector)
**Goal**: Demonstrate that we only send valuable data to the central hub to save bandwidth and storage.

1.  Open **Jaeger** ([http://localhost:16686](http://localhost:16686)).
2.  Select Service: `noise-generator`.
3.  Click **Find Traces**.
4.  **Findings**:
    -   Look at the traces. You will see mostly **Errors** (HTTP 500) or **High Latency** (>500ms) requests.
    -   **Where are the success (HTTP 200) requests?**
        -   The `noise-generator` app produces 80% success traffic!
        -   The **OpenTelemetry Collector** is configured with `tail_sampling` to **DROP** normal, fast requests.
    -   **Why?**: On the edge, bandwidth is expensive/slow (4G/LTE/Satellite). We only care about *problems*, not "everything is fine" signals.

### Scenario C: Unreliable Network Resilience (The "Persistent" Collector)
**Goal**: Show that data is safe even if the network disconnects (a common edge problem).

1.  **Start the Outage**:
    Run this script to cut the network connection between Edge Nodes and the Hub:
    ```bash
    ./scripts/simulate-outage.sh start
    ```
2.  **Observe**:
    -   Go to **Grafana**. You might see metrics stop updating or a gap appear.
    -   Wait for about 30-60 seconds.
    -   The `noise-generator` is still running, generating data. Where is it going?
    -   It is being **buffered to disk** on the edge node inside the Collector's `persistent_queue`.
3.  **Stop the Outage**:
    Restore connectivity:
    ```bash
    ./scripts/simulate-outage.sh stop
    ```
4.  **Findings**:
    -   Go back to **Jaeger** and **Grafana**.
    -   You should see the "missing" data fill in (backfill).
    -   **Why?**: Standard collectors drop data in memory when the destination is down. Our config uses a file-based buffer to ensure **zero data loss** during connectivity issues.

### Scenario D: Edge Log Processing (The "Clean" Collector)
**Goal**: Demonstrate how Fluent Bit reduces noise and enriches data directly on the device.

1.  Open **Grafana** ([http://localhost:3000](http://localhost:3000)).
2.  Look at the **Edge Filtered Logs** panel.
3.  **Findings**:
    -   You will see logs with `status=500` or `scenario=high_latency`.
    -   **Where are the success logs?**
        -   The `noise-generator` logs *every* request, but **Fluent Bit** drops all 200 OK logs at the edge.
    -   **Enrichment**: Notice each log has an `edge_region: south-1` label, added by Fluent Bit, not the app.
    -   **Why?**: Log volumes can be massive. Filtering at the source (edge) ensures we only pay for the transit of *useful* logs.

### Scenario E: The Noise Generator
**Goal**: Understand the source of the data.

1.  The `noise-generator` is a simple Go app deployed on the edge nodes.
2.  It creates traces with random characteristics:
    -   **Fast Success**: HTTP 200, < 100ms latency.
    -   **Slow Success**: HTTP 200, > 600ms latency.
    -   **Random Error**: HTTP 500.
3.  It exports traces directly to the local OpenTelemetry Collector (DaemonSet) via HostIP.

## 4. Key Configuration Files
If you want to see *how* this is done, check these files:

- `manifests/02-otel/otel-config.yaml`: The brain of the operation. Contains `tail_sampling`, `memory_limiter`, and `persistent_queue` configurations.
- `manifests/02-otel/daemonset.yaml`: How we deploy one collector per node.
