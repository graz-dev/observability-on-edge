# Observability on the Edge

**KubeCon EU 2026 — "Making Observability Work at the Edge"**

A production-realistic demonstration of a complete observability pipeline for constrained edge environments: tail-based sampling, file-backed persistent queues, unified signal correlation, and automatic gap-fill after link restoration. Runs on a local k3d cluster or Civo managed Kubernetes with no code changes.

---

## Table of Contents

1. [What This Demonstrates](#1-what-this-demonstrates)
2. [Architecture Overview](#2-architecture-overview)
3. [Key Concepts](#3-key-concepts)
   - 3.1 [Tail-Based Sampling](#31-tail-based-sampling)
   - 3.2 [File-Backed Persistent Queues](#32-file-backed-persistent-queues)
   - 3.3 [Signal Correlation: Traces, Logs, and Metrics](#33-signal-correlation-traces-logs-and-metrics)
   - 3.4 [Out-of-Order Ingestion and Gap-Fill](#34-out-of-order-ingestion-and-gap-fill)
4. [Components](#4-components)
5. [Quick Start](#5-quick-start)
   - 5.1 [Local Environment (k3d)](#51-local-environment-k3d)
   - 5.2 [Cloud Environment (Civo)](#52-cloud-environment-civo)
6. [Configuration Reference](#6-configuration-reference)
   - 6.1 [OpenTelemetry Collector](#61-opentelemetry-collector)
   - 6.2 [Fluent Bit](#62-fluent-bit)
   - 6.3 [Loki](#63-loki)
   - 6.4 [Prometheus](#64-prometheus)
7. [Dashboard Reference](#7-dashboard-reference)
   - 7.1 [Vessel Operations](#71-vessel-operations-dashboard)
   - 7.2 [Edge Pipeline — SAMPLING section](#72-edge-pipeline--sampling-section)
   - 7.3 [Edge Pipeline — RESILIENCE section](#73-edge-pipeline--resilience-section)
   - 7.4 [Edge Pipeline — COLLECTOR FOOTPRINT section](#74-edge-pipeline--collector-footprint-section)
8. [Design Decisions and Trade-offs](#8-design-decisions-and-trade-offs)
9. [Network Failure Simulation](#9-network-failure-simulation)
10. [Project Structure](#10-project-structure)
11. [Troubleshooting](#11-troubleshooting)
12. [References](#12-references)

---

## 1. What This Demonstrates

Edge environments impose hard constraints that do not exist in cloud deployments: intermittent connectivity, limited CPU and RAM, no persistent storage guarantees, and the impossibility of running the full observability stack locally. This project shows how to build a pipeline that is simultaneously:

| Property | Implementation |
|---|---|
| **Bandwidth-efficient** | Tail-based sampling drops ~80% of spans before export; Fluent Bit Lua filter drops ~86% of log records at source |
| **Resilient to link outages** | File-backed persistent queue (bbolt) accumulates traces and logs on local disk during outages |
| **Self-healing after restore** | On reconnect, the queue drains automatically; Jaeger and Loki accept out-of-order data, filling the gap with original timestamps |
| **Fully correlated** | Every exported log entry carries the `trace_id` of its parent request; sampling criteria are identical in both the OTel Collector (tail sampling) and Fluent Bit (Lua filter) |
| **Lightweight** | Custom OTel Collector build (~30 MB) with exactly the components needed; resource limits designed to not compete with the application workload |

---

## 2. Architecture Overview

```
┌─────────────────────────── EDGE NODE (k8s agent-0) ────────────────────────────┐
│                                                                                   │
│  ┌──────────────────┐  OTLP gRPC :4317   ┌──────────────────────────────────┐   │
│  │  edge-demo-app   │ ──────────────────► │       OTel Collector             │   │
│  │                  │                     │                                  │   │
│  │  • /engine       │                     │  Receivers:  otlp (4317/4318)    │   │
│  │  • /navigation   │                     │  Processors: memory_limiter      │   │
│  │  • /diagnostics  │                     │              tail_sampling       │   │
│  │  • /alerts       │                     │              batch               │   │
│  │                  │                     │  Exporters:  otlp/jaeger  ──────────►│
│  └──────────────────┘                     │              prometheusrw ──────────►│
│         │ stdout logs                     │              loki         ──────────►│
│         ▼                                 │                                  │   │
│  ┌──────────────┐  OTLP HTTP :4318        │  file_storage extension          │   │
│  │  Fluent Bit  │ ──────────────────────► │  /var/lib/otelcol/file_storage   │   │
│  │              │                         │  (bbolt persistent queue)        │   │
│  │  Lua filter  │                         └──────────────────────────────────┘   │
│  │  (86% drop)  │                                                                 │
│  └──────────────┘                                                                 │
│                                                                                   │
│  ┌──────────────────┐                                                             │
│  │  network-chaos   │ ← privileged DaemonSet for iptables (network simulation)   │
│  └──────────────────┘                                                             │
└───────────────────────────────────────────────────────────────────────────────────┘
                                    │ satellite link (simulated)
                                    │ iptables DROP rules on ports 4317/9090/3100
                                    │
┌─────────────────────────── HUB NODE (k8s agent-1) ────────────────────────────┐
│                                                                                   │
│  ┌──────────┐  ┌────────────┐  ┌──────┐  ┌─────────┐                           │
│  │  Jaeger  │  │ Prometheus │  │ Loki │  │ Grafana │                           │
│  │ :16686   │  │   :9090    │  │:3100 │  │  :3000  │                           │
│  │ (traces) │  │ (metrics)  │  │(logs)│  │(dashbrd)│                           │
│  └──────────┘  └────────────┘  └──────┘  └─────────┘                           │
│                      │                                                            │
│           scrapes otel-collector:8888 and fluent-bit:2020/metrics                │
└───────────────────────────────────────────────────────────────────────────────────┘
```

**Signal flows:**

| Signal | Source | Path | Destination |
|---|---|---|---|
| Traces | edge-demo-app | OTLP gRPC → OTel Collector → tail sampling → bbolt queue → OTLP gRPC | Jaeger |
| Metrics (app) | edge-demo-app | OTLP gRPC → OTel Collector → in-memory queue → Prometheus remote-write | Prometheus |
| Metrics (infra) | OTel Collector (self) + Fluent Bit | Prometheus scrape (pull) | Prometheus |
| Logs | edge-demo-app stdout | Fluent Bit tail → Lua filter → OTLP HTTP → OTel Collector → bbolt queue → HTTP push | Loki |

---

## 3. Key Concepts

### 3.1 Tail-Based Sampling

**What is sampling?** Distributed tracing generates one span per operation per service. A single HTTP request can produce 5–50 spans as it traverses middleware, database calls, and downstream services. At modest load (10 req/s × 15 spans/request = 150 spans/s), a full year of data would occupy hundreds of GB. Sampling reduces this by only exporting a representative subset.

**Head-based sampling** makes the keep/drop decision at the first span of a trace, before any downstream spans exist. It is simple and adds no latency, but it is blind to the trace outcome: a decision to drop at t=0 means you lose the information that the trace later failed or became slow.

**Tail-based sampling** buffers all spans of a trace in memory, waits for the trace to complete, then makes the keep/drop decision based on the full trace. This guarantees:
- Every error trace is kept (regardless of frequency)
- Every slow trace is kept (regardless of frequency)
- Normal fast-success traces are dropped

**This project's tail sampling configuration:**

```yaml
tail_sampling:
  decision_wait: 5s       # buffer window: all spans arriving within 5s of the
                           # first span for a given trace_id are considered
  num_traces: 10000        # maximum concurrent traces held in memory
                           # each trace occupies roughly 1–5 KB → ~10–50 MB
  policies:
    - name: error-policy
      type: status_code
      status_code:
        status_codes: [ERROR]   # keep 100% of traces where any span has ERROR status

    - name: latency-policy
      type: latency
      latency:
        threshold_ms: 200       # keep 100% of traces whose total duration > 200ms
```

**Observed result:** ~80% of spans dropped, 100% of errors and slow traces kept.

**Important constraints of tail sampling on a DaemonSet:**
- All spans belonging to the same `trace_id` MUST reach the same collector instance. With one DaemonSet pod per node and one application pod per node, this is guaranteed by co-location.
- For multi-service architectures where spans can arrive at different collector instances, a gateway tier with consistent hash routing on `trace_id` is required. See [OpenTelemetry Tail Sampling documentation](https://opentelemetry.io/docs/collector/configuration/#tail-sampling-processor) for the gateway pattern.

**Fluent Bit alignment:** The Lua filter in Fluent Bit uses the same criteria (`level == "error"` or `duration_ms >= 200`) to filter log records. This ensures that every exported trace has a corresponding log entry and every exported log entry has a corresponding trace — a 1:1 structural guarantee, not just a best-effort correlation.

### 3.2 File-Backed Persistent Queues

**The problem:** When the satellite link fails, the OTel Collector cannot export data to the hub. Without a persistent buffer, all telemetry accumulated during the outage is lost.

**The solution:** The `file_storage` extension provides a [bbolt](https://github.com/etcd-io/bbolt) (BoltDB) key-value store on disk. When the exporter's sending queue is configured with `storage: file_storage`, items are serialized and written to bbolt before being dispatched. Items remain in bbolt until the exporter receives a successful acknowledgment from the remote endpoint.

**bbolt properties relevant to this demo:**
- ACID-compliant: writes are crash-safe (write-ahead log)
- Single-process, single-writer model: appropriate for one DaemonSet pod per node
- Items are stored as sequential buckets keyed by sequence number
- The file does NOT shrink after drain (high-water mark behavior): after a 2-minute outage, the bbolt file will have the same size as at peak queue depth, even after all items are sent. This is expected and harmless.

**Queue configuration parameters explained:**

```yaml
sending_queue:
  enabled: true
  num_consumers: 1    # number of goroutines consuming from the queue simultaneously.
                       # With 1, items are processed one batch at a time.
                       # Higher values increase throughput but reduce queue_size visibility:
                       # with 4 consumers, 4 batches are in-flight simultaneously and
                       # the metric otelcol_exporter_queue_size reflects only items
                       # WAITING in bbolt, not items being retried — which stays near 0
                       # even during outages when consumers quickly claim items.
                       # With 1 consumer, all batches beyond the first accumulate visibly
                       # in bbolt → queue_size grows monotonically during outages.
  queue_size: 1000    # maximum number of batches in the persistent queue.
                       # Each batch holds up to send_batch_size (512) spans.
                       # Capacity = 1000 × 512 = 512,000 spans.
                       # At ~3 sampled spans/s (post tail-sampling), that is
                       # ~47 hours of buffer before overflow — far beyond any
                       # satellite outage scenario.
  storage: file_storage  # reference to the file_storage extension defined above
```

**Retry policy:**
```yaml
retry_on_failure:
  enabled: true
  initial_interval: 5s   # first retry after 5 seconds
  max_interval: 30s      # exponential backoff cap: 5s → 7.5s → 11.25s → 16.875s → 25.3s → 30s → 30s …
  max_elapsed_time: 300s # give up and drop data only after 5 minutes of continuous failure.
                          # For the demo scenario (2–3 min outage), this is never reached.
```

**Why `num_consumers: 1` matters for observability:** With the default of 4 consumers, each goroutine claims a batch from bbolt as soon as it becomes available. Since the batch processor produces approximately 0.3 batches/s (a batch every 5s at low traffic), and 4 goroutines can claim them in milliseconds, the queue depth stays near 0 even during outages — items are in the retry_sender's in-memory retry buffer, not in bbolt. With `num_consumers: 1`, only one batch is ever in-flight; all others wait in bbolt, making `otelcol_exporter_queue_size` grow correctly during outages.

**Coverage by signal:**

| Signal | Exporter | File-backed queue | Gap-fill on restore |
|---|---|---|---|
| Traces | `otlp/jaeger` | ✅ yes (`storage: file_storage`) | ✅ yes (Jaeger accepts any timestamp) |
| Logs | `loki` | ✅ yes (`storage: file_storage`) | ✅ yes (`unordered_writes: true`) |
| Metrics | `prometheusremotewrite` | ❌ no (library limitation in OTel Collector v0.95) | ❌ no (in-memory queue, dropped on failure) |

The metrics gap is a deliberate and honest trade-off. See [§8.2](#82-prometheusremotewrite-vs-otlphttp-for-metrics) for the full explanation.

### 3.3 Signal Correlation: Traces, Logs, and Metrics

Observability is only actionable when the three signal types can be navigated together: a latency spike in metrics leads to a specific slow trace in Jaeger, and that trace links to the exact log lines produced during the slow request.

**How correlation is implemented here:**

1. **Trace context propagation:** The demo app creates an OpenTelemetry span for every incoming HTTP request. The span's `trace_id` and `span_id` are extracted and injected into every structured log line via the [zap](https://github.com/uber-go/zap) logger. Log format:
   ```json
   {"timestamp":"2025-01-15T10:23:45Z","level":"error","msg":"request failed",
    "trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7",
    "http.route":"/api/alerts/system","http.status_code":500,"duration_ms":142}
   ```

2. **Fluent Bit forward:** The log line is picked up by Fluent Bit's tail input from the pod log file. The Lua filter decides to keep or drop it. If kept, it is forwarded to the OTel Collector via OTLP HTTP, which passes it to Loki.

3. **Grafana deep link:** The "Vessel Operations" dashboard's logs panel has a configured data link on the `trace_id` field. Clicking it opens `http://<jaeger-host>/trace/<trace_id>` directly in Jaeger.

**Sampling alignment guarantee:** Because the OTel Collector's tail sampling and Fluent Bit's Lua filter use identical criteria (`ERROR` status or latency ≥ 200ms), for any given request exactly one of two outcomes occurs:
- The request is fast and successful → span dropped by tail sampling, log dropped by Lua filter → neither appears in Jaeger or Loki
- The request is slow or failed → span kept by tail sampling, log kept by Lua filter → both appear, connected by `trace_id`

This deterministic alignment means there are no "orphaned" log entries (logs with a `trace_id` that doesn't exist in Jaeger) and no "orphaned" traces (traces without a corresponding log entry).

### 3.4 Out-of-Order Ingestion and Gap-Fill

When the satellite link is restored after an outage, the OTel Collector begins draining its file-backed queue. The items in the queue have their original timestamps (the time they were generated on the edge node), which may be minutes or hours in the past. Both Jaeger and Loki must be configured to accept these retroactive timestamps.

**Jaeger:** Accepts spans with any timestamp by design. The Jaeger storage model is append-only and there is no concept of "out-of-order rejection". Traces with timestamps from the failure window will appear in the Jaeger UI when searched by time range.

**Loki:** By default, Loki rejects log entries whose timestamp is older than the per-stream ingestion window. To enable gap-fill, the Loki configuration sets:
```yaml
limits_config:
  unordered_writes: true
```
This disables the per-stream ordering requirement, allowing log entries from the failure window to be ingested regardless of their order relative to entries already stored. Without this setting, the OTel Collector would receive HTTP 400 errors when draining the log queue, and logs from the failure window would be permanently lost.

**Prometheus/Metrics:** The `prometheusremotewrite` exporter uses the Prometheus Remote Write protocol. When the link is restored, the OTel Collector sends the in-memory queue, which contains only the most recent metric samples (not the full failure window). Prometheus silently skips out-of-order samples from remote-write (HTTP 204 with 0 written samples). The failure-window gap in metrics is therefore NOT filled. This is a known limitation and is explicitly called out as expected behavior. See [§8.2](#82-prometheusremotewrite-vs-otlphttp-for-metrics).

---

## 4. Components

| Component | Image | Version | Role | Node |
|---|---|---|---|---|
| edge-demo-app | built locally / `ghcr.io/graz-dev/edge-demo-app:latest` | — | Maritime vessel monitoring HTTP API | edge |
| OTel Collector | `ghcr.io/graz-dev/otel-collector-edge` | 0.1.0 | Telemetry pipeline: receive, process, queue, export | edge |
| Fluent Bit | `fluent/fluent-bit` | 2.2 | Log tailing, Lua filtering, OTLP forwarding | edge |
| network-chaos | `nicolaka/netshoot` | latest | Privileged DaemonSet for iptables simulation | edge |
| Jaeger | `jaegertracing/all-in-one` | 1.54 | Distributed trace storage and UI | hub |
| Prometheus | `prom/prometheus` | 2.49.1 | Time-series metrics storage and query engine | hub |
| Loki | `grafana/loki` | 2.9.4 | Log aggregation and query engine | hub |
| Grafana | `grafana/grafana` | 10.3.3 | Visualization: dashboards, data source federation | hub |
| k6 Operator | Helm chart | — | Kubernetes-native load test runner | hub |

### edge-demo-app

A Go HTTP server simulating a maritime vessel monitoring system. Four endpoints with distinct latency and error profiles that exercise all sampling paths:

| Endpoint | Latency | Error rate | Tail sampling outcome | Traffic share |
|---|---|---|---|---|
| `GET /api/sensors/engine` | 50–80 ms | 0% | **Dropped** (fast success) | 50% |
| `GET /api/sensors/navigation` | 40–60 ms | 0% | **Dropped** (fast success) | 30% |
| `GET /api/analytics/diagnostics` | 300–1500 ms | 0% | **Kept** (latency policy: >200ms) | 12% |
| `GET /api/alerts/system` | 80–160 ms | 20% | **Kept** if error (error policy), **dropped** if success | 8% |

Every request handler attaches `trace_id` and `span_id` to the structured log output (zap JSON logger). The application sends telemetry via OTLP gRPC to the OTel Collector at `otel-collector.observability.svc.cluster.local:4317`.

**Custom metrics exported:**
- `http.server.request.count` — Int64Counter, incremented per request, labels: `http.route`, `http.status_code`
- `http.server.request.duration` — Float64Histogram (milliseconds), labels: `http.route`, `http.status_code`
- `vessel.diagnostics.count` — Int64Counter, incremented per `/diagnostics` call

### OTel Collector (custom build)

The standard `otelcol-contrib` distribution ships 150+ components (~250 MB). This project builds a minimal custom collector using the [OpenTelemetry Collector Builder (ocb)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder) with exactly 9 components:

| Type | Name | Purpose |
|---|---|---|
| Extension | `health_check` | Kubernetes liveness/readiness probe endpoint |
| Extension | `file_storage` | bbolt persistent queue backend |
| Receiver | `otlp` | Receive telemetry from app (gRPC 4317) and Fluent Bit (HTTP 4318) |
| Processor | `memory_limiter` | Circuit-breaker: drop data before OOM kills the collector |
| Processor | `batch` | Accumulate spans/metrics/logs into batches before export |
| Processor | `resource` | Add common resource attributes (environment, cluster) |
| Processor | `tail_sampling` | Buffered trace-outcome-aware sampling |
| Exporter | `otlp` | Export traces to Jaeger via OTLP gRPC |
| Exporter | `prometheusremotewrite` | Export metrics to Prometheus via remote-write |
| Exporter | `loki` | Export logs to Loki via HTTP push |

Final image size: ~30 MB vs. ~250 MB for `otelcol-contrib`. The image is distroless (no shell), which means `kubectl exec` to run utilities inside the collector container is not possible — this is why the `network-chaos` DaemonSet mounts the file storage path directly for local inspection.

The `edge-demo-app` image is built automatically via GitHub Actions (`.github/workflows/build-app.yaml`) on every push to `master` and `feat/**` branches when files under `app/**` change. It produces a multi-architecture image (`linux/amd64`, `linux/arm64`) and pushes it to `ghcr.io/graz-dev/edge-demo-app:latest`.

### Fluent Bit

Fluent Bit runs as a DaemonSet on edge nodes, reading container logs from `/var/log/pods/`. The pipeline is:

1. **Input (tail):** Read lines from `observability_edge-demo-app*/**/*.log` using the CRI log format parser.
2. **Filter (Kubernetes):** Enrich each log record with pod name, namespace, labels, and annotations.
3. **Filter (Lua script):** Apply the sampling filter — keep only `level=error` or `duration_ms >= 200`. Drop everything else. This reduces log volume by ~86% before the data ever leaves the node.
4. **Output (OpenTelemetry HTTP):** Forward kept records to the OTel Collector at `otel-collector.observability.svc.cluster.local:4318` via OTLP HTTP.

Fluent Bit exposes Prometheus metrics at `:2020/api/v1/metrics/prometheus` (note: the path is specific to Fluent Bit 2.x, not the conventional `/metrics`). Prometheus scrapes these metrics for the "Log Flow" panel in the Edge Pipeline dashboard.

### network-chaos DaemonSet

A privileged DaemonSet running `nicolaka/netshoot` — a network debugging image with `iptables`, `iptables-legacy`, `conntrack`, and other utilities. It serves as the execution environment for iptables commands, replacing the `docker exec k3d-*` approach that only works on local k3d.

Key properties:
- `hostNetwork: true` — the pod operates in the host network namespace, so iptables rules it writes apply to the node's kernel, affecting all traffic routed through the node
- `securityContext.privileged: true` — required for iptables and conntrack operations
- Mounts `hostPath: /var/lib/otelcol/file_storage` — allows listing queue files on local k3d without exec-ing into the distroless collector container

This pattern is environment-agnostic: it works identically on local k3d, Civo, and any other Kubernetes cluster.

---

## 5. Quick Start

### 5.1 Local Environment (k3d)

**Prerequisites:**
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine) running
- [k3d](https://k3d.io/) v5.6+: `brew install k3d`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.28+: `brew install kubectl`
- [Helm](https://helm.sh/) v3.x: `brew install helm`

**Step 1: Deploy the full stack (~5 minutes)**

```bash
./scripts/setup.sh
```

This script:
1. Builds the `edge-demo-app` Docker image locally
2. Creates a k3d cluster named `edge-observability` with 2 agent nodes
3. Labels `agent-0` as `node-role=edge` and `agent-1` as `node-role=hub`
4. Pre-pulls container images into the cluster (avoids pull latency during demo)
5. Installs the k6 Operator via Helm
6. Applies `overlays/local` via Kustomize (hostPath volume, NodePort services)
7. Waits for all pods to reach Ready state

At the end, URLs are printed:
```
Grafana:    http://localhost:30300  (admin/admin)
Jaeger:     http://localhost:30686
Prometheus: http://localhost:9090 (via kubectl port-forward, started by setup)
```

**Step 2: Start the load generator**

```bash
./scripts/load-generator.sh
```

Creates the k6 TestRun custom resource. k6 runs 8 virtual users for 40 minutes, split across all four endpoints. Allow 30–60 seconds for the runner pod to start and for data to populate the dashboards before beginning the demo.

**Step 3: Run the demo**

```bash
./scripts/demo.sh
```

The demo script is fully orchestrated. It:
- Runs preflight checks (pod readiness, Prometheus connectivity, iptables state)
- Guides you through Act 1 (baseline), Act 2 (sampling), and Act 3 (network failure + restore)
- Pauses at each key moment with instructions for what to show the audience
- Polls metrics in real time during the failure window
- Verifies gap-fill after restore

You can also start from a specific act:
```bash
./scripts/demo.sh 3   # jump directly to Act 3 (network failure)
```

**Step 4: Clean up**

```bash
./scripts/cleanup.sh
```

Deletes the k3d cluster and all associated resources.

**Demo reset (without full teardown):**

If re-running Act 3, you must clear stale queue files first. Old bbolt entries contain metric timestamps that Prometheus will reject as out-of-order:

```bash
CHAOS_POD=$(kubectl get pod -n observability -l app=network-chaos -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n observability "$CHAOS_POD" -- find /var/lib/otelcol/file_storage -type f -delete
kubectl rollout restart daemonset/otel-collector -n observability
```

Wait for the collector DaemonSet to come back up before running the demo again.

---

### 5.2 Cloud Environment (Civo)

**Prerequisites:**
- [Civo CLI](https://github.com/civo/cli): `brew install civo`
- Civo account with API key configured: `civo apikey save <name> <key>`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.28+
- [Helm](https://helm.sh/) v3.x

Verify the CLI is authenticated:
```bash
civo kubernetes list   # should return 0 items or existing clusters
```

**Step 1: Deploy the full stack (~10 minutes)**

```bash
./scripts/setup.sh --env civo
```

Additional optional flags:
```bash
./scripts/setup.sh --env civo --region LON1 --size g4s.kube.medium
```

This script:
1. Creates a Civo K3s cluster (`edge-observability`) with 2 nodes
2. Waits for the cluster to become ACTIVE and for both nodes to register in the Kubernetes API (Civo marks a cluster ACTIVE before nodes are fully registered — the script polls until the node count is ≥ 2)
3. Merges the kubeconfig and switches context
4. Prompts you to label the two nodes as edge and hub (interactive)
5. Installs the k6 Operator via Helm
6. Applies `overlays/civo` via Kustomize (PVC, LoadBalancer services, image from ghcr.io)
7. Waits for the PVC to bind and all pods to reach Ready state
8. Waits for Grafana and Jaeger LoadBalancer IPs to be assigned
9. Prints final URLs with actual external IPs

**The Civo overlay differs from local in three ways:**
- `overlays/civo/patches/otelcol-pvc.yaml` replaces the emptyDir base volume with a PVC (`otelcol-file-storage`, 1Gi, StorageClass `civo-volume`)
- `overlays/civo/patches/grafana-lb.yaml` and `jaeger-lb.yaml` set `type: LoadBalancer`
- `overlays/civo/patches/app-deployment.yaml` sets the app image to `ghcr.io/graz-dev/edge-demo-app:latest` and `imagePullPolicy: IfNotPresent`

**Step 2: Start the load generator**

```bash
./scripts/load-generator.sh
```

Same as local. k6 runs from within the cluster.

**Step 3: Run the demo**

```bash
./scripts/demo.sh --env civo
```

The `--env civo` flag uses LoadBalancer IPs instead of localhost NodePorts, and the file storage display in Act 3 shows PVC metadata and a calculated span backlog.

**Step 4: Clean up**

```bash
./scripts/cleanup.sh --env civo
```

Deletes the Kubernetes resources, then prompts whether to delete the Civo cluster itself.

---

## 6. Configuration Reference

### 6.1 OpenTelemetry Collector

The full configuration is in `k8s/edge-node/otel-collector-config.yaml`. This section explains every parameter and the reasoning behind each choice.

#### Extensions

```yaml
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
```

The `health_check` extension exposes an HTTP endpoint that returns 200 OK when the collector is operational. Used by the DaemonSet's `livenessProbe` and `readinessProbe`. Without this, Kubernetes cannot distinguish a healthy collector from a crashed one.

```yaml
  file_storage:
    directory: /var/lib/otelcol/file_storage
    timeout: 10s
```

The `file_storage` extension provides the bbolt backend. `timeout: 10s` is the maximum time a single bbolt operation may take — a safety guard against a hung disk. Under normal conditions, operations complete in microseconds.

**Storage path by environment:**
- Local (k3d): hostPath at `/var/lib/otelcol/file_storage` (overlays/local patch)
- Civo: PVC `otelcol-file-storage` (1Gi, `civo-volume` StorageClass) mounted at the same path (overlays/civo patch)

#### Receivers

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317   # receives traces and metrics from edge-demo-app
      http:
        endpoint: 0.0.0.0:4318   # receives logs from Fluent Bit (OTLP HTTP)
```

The app uses gRPC (lower overhead, binary framing, HTTP/2 multiplexing). Fluent Bit 2.2's OTLP output plugin only supports HTTP, so it targets port 4318.

#### Processors

**Order in the traces pipeline is critical:**
```yaml
traces:
  processors: [memory_limiter, resource, tail_sampling, batch]
```

1. `memory_limiter` — must be first. It is the circuit breaker: drop incoming data before accepting it into the pipeline when memory is under pressure.
2. `resource` — add enrichment attributes before tail_sampling sees the spans.
3. `tail_sampling` — must come BEFORE `batch`. The sampler needs to see individual spans to correlate them by `trace_id`. If batch ran first, pre-batched groups would prevent correct trace correlation.
4. `batch` — runs last, after sampling has reduced volume, grouping only kept spans into efficient batches for export.

```yaml
  memory_limiter:
    check_interval: 1s      # check memory every second
    limit_mib: 400          # hard limit: 400 MiB RSS
    spike_limit_mib: 80     # effective soft limit = 400 - 80 = 320 MiB
```

When RSS exceeds the soft limit (320 MiB), the memory_limiter refuses new data (returns `ResourceExhausted` to the sender). When RSS exceeds the hard limit (400 MiB), it drops data. This prevents OOM-kill, which would cause greater data loss than controlled dropping.

```yaml
  batch:
    timeout: 5s             # flush a batch every 5 seconds even if not full
    send_batch_size: 512    # preferred batch size
    send_batch_max_size: 1024  # absolute maximum
```

A single gRPC call carrying 512 spans is orders of magnitude cheaper than 512 individual calls. The 5-second timeout ensures data is not held indefinitely in low-traffic scenarios. This timeout also determines the cadence at which bbolt queue depth grows during link outages (1 new batch entry every 5s).

```yaml
  resource:
    attributes:
      - key: deployment.environment
        value: edge
        action: insert
      - key: cluster.name
        value: edge-observability
        action: insert
```

`insert` only adds the attribute if it does not already exist (non-destructive). These attributes are attached to every span, metric datapoint, and log record passing through the collector.

#### Exporters — `otlp/jaeger`

```yaml
  otlp/jaeger:
    endpoint: jaeger.observability.svc.cluster.local:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 1
      queue_size: 1000
      storage: file_storage
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
```

The exporter name `otlp/jaeger` uses the name/alias syntax: `<type>/<alias>`. This allows multiple OTLP exporters to coexist in the same pipeline without naming conflicts.

`num_consumers: 1` — see [§3.2](#32-file-backed-persistent-queues) for the detailed explanation of why this value is used instead of the default 4.

`max_elapsed_time: 300s` — the retry policy gives up after 5 minutes of continuous failure. For the demo scenario (2–3 min outage), this threshold is never reached.

#### Exporters — `prometheusremotewrite`

```yaml
  prometheusremotewrite:
    endpoint: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
    tls:
      insecure: true
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
    # No sending_queue.storage — not supported for prometheusremotewrite in OTel v0.95
```

The absence of `storage: file_storage` is a known limitation of the `prometheusremotewrite` exporter in OTel Collector v0.95. The queue is in-memory only. See [§8.2](#82-prometheusremotewrite-vs-otlphttp-for-metrics) for the full explanation.

#### Exporters — `loki`

```yaml
  loki:
    endpoint: http://loki.observability.svc.cluster.local:3100/loki/api/v1/push
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 1
      queue_size: 1000
      storage: file_storage
    retry_on_failure:
      enabled: true
      initial_interval: 5s
      max_interval: 30s
      max_elapsed_time: 300s
```

Mirror of the Jaeger exporter. Both use the same file-backed queue and retry policy.

#### Telemetry (collector self-monitoring)

```yaml
  telemetry:
    logs:
      level: info
    metrics:
      address: 0.0.0.0:8888
      level: detailed
```

`level: detailed` is **required** for the queue depth panel in Grafana to receive data. Without it, `otelcol_exporter_queue_size` and many other internal metrics (including per-policy tail sampling counters) are not emitted. The `address: 0.0.0.0:8888` is the Prometheus scrape endpoint for the collector's own metrics.

---

### 6.2 Fluent Bit

Configuration is in `k8s/edge-node/fluentbit-config.yaml`, split into three sections.

#### Main configuration (`fluent-bit.conf`)

```ini
[SERVICE]
    Flush        5
    Log_Level    info
    Parsers_File parsers.conf
    HTTP_Server  On
    HTTP_Listen  0.0.0.0
    HTTP_Port    2020      # Prometheus metrics at /api/v1/metrics/prometheus
    storage.type filesystem
```

`storage.type filesystem` enables Fluent Bit's own on-disk input buffer. If the OTLP output is backpressuring (e.g., the OTel Collector is not accepting data), Fluent Bit will spill input buffer to disk rather than dropping records. This provides a secondary resilience layer at the log ingestion stage.

```ini
[INPUT]
    Name              tail
    Path              /var/log/pods/observability_edge-demo-app*/*/*.log
    Parser            cri
    Mem_Buf_Limit     5MB
    storage.type      filesystem
```

The path glob matches CRI-format log files for the `edge-demo-app` pod. CRI format wraps each line: `<timestamp> <stream> <flags> <content>`. The `cri` parser strips the wrapper and presents the raw JSON log line to subsequent filters.

```ini
[FILTER]
    Name    lua
    script  /fluent-bit/etc/filter_logs.lua
    call    filter_by_severity_or_latency

[OUTPUT]
    Name                 opentelemetry
    Host                 otel-collector.observability.svc.cluster.local
    Port                 4318
    Log_response_payload True
    tls                  off
    storage.total_limit_size 50MB
```

`storage.total_limit_size 50MB` limits the output's on-disk buffer. If Loki is unreachable and the OTel Collector's output buffer fills to 50MB, Fluent Bit will start dropping records (the oldest first). For the demo scenario (2–3 min outage), 50MB is not approached.

#### Lua filter (`filter_logs.lua`)

```lua
function filter_by_severity_or_latency(tag, timestamp, record)
    local level       = record["level"]
    local duration_ms = record["duration_ms"]

    if level == "error" then
        return 0, 0, 0   -- keep unchanged
    end

    if duration_ms ~= nil and tonumber(duration_ms) >= 200 then
        return 0, 0, 0   -- keep unchanged
    end

    return -1, 0, 0      -- drop
end
```

**Why Lua and not a native Fluent Bit filter?**

Fluent Bit's native `grep` and `modify` filters support exact string matching but not combined multi-field conditional logic with OR semantics (keep if level=error OR if duration_ms >= 200). Lua provides the expressiveness needed for this exact-mirror-of-tail-sampling logic.

**Why filter in Fluent Bit and not only in the OTel Collector?**

Filtering in Fluent Bit reduces log volume before it leaves the edge node. If all logs were forwarded and the OTel Collector applied sampling, the satellite link would carry the full unsampled log volume. The Lua filter operates at the very first stage (before any network I/O), maximizing bandwidth efficiency.

---

### 6.3 Loki

```yaml
limits_config:
  unordered_writes: true
```

This is the single most important Loki setting for the gap-fill story. In Loki, log entries for a given "stream" (a unique label set) must normally arrive in roughly chronological order within the active chunk window (`max_chunk_age: 1h`). Entries with significantly older timestamps are rejected with HTTP 400.

With `unordered_writes: true`, Loki processes entries regardless of their timestamp order relative to previously ingested entries in the same stream. This enables queued logs from the failure window to be ingested when the OTel Collector drains after link restore.

Other relevant settings:
```yaml
ingester:
  chunk_encoding: snappy      # fast compression, lower CPU than zstd
  chunk_idle_period: 1h
  max_chunk_age: 1h
  wal:
    enabled: true             # write-ahead log: log entries are crash-safe after ingestion
    dir: /loki/wal
```

The WAL ensures that log entries ingested by Loki but not yet flushed to the chunk store are recoverable after a Loki restart. This is defense-in-depth for the demo.

---

### 6.4 Prometheus

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: 'edge-observability'
    environment: 'demo'
```

The 15-second scrape interval is the minimum time resolution for all Prometheus metrics in this project. This directly affects how Grafana dashboard queries should be written:
- `rate(metric[1m])` uses 4 scrape points (recommended minimum for stability)
- `rate(metric[30s])` uses 2 scrape points (minimum acceptable; used for the throughput panel to provide faster response during link failure)

```yaml
scrape_configs:
  - job_name: 'otel-collector'
    static_configs:
      - targets: ['otel-collector.observability.svc.cluster.local:8888']
        labels:
          component: 'otel-collector'
          node_role: 'edge'
```

OTel Collector metrics come from the collector's own Prometheus endpoint at port 8888. The additional labels `component` and `node_role` are injected at scrape time.

```yaml
  - job_name: 'fluent-bit'
    metrics_path: /api/v1/metrics/prometheus   # Fluent Bit 2.x non-standard path
    kubernetes_sd_configs:
      - role: pod
        namespaces:
          names: [observability]
    relabel_configs:
      - source_labels: [__meta_kubernetes_pod_label_app]
        action: keep
        regex: fluent-bit
```

Service discovery is used for Fluent Bit because its pod IP can change (DaemonSet reschedule). The `relabel_configs` keep only pods with the `app=fluent-bit` label. The custom `metrics_path` is required — Fluent Bit 2.x exposes metrics at `/api/v1/metrics/prometheus`, not the conventional `/metrics`.

---

## 7. Dashboard Reference

Both dashboards are deployed as a Kubernetes ConfigMap (`grafana-dashboards-configmap.yaml`) and auto-provisioned into Grafana at startup. They refresh every **5 seconds**.

**General notes on metric math:**
- Prometheus scrape interval: **15 seconds** — the minimum meaningful `rate()` window is 30s (2× scrape interval); 1m is preferred (4× scrape interval)
- All `rate()` and `increase()` expressions operate on monotonically increasing counters
- `rate(counter[window])` returns the per-second rate averaged over the window
- `increase(counter[window])` returns the total increment over the window (equivalent to `rate() × window_seconds`)
- `histogram_quantile(φ, …)` uses linear interpolation between bucket boundaries — accuracy depends on bucket resolution relative to the distribution
- `or vector(0)` handles the case where a metric has no samples (e.g., queue_size is genuinely 0 and has no active time series); without this, the panel shows "No data" instead of 0

---

### 7.1 Vessel Operations Dashboard

**Purpose:** Show the health and behavior of the maritime system itself. This is the "business layer" view used in Act 1.

**UID:** `vessel-operations` | **Refresh:** 5s | **Time range:** last 15 minutes

#### Panel: Request Rate

| Property | Value |
|---|---|
| Type | Stat (large number + sparkline) |
| Unit | requests per second (req/s) |
| Query | `sum(rate(http_server_request_count_total[1m]))` |
| Aggregation | `sum` across all labels (routes, status codes) |
| Window | 1-minute rolling rate |

`http_server_request_count_total` is the OTel counter `http.server.request.count` from the app, received via OTLP and forwarded to Prometheus via remote-write. The `rate([1m])` divides the counter increment over the last 4 scrape points by 60s. Color thresholds: green < 5 req/s, yellow 5–10 req/s, red > 10 req/s.

#### Panel: Error Rate

| Property | Value |
|---|---|
| Type | Stat |
| Unit | Percent (0–100%) |
| Query | `sum(rate(http_server_request_count_total{http_status_code=~"5.."}[1m])) / sum(rate(http_server_request_count_total[1m]))` |
| Aggregation | ratio of 5xx rate to total rate |

The label selector `http_status_code=~"5.."` is a regex matching any 5xx status. Expected value during steady-state: ~1.6% (20% error rate × 8% of `/alerts` traffic). Color thresholds: green < 5%, yellow 5–15%, red > 15%.

#### Panel: P95 Latency

| Property | Value |
|---|---|
| Type | Stat |
| Unit | milliseconds |
| Query | `histogram_quantile(0.95, sum(rate(http_server_request_duration_milliseconds_bucket[1m])) by (le))` |
| Aggregation | sum of bucket rates by `le` label, then quantile estimation |

`http_server_request_duration_milliseconds_bucket` is a Prometheus histogram with cumulative bucket counters keyed by the `le` (less-than-or-equal) label. `sum(rate(…)) by (le)` computes the per-second rate of increment for each bucket, preserving the bucket structure. `histogram_quantile(0.95, …)` applies linear interpolation between the two buckets that bracket the 95th percentile. Expected P95: ~500–1000 ms (driven by `/diagnostics`). Color thresholds: green < 200ms, yellow 200–500ms, red > 500ms.

#### Panel: Diagnostics Run (5m)

| Property | Value |
|---|---|
| Type | Stat |
| Unit | count |
| Query | `sum(increase(vessel_diagnostics_count_total[5m]))` |

`increase(counter[5m])` = total counter increment over the last 5 minutes. Used here because the absolute count is more intuitive than a per-second rate for a low-frequency event.

#### Panel: Request Rate by Endpoint

| Property | Value |
|---|---|
| Type | Time series |
| Unit | requests per second |
| Query | `sum(rate(http_server_request_count_total[1m])) by (http_route)` |
| Legend | `{{http_route}}` — one line per endpoint |

Shows four lines with relative heights reflecting the k6 load distribution: engine (50%), navigation (30%), diagnostics (12%), alerts (8%).

#### Panel: Latency P50/P95 by Endpoint

| Property | Value |
|---|---|
| Type | Time series |
| Unit | milliseconds |
| P50 query | `histogram_quantile(0.50, sum(rate(http_server_request_duration_milliseconds_bucket[1m])) by (le, http_route))` |
| P95 query | `histogram_quantile(0.95, sum(rate(http_server_request_duration_milliseconds_bucket[1m])) by (le, http_route))` |

8 lines total (P50 + P95 × 4 routes). The `by (le, http_route)` preserves both the bucket dimension (required for quantile) and the route dimension (for per-endpoint breakdown). Expected pattern: engine/navigation ~60ms, diagnostics P50 ~600ms P95 ~1400ms, alerts ~120ms.

#### Panel: Application Logs

| Property | Value |
|---|---|
| Type | Logs |
| Query | `{exporter="OTLP"} \| json` |
| Data source | Loki |

`{exporter="OTLP"}` matches streams ingested by Fluent Bit's OTLP output, which tags streams with this label. `| json` parses the raw JSON log line and extracts all fields as queryable metadata. The `trace_id` field has a data link to Jaeger.

**Known limitation for Civo:** The data link URL is hardcoded to `http://localhost:30686`. Update the URL in `grafana-dashboards-configmap.yaml` to the Jaeger LoadBalancer IP for Civo demos.

---

### 7.2 Edge Pipeline — SAMPLING section

**Purpose:** Quantify pipeline data reduction and sampling policy distribution.

#### Panel: Trace Data Reduction (gauge)

| Property | Value |
|---|---|
| Type | Gauge |
| Unit | percent (0–100) |
| Query | `(1 - sum(rate(otelcol_exporter_sent_spans[2m])) / sum(rate(otelcol_receiver_accepted_spans[2m]))) * 100` |
| Window | 2-minute rolling rate |

`otelcol_receiver_accepted_spans` — spans accepted into the collector pipeline, regardless of sampling outcome. Scraped from OTel Collector's self-metrics at `:8888`.

`otelcol_exporter_sent_spans` — spans successfully delivered to Jaeger (post-sampling).

The ratio shows the sampling keep rate. The gauge shows `(1 - keep_rate) × 100` = percentage dropped. Target: **70–85%** (green). The 2-minute window balances responsiveness with statistical stability.

#### Panel: Trace Flow — Received vs Exported

| Property | Value |
|---|---|
| Type | Time series |
| Unit | spans per second |
| Query A (blue) | `sum(rate(otelcol_receiver_accepted_spans[1m]))` |
| Query B (green) | `sum(rate(otelcol_exporter_sent_spans[1m]))` |

The gap between the lines represents sampling drop volume. During a link failure, the green line drops to zero while the blue line continues — 100% of spans are being queued. After restore, the green line spikes above baseline (queue drain burst).

**Important nuance:** `otelcol_exporter_sent_spans` counts spans passed to the exporter's send queue, not physically transmitted. During a link failure, this counter stops because the batch processor's output is held in bbolt (not "sent"). This is why the graph correctly shows zero during an outage.

#### Panel: Log Flow — Fluent Bit Input vs Forwarded

| Property | Value |
|---|---|
| Type | Time series |
| Unit | records per second |
| Query A (blue) | `sum(rate(fluentbit_input_records_total[1m]))` |
| Query B (green) | `sum(rate(fluentbit_output_proc_records_total[1m]))` |

`fluentbit_input_records_total` — all log lines read by the tail input.
`fluentbit_output_proc_records_total` — records forwarded after the Lua filter.

The ~86% gap between lines is structural: it reflects the traffic distribution (fast sensor reads dominate). This visual proof of log-at-source filtering is the complement to the trace sampling panel. During a link failure, the green line drops (Fluent Bit cannot deliver to the OTel Collector or buffers to disk), mirroring the trace behavior.

#### Panel: Sampling Policy Breakdown

| Property | Value |
|---|---|
| Type | Time series (stacked bars) |
| Unit | traces per second |
| Error policy query | `sum(rate(otelcol_processor_tail_sampling_count_traces_sampled{policy="error-policy",sampled="true"}[1m])) or vector(0)` |
| Latency policy query | `sum(rate(otelcol_processor_tail_sampling_count_traces_sampled{policy="latency-policy",sampled="true"}[1m])) or vector(0)` |

`otelcol_processor_tail_sampling_count_traces_sampled` — emitted by the tail sampler per policy. Counts **traces** (not spans). Labels: `policy` (policy name), `sampled` (true/false).

Expected values: error policy ~0.013 traces/s, latency policy ~0.10 traces/s. The `or vector(0)` prevents "No data" gaps when traffic is momentarily zero.

---

### 7.3 Edge Pipeline — RESILIENCE section

**Purpose:** Visualize the persistence layer behavior during link failure and recovery. This is the centrepiece of Act 3.

#### Panel: Export Throughput

| Property | Value |
|---|---|
| Type | Time series |
| Unit | count per second (cps) |
| Query A (blue) | `rate(otelcol_exporter_sent_spans{exporter="otlp/jaeger"}[30s])` |
| Query B (green) | `rate(otelcol_exporter_sent_log_records{exporter="loki"}[30s])` |
| Window | **30-second rolling rate** (deliberately shorter than the 1m standard) |
| Y-axis minimum | 0 |

**Why 30s instead of 1m?** A 1-minute rate window smooths out the link failure over 60 seconds, producing a gradual slope rather than a sharp cliff. The 30-second window reflects the link state change within 2 scrape intervals, providing a crisper visual signal during the demo.

The `exporter` label value `"otlp/jaeger"` matches the alias defined in the pipeline configuration.

**What to expect:**
- Normal: both lines flat at steady-state
- Link fails: both drop to 0 within ~30 seconds
- Link restores: both spike significantly above baseline (queue drain), then settle

The magnitude of the spike is proportional to the outage duration: a 2-minute outage accumulates ~24 batches × ~5–10 spans per batch = ~120–240 spans. These drain at full network speed in ~5–10 seconds, producing a burst ~10–50× the steady-state rate.

#### Panel: Permanent Data Drops (5m)

| Property | Value |
|---|---|
| Type | Stat (color background) |
| Unit | count |
| Query | `sum(increase(otelcol_exporter_send_failed_spans[5m])) + sum(increase(otelcol_exporter_send_failed_log_records[5m]))` |

`otelcol_exporter_send_failed_spans` is incremented only when the retry policy gives up after `max_elapsed_time` (5 minutes), OR when an item fails to be enqueued (queue full). This represents **permanent, unrecoverable data loss**.

For a typical demo outage of 2–3 minutes, this counter stays at **0** (green). Any non-zero value warrants investigation. Color: green = 0, yellow ≥ 1, red ≥ 10.

#### Panel: Queue Depth (batches)

| Property | Value |
|---|---|
| Type | Time series |
| Unit | batches (dimensionless) |
| Query | `sum(otelcol_exporter_queue_size) or vector(0)` |
| Y-axis minimum | 0 |

`otelcol_exporter_queue_size` is a **gauge** reporting the instantaneous number of batches in bbolt waiting to be consumed. This metric requires:
1. `telemetry.metrics.level: detailed` in the collector config
2. `num_consumers: 1` in the exporter's sending_queue config (see [§3.2](#32-file-backed-persistent-queues))

**What to expect:**
- Normal: 0 (queue drains as fast as batches are produced)
- Link fails: grows by ~1 batch every 5 seconds (`batch.timeout`)
- After 2-minute outage: ~24 batches
- Link restores: drops to 0 as batches are acknowledged by the backends

The `sum(…)` aggregates across both `otlp/jaeger` and `loki` exporters.

---

### 7.4 Edge Pipeline — COLLECTOR FOOTPRINT section

**Purpose:** Confirm the collector is not consuming significant resources or competing with the application.

#### Panel: OTel Collector Resource Footprint

| Property | Value |
|---|---|
| Type | Time series (dual Y-axis) |
| CPU query | `rate(otelcol_process_cpu_seconds_total[1m])` |
| CPU unit | Ratio (0.0–1.0 = 0–100% of one CPU core), left Y-axis |
| Memory query | `otelcol_process_memory_rss` |
| Memory unit | bytes (displayed as MiB), right Y-axis |

`otelcol_process_cpu_seconds_total` — counter of total CPU-seconds. `rate([1m])` gives the CPU fraction (0.1 = 10% of one core).

`otelcol_process_memory_rss` — Resident Set Size in bytes, as reported by the OS. This is the actual RAM in use, not the Go runtime's heap size.

Expected values: CPU ~1–5% (0.01–0.05 ratio), Memory ~80–150 MiB. During a link outage, memory may increase slightly as the retry_sender holds batches in its buffer (each batch ≤ 512 spans × a few KB each ≈ a few MB additional). The memory_limiter (400 MiB hard limit) prevents unbounded growth.

---

## 8. Design Decisions and Trade-offs

### 8.1 Tail-Based vs. Head-Based Sampling

**Head-based sampling** is simpler: a random decision at trace start, propagated in the W3C Trace Context `sampled` flag. No buffering, no state, minimal overhead.

**Why tail sampling here:** The demo application has two classes of traffic — fast successful sensor reads (~80%) and slow/error-prone requests (~20%). Head-based sampling cannot distinguish these at decision time. A 20% head-based rate would drop 80% of errors and slow requests — exactly the events that matter diagnostically.

Tail sampling waits for the trace to complete, then applies deterministic policies, guaranteeing 100% retention of all errors and slow requests with ~100% rejection of fast successes.

**Trade-offs of tail sampling:**
- Up to `decision_wait: 5s` delivery latency for traces (data reaches Jaeger 5s after request completes)
- All spans of a trace must reach the same collector instance (addressed by DaemonSet co-location)
- Higher memory: `num_traces: 10000` reserves capacity for 10,000 concurrent traces (~10–50 MB)
- Spans that arrive during collector restart are lost (not yet in bbolt)

For multi-service architectures, a gateway tier with consistent hash routing on `trace_id` is required. This demo uses the simpler single-node model.

### 8.2 `prometheusremotewrite` vs `otlphttp` for Metrics

The OTel Collector can export metrics to Prometheus via:
1. `prometheusremotewrite` — Prometheus remote-write protocol to `/api/v1/write`
2. `otlphttp` — OTLP format to Prometheus's `/api/v1/otlp/v1/metrics` endpoint

**Why `prometheusremotewrite` is used:**

Prometheus's OTLP endpoint rejects metrics with out-of-order timestamps (HTTP 400). After a link restore, the in-memory queue contains samples from the failure window (old timestamps). Prometheus returns HTTP 400 for each out-of-order sample, causing the exporter to retry indefinitely and eventually drop items — the queue never drains cleanly.

There is a Prometheus feature flag `--enable-feature=out-of-order-ingestion` paired with `--storage.tsdb.out-of-order-time-window`, but in the arm64 builds of Prometheus v2.49.1 used here, this flag is not consistently available across architectures.

The `prometheusremotewrite` exporter targets `/api/v1/write`. The remote-write endpoint silently skips out-of-order samples (HTTP 204 with 0 written). The queue drains without errors — at the cost of NOT filling the failure-window gap for metrics. This is the accepted trade-off: metric data from the outage period is lost, but the system does not get stuck.

**Implication for the demo:** After restore, Jaeger has failure-window traces ✅, Loki has failure-window logs ✅, Prometheus has a visible gap in metrics ❌ (expected, documented, and itself a teaching point about signal-type differences in resilience guarantees).

**Note:** `prometheusremotewrite` does not support `sending_queue.storage: file_storage` in OTel Collector v0.95. The metrics queue is in-memory only, so during a link outage, metrics are held in RAM (up to `queue_size` batches) and dropped if the outage exceeds `max_elapsed_time` (5 minutes). For the demo (2–3 min outage), no metrics are permanently lost — they resume after restore, just without the failure-window data.

### 8.3 DaemonSet vs. Deployment for the OTel Collector

A DaemonSet runs exactly one pod per matching node. A Deployment with `replicas: 1` runs one pod on a scheduler-determined node.

**Why DaemonSet:**
- Tail sampling requires all spans of a trace to reach the same instance. DaemonSet co-location with the app guarantees this.
- Application-to-collector spans are sent to `localhost:4317` (via the DaemonSet's `hostPort`), with no external network hop and no load balancer.
- If the app is scaled to N replicas across N nodes, a DaemonSet provides N collector instances automatically.
- Resource isolation: each node's collector is independent; a noisy node does not affect other nodes' collectors.

**Trade-off:** Cannot scale below 1 pod per node. The resource limits (128 MiB request, 512 MiB limit, 100m CPU request, 500m limit) must leave headroom for the application. Profile under peak load before production use.

### 8.4 Custom OTel Collector Build

`otelcol-contrib` ships 150+ components (~250 MB). This project builds a custom binary with exactly 9 components (~30 MB, 88% size reduction).

**Benefits:** Smaller attack surface, faster startup, fully auditable component set, no code for unused exporters/receivers.

**Trade-off:** Each change to the component list requires rebuilding and republishing the image. For prototyping, `otelcol-contrib` is fine. For production, a custom build is strongly recommended.

The image is distroless (no shell). This means `kubectl exec <collector-pod> -- ls` fails. The `network-chaos` DaemonSet mounts the file storage path as a workaround for local queue inspection.

### 8.5 iptables vs. NetworkPolicy for Network Simulation

Kubernetes `NetworkPolicy` requires CNI support (k3d's default Flannel does not enforce policies). NetworkPolicy also applies to all traffic to a pod, not specific ports.

`iptables` provides surgical, instant, reversible control: drop only OTLP gRPC (4317), Prometheus remote-write (9090), and Loki push (3100) from the collector pod IP, while leaving all other traffic unaffected.

**The conntrack problem:** Established TCP connections survive iptables DROP rules via the kernel's conntrack ESTABLISHED bypass. Without explicit conntrack flush, existing gRPC connections continue working even after DROP rules are inserted. The fix: `conntrack -D -s <collector-pod-ip>` after adding rules. This terminates existing connections, forcing the gRPC client to reconnect — and the new TCP SYN will be blocked.

**The dual-backend problem:** Modern kernels use `iptables-nft`; some k3s/k3d configurations use `iptables-legacy`. Rules in one backend are invisible to the other. The scripts apply rules to both backends simultaneously with `|| true` on each to silently skip missing backends:
```bash
iptables        -I FORWARD -s "$POD_IP" -p tcp --dport 4317 -j DROP 2>/dev/null || true
iptables-legacy -I FORWARD -s "$POD_IP" -p tcp --dport 4317 -j DROP 2>/dev/null || true
```

### 8.6 `num_consumers: 1` — Queue Visibility vs. Throughput

With `num_consumers: 4` (the default), 4 goroutines consume batches from bbolt in parallel. Items are claimed within milliseconds of being enqueued, even during link failures (the consumer goroutines hold items in the retry_sender's in-memory buffer). The `otelcol_exporter_queue_size` metric reflects only items waiting in bbolt — which is near 0 because items are claimed immediately.

With `num_consumers: 1`, only 1 goroutine consumes batches. While that goroutine is blocked in the retry loop (5s, 7.5s, … backoff), all new batches from the batch processor accumulate in bbolt. `queue_size` grows by ~1 every 5 seconds, producing the rising slope visible in Grafana.

**Impact on throughput:** At the demo's traffic rate (~0.3 batches/s post-sampling), a single consumer is more than sufficient under normal conditions. The recovery spike after restore lasts slightly longer (~5–15s vs ~1–3s with 4 consumers) but remains visually clear and delivers the same total data.

---

## 9. Network Failure Simulation

The network failure simulation models a satellite link outage at the IP layer using iptables in the `network-chaos` DaemonSet.

### How it works

`simulate-network-failure.sh`:

1. Gets the OTel Collector pod's IP and the network-chaos pod name
2. Inserts DROP rules in the FORWARD chain for ports 4317, 9090, and 3100, applied to both `iptables` and `iptables-legacy`
3. Flushes conntrack state to terminate existing connections
4. Saves the pod IP to `/tmp/otel-collector-pod-ip`

`restore-network.sh`:

1. Reads the pod IP from `/tmp/otel-collector-pod-ip`
2. Removes the same DROP rules from both backends

### Collector behavior during failure

After the rules take effect and conntrack is flushed:
- gRPC connections to Jaeger, Prometheus, and Loki fail
- `retry_sender` logs: `"Exporting failed. Will retry the request after interval."`
- New batches from the `batch` processor are written to the bbolt queue
- `otelcol_exporter_sent_spans` stops incrementing
- `otelcol_exporter_queue_size` rises (~1 batch every 5s)

### Collector behavior after restore

- The collector reconnects to all three backends
- `retry_sender` succeeds on its next attempt
- bbolt queue drains at maximum network throughput
- Export throughput spikes above baseline (queue drain burst)
- Jaeger: queued traces appear with original timestamps
- Loki: queued logs appear with original timestamps

---

## 10. Project Structure

```
observability-on-edge/
│
├── app/                                # Maritime vessel monitoring application
│   ├── main.go                        # HTTP server, OTel init, graceful shutdown
│   ├── handlers.go                    # Route handlers + tracing middleware
│   ├── telemetry.go                   # OTel SDK: TracerProvider, MeterProvider, Logger
│   ├── go.mod                         # Go 1.22, OTel SDK v1.24, zap v1.27
│   └── Dockerfile                     # Multi-stage build (~15MB final image)
│
├── k8s/                                # Base Kubernetes manifests
│   ├── kustomization.yaml
│   ├── namespace.yaml
│   ├── edge-node/
│   │   ├── app-deployment.yaml
│   │   ├── app-service.yaml
│   │   ├── otel-collector-daemonset.yaml
│   │   ├── otel-collector-config.yaml  # Tail sampling, file queues, retry
│   │   ├── otel-collector-service.yaml
│   │   ├── fluentbit-daemonset.yaml
│   │   ├── fluentbit-config.yaml       # CRI parser, Lua filter, OTLP HTTP output
│   │   └── network-chaos-daemonset.yaml
│   └── hub-node/
│       ├── jaeger-deployment.yaml
│       ├── jaeger-service.yaml
│       ├── prometheus-deployment.yaml
│       ├── prometheus-service.yaml
│       ├── prometheus-config.yaml      # 15s scrape, OTel + Fluent Bit targets
│       ├── loki-deployment.yaml
│       ├── loki-service.yaml
│       ├── loki-config.yaml            # unordered_writes: true
│       ├── grafana-deployment.yaml
│       ├── grafana-service.yaml
│       ├── grafana-config.yaml         # Data source provisioning
│       └── grafana-dashboards-configmap.yaml  # vessel-operations + edge-pipeline
│
├── overlays/                           # Kustomize environment patches
│   ├── local/                         # k3d: hostPath + NodePort
│   │   ├── kustomization.yaml
│   │   └── patches/
│   │       ├── otelcol-hostpath.yaml
│   │       ├── grafana-nodeport.yaml   # NodePort 30300
│   │       └── jaeger-nodeport.yaml    # NodePort 30686
│   └── civo/                          # Civo: PVC + LoadBalancer + ghcr.io image
│       ├── kustomization.yaml
│       ├── patches/
│       │   ├── otelcol-pvc.yaml
│       │   ├── app-deployment.yaml     # image → ghcr.io, pullPolicy → IfNotPresent
│       │   ├── grafana-lb.yaml
│       │   └── jaeger-lb.yaml
│       └── resources/
│           └── otelcol-pvc.yaml        # PVC: 1Gi, civo-volume StorageClass
│
├── load-tests/
│   └── k6-script.js                   # 40-min, 8 VU, 4-endpoint distribution
│
├── scripts/
│   ├── setup.sh                       # Cluster setup (--env local|civo)
│   ├── load-generator.sh              # Create k6 TestRun
│   ├── demo.sh                        # Orchestrated demo Acts 1–3
│   ├── simulate-network-failure.sh    # Insert iptables DROP rules
│   ├── restore-network.sh             # Remove iptables DROP rules
│   └── cleanup.sh                     # Delete cluster
│
├── .github/workflows/
│   └── build-app.yaml                 # Multi-arch image build + push on push to master/feat/**
│
├── README.md                          # This file
├── DEMO-LIVE.md                       # KubeCon live presentation script
└── architecture.mmd                   # Mermaid architecture diagram source
```

---

## 11. Troubleshooting

### Collector pods are CrashLooping

```bash
kubectl logs -n observability daemonset/otel-collector --previous
```

Common causes:
- **Configuration parse error:** Validate YAML syntax in `otel-collector-config.yaml`.
- **Memory limit exceeded:** Check for OOM events: `kubectl describe pod -n observability <collector-pod>`. Reduce traffic or increase `spec.containers[0].resources.limits.memory`.
- **File storage permission error:** The path `/var/lib/otelcol/file_storage` must be writable by the process (runs as root). On local k3d, `hostPath.type: DirectoryOrCreate` handles this automatically.

### `otelcol_exporter_queue_size` always shows 0

Check all three conditions:
1. `telemetry.metrics.level: detailed` is set in the collector config
2. `num_consumers: 1` is set for `otlp/jaeger` and `loki` exporters
3. The collector was restarted after the config change: `kubectl rollout restart daemonset/otel-collector -n observability`
4. A network failure simulation is currently active (run `simulate-network-failure.sh` first)

### Stale queue files causing export errors after demo reset

Old bbolt entries contain metric timestamps that Prometheus rejects as out-of-order. Symptoms: collector logs show HTTP 400 errors, "Permanent Data Drops" panel shows non-zero values.

```bash
CHAOS_POD=$(kubectl get pod -n observability -l app=network-chaos -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n observability "$CHAOS_POD" -- find /var/lib/otelcol/file_storage -type f -delete
kubectl rollout restart daemonset/otel-collector -n observability
```

### iptables rules not blocking traffic

Verify rules in both backends:
```bash
CHAOS_POD=$(kubectl get pod -n observability -l app=network-chaos -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n observability "$CHAOS_POD" -- sh -c \
  "iptables -L FORWARD -n 2>/dev/null; echo '---'; iptables-legacy -L FORWARD -n 2>/dev/null"
```

If rules are present but traffic still flows, conntrack was not flushed:
```bash
POD_IP=$(cat /tmp/otel-collector-pod-ip)
kubectl exec -n observability "$CHAOS_POD" -- conntrack -D -s "$POD_IP"
```

### Gap-fill not working for logs after restore

Verify Loki has `unordered_writes: true`:
```bash
kubectl exec -n observability deployment/loki -- grep unordered /etc/loki/loki.yaml
```

If missing, update `loki-config.yaml`, re-apply, and restart Loki:
```bash
kubectl rollout restart deployment/loki -n observability
```

### Civo: PVC stuck in `Pending`

The `civo-volume` StorageClass uses `WaitForFirstConsumer` binding mode. The PVC binds to a node only when a pod is scheduled. This resolves automatically once the DaemonSet pod is placed. `setup.sh` polls for PVC `Bound` status before proceeding.

```bash
kubectl describe pvc otelcol-file-storage -n observability
```

### Civo: node count stuck at 0 during setup

Civo marks a cluster ACTIVE before nodes register in the Kubernetes API. `setup.sh` includes a polling loop that waits until `kubectl get nodes` returns at least 2 nodes. If the wait times out, check the Civo dashboard for cluster status.

---

## 12. References

**OpenTelemetry:**
- [OTel Collector Configuration Reference](https://opentelemetry.io/docs/collector/configuration/)
- [Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)
- [File Storage Extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/storage/filestorage)
- [OTel Collector Builder (ocb)](https://github.com/open-telemetry/opentelemetry-collector/tree/main/cmd/builder)
- [Prometheus Remote Write Exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusremotewriteexporter)
- [Loki Exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/lokiexporter)
- [OTel Go SDK](https://pkg.go.dev/go.opentelemetry.io/otel)

**Fluent Bit:**
- [Fluent Bit OpenTelemetry Output Plugin](https://docs.fluentbit.io/manual/pipeline/outputs/opentelemetry)
- [Fluent Bit Lua Filter](https://docs.fluentbit.io/manual/pipeline/filters/lua)
- [Fluent Bit Prometheus Monitoring](https://docs.fluentbit.io/manual/administration/monitoring)

**Loki:**
- [Loki Limits Configuration (`unordered_writes`)](https://grafana.com/docs/loki/latest/configure/#limits_config)
- [Loki Storage Schema](https://grafana.com/docs/loki/latest/storage/schema/)

**Prometheus:**
- [Remote Write Protocol Specification](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write)
- [PromQL Rate and Increase Functions](https://prometheus.io/docs/prometheus/latest/querying/functions/)
- [Histograms and Summaries Best Practices](https://prometheus.io/docs/practices/histograms/)

**Infrastructure:**
- [k3d Documentation](https://k3d.io/v5.6.0/)
- [Kustomize Documentation](https://kustomize.io/)
- [k6 Operator](https://grafana.com/docs/k6/latest/set-up/kubernetes-operator/)
- [bbolt (BoltDB) — embedded key-value store](https://github.com/etcd-io/bbolt)
- [nicolaka/netshoot](https://github.com/nicolaka/netshoot)

**Background Reading:**
- [Google SRE Book: Monitoring Distributed Systems](https://sre.google/sre-book/monitoring-distributed-systems/)
- [OpenTelemetry Concepts](https://opentelemetry.io/docs/concepts/)
- [Cindy Sridharan: Distributed Systems Observability](https://www.oreilly.com/library/view/distributed-systems-observability/9781492033431/)
