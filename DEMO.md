# Edge Observability Solution - Demo Guide

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Component Details](#component-details)
4. [Telemetry Data Flow](#telemetry-data-flow)
5. [Sampling Strategy](#sampling-strategy)
6. [Network Resilience](#network-resilience)
7. [Running the Demo](#running-the-demo)
8. [Demo Scenarios](#demo-scenarios)
9. [Dashboard Guide](#dashboard-guide)
10. [Troubleshooting](#troubleshooting)

---

## Overview

This demo showcases a production-realistic observability solution for edge computing environments. It addresses the key challenges of edge observability:

- **Limited Bandwidth**: Intelligent sampling reduces data transfer by ~80-90%
- **Intermittent Connectivity**: Persistent queues prevent data loss during network outages
- **Resource Constraints**: Lightweight collectors optimized for edge devices
- **Full Correlation**: Seamless navigation between metrics, logs, and traces

### Key Technologies

- **Application**: Go microservice with OpenTelemetry instrumentation
- **Telemetry Collection**: OpenTelemetry Collector (tail-based sampling) + Fluent Bit
- **Storage**: Prometheus (metrics), Loki (logs), Jaeger (traces)
- **Visualization**: Grafana with pre-configured dashboards
- **Infrastructure**: k3s (lightweight Kubernetes) on k3d

---

## Architecture

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         EDGE NODE                               │
│  ┌──────────────┐    ┌─────────────────┐    ┌──────────────┐  │
│  │              │    │                 │    │              │  │
│  │  Demo App    │───▶│ OTel Collector  │    │  Fluent Bit  │  │
│  │  (Go + OTel) │    │                 │◀───│              │  │
│  │              │    │ • Tail Sampling │    │              │  │
│  └──────────────┘    │ • File Queues   │    └──────────────┘  │
│         │            │ • Batching      │            │          │
│         │            └────────┬────────┘            │          │
│         │                     │                     │          │
│         └─────────────────────┴─────────────────────┘          │
│                               │                                 │
│                      Network (can fail)                         │
│                               │                                 │
└───────────────────────────────┼─────────────────────────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                          HUB NODE                               │
│                                                                 │
│  ┌─────────┐      ┌────────────┐      ┌──────┐      ┌──────┐  │
│  │         │      │            │      │      │      │      │  │
│  │ Grafana │◀─────│ Prometheus │      │ Loki │      │Jaeger│  │
│  │         │      │            │      │      │      │      │  │
│  └─────────┘      └────────────┘      └──────┘      └──────┘  │
│       │                  ▲                 ▲            ▲       │
│       │                  │                 │            │       │
│       └──────────────────┴─────────────────┴────────────┘       │
│                    Query & Visualize                            │
└─────────────────────────────────────────────────────────────────┘
```

### Node Distribution

The demo uses a 2-node k3s cluster with workload isolation:

**Edge Node** (node-role=edge):
- `edge-demo-app` - Application deployment
- `otel-collector` - Telemetry collection and sampling
- `fluent-bit` - Log collection (DaemonSet)

**Hub Node** (node-role=hub):
- `jaeger` - Distributed tracing backend
- `prometheus` - Metrics storage and querying
- `loki` - Log aggregation
- `grafana` - Unified visualization

This separation simulates a real edge deployment where the application and collectors run on edge hardware, while heavy storage/query backends run in a centralized location.

---

## Component Details

### 1. Edge Demo Application

**Purpose**: Generate realistic telemetry data (metrics, logs, traces)

**Technology**: Go 1.22 with OpenTelemetry SDK

**Endpoints**:
- `GET /api/users` - Fast response (~50ms) - simulates user listing
- `GET /api/products` - Medium latency (~150ms) - simulates product catalog
- `GET /api/orders` - Variable latency (300-1500ms) - simulates database queries
- `GET /api/checkout` - Error-prone (20% failure rate) - simulates payment processing
- `GET /health` - Health check

**Telemetry Generated**:

1. **Traces**:
   - Parent span for HTTP request
   - Child spans for business logic (fetch-users, fetch-products, etc.)
   - Span attributes: http.method, http.url, http.status_code
   - Error status and error messages for failures

2. **Metrics**:
   - `http.server.request.count` - Request counter by endpoint and status
   - `http.server.request.duration` - Latency histogram
   - `business.orders.count` - Business metric for order processing

3. **Logs**:
   - Structured JSON logs with fields:
     - `timestamp` - ISO8601 format
     - `level` - log level (info, warn, error)
     - `msg` - log message
     - `trace_id` - trace ID for correlation
     - `span_id` - span ID
     - Additional context fields

**Configuration**:
```yaml
env:
  - OTEL_EXPORTER_OTLP_ENDPOINT: otel-collector.observability.svc.cluster.local:4317
  - OTEL_SERVICE_NAME: edge-demo-app
```

### 2. OpenTelemetry Collector

**Purpose**: Intelligent telemetry collection, sampling, and forwarding with network resilience

**Image**: `otel/opentelemetry-collector-contrib:0.95.0`

**Key Features**:

1. **Tail-Based Sampling** - Smart decision making:
   - Waits for complete trace before sampling decision
   - Multiple policies evaluated in order:
     - **Error Policy**: Keep ALL traces with errors (status_code=ERROR)
     - **Latency Policy**: Keep traces slower than 200ms
     - **Probabilistic Policy**: Sample 10% of remaining traces
   - Expected data reduction: 80-90%

2. **Persistent File Queues**:
   - All exporters use file-backed queues
   - Queue directory: `/var/lib/otelcol/file_storage`
   - Survives collector restarts
   - Automatic compaction and cleanup
   - Queue size: 1000 items per exporter

3. **Receivers**:
   - OTLP gRPC (port 4317) - receives from application
   - OTLP HTTP (port 4318) - receives from Fluent Bit
   - Prometheus (port 8888) - self-monitoring

4. **Processors**:
   - `memory_limiter` - Prevents OOM (512MB limit)
   - `batch` - Batches data for efficiency
   - `resource` - Adds resource attributes (cluster, environment)
   - `tail_sampling` - Intelligent trace sampling

5. **Exporters**:
   - `otlp/jaeger` - Sends traces to Jaeger
   - `prometheusremotewrite` - Sends metrics to Prometheus
   - `loki` - Sends logs to Loki
   - All with retry logic and persistent queues

**Resource Limits**:
```yaml
requests:
  memory: 256Mi
  cpu: 200m
limits:
  memory: 1Gi
  cpu: 1000m
```

### 3. Fluent Bit

**Purpose**: Lightweight log collection and forwarding

**Image**: `fluent/fluent-bit:2.2`

**Configuration**:

1. **Input**:
   - Tails application logs: `/var/log/app/*.log`
   - JSON parser extracts structured fields
   - Filesystem storage for buffering

2. **Filters**:
   - Add resource labels (cluster, namespace, deployment)
   - Preserve trace_id for correlation

3. **Output**:
   - Sends to OTel Collector via OTLP HTTP
   - Filesystem buffering (50MB limit)
   - Automatic retries

**Why Fluent Bit**:
- Lightweight: ~450KB memory footprint
- Fast: Written in C
- Cloud-native: Kubernetes-ready
- Flexible: Many input/output plugins

### 4. Jaeger

**Purpose**: Distributed tracing backend and UI

**Image**: `jaegertracing/all-in-one:1.54`

**Configuration**:
- All-in-one deployment (collector + query + UI)
- OTLP receiver enabled (port 4317)
- Badger storage backend (embedded database)
- Storage directory: `/badger`

**Features**:
- Trace search by service, operation, tags
- Trace timeline visualization
- Service dependency graph
- Performance analysis

### 5. Prometheus

**Purpose**: Metrics storage and querying

**Image**: `prom/prometheus:v2.49.1`

**Configuration**:
- Remote write receiver enabled
- Exemplar storage enabled (for trace correlation)
- Retention: 7 days
- Scrape targets:
  - OTel Collector self-metrics (8888)
  - Fluent Bit metrics (2020)

**Key Features**:
- PromQL query language
- Time-series database
- Alerting support (not configured in demo)
- Exemplars link to traces

### 6. Loki

**Purpose**: Log aggregation and querying

**Image**: `grafana/loki:2.9.4`

**Configuration**:
- Single binary mode
- Filesystem storage
- Schema v13 (TSDB)
- Retention: 7 days

**Stream Labels**:
```
{app="edge-demo-app", namespace="observability", deployment="edge-demo-app"}
```

**Features**:
- LogQL query language (similar to PromQL)
- Label-based indexing
- Efficient compression
- Derived fields for trace correlation

### 7. Grafana

**Purpose**: Unified visualization and exploration

**Image**: `grafana/grafana:10.3.3`

**Pre-configured**:
- 3 datasources (Prometheus, Loki, Jaeger)
- 2 dashboards (Application, Monitoring Health)
- Correlation configured:
  - Logs → Traces (via trace_id)
  - Metrics → Traces (via exemplars)
  - Traces → Logs (via trace_id)

**Access**:
- URL: http://localhost:30300
- Username: `admin`
- Password: `admin`

---

## Telemetry Data Flow

### Traces Flow

```
Application
    │
    │ OTLP/gRPC (4317)
    ▼
OTel Collector
    │
    │ Receives all traces
    │ Buffers for tail-sampling decision (10s wait)
    │
    ├─ Error trace? ────────────────────────▶ Keep (100%)
    ├─ Latency > 200ms? ───────────────────▶ Keep (100%)
    ├─ Probabilistic sample (10%)? ────────▶ Keep (10%)
    └─ Drop ───────────────────────────────▶ Drop (90% of fast)
    │
    │ OTLP/gRPC (4317)
    │ Persistent queue if network down
    ▼
Jaeger
    │
    │ Store in Badger DB
    ▼
Grafana queries Jaeger
```

**Key Points**:
- Tail-based sampling waits for complete trace
- Decision based on complete trace characteristics
- ~80-90% data reduction while keeping important traces
- Queue prevents data loss during network issues

### Metrics Flow

```
Application
    │
    │ OTLP/gRPC (4317)
    │ Includes exemplars (trace_id references)
    ▼
OTel Collector
    │
    │ Batching (10s or 1024 points)
    │ Add resource attributes
    │
    │ Prometheus Remote Write
    │ Persistent queue if network down
    ▼
Prometheus
    │
    │ Store as time-series
    │ Keep exemplars for correlation
    ▼
Grafana queries Prometheus
```

**Key Points**:
- All metrics sent (no sampling)
- Exemplars link metrics to traces
- Batching reduces network overhead
- Queue prevents data loss

### Logs Flow

```
Application
    │
    │ Write to stdout/file
    │ JSON format with trace_id
    ▼
Fluent Bit
    │
    │ Tail log files
    │ Parse JSON
    │ Add resource labels
    │
    │ OTLP/HTTP (4318)
    │ Filesystem buffer
    ▼
OTel Collector
    │
    │ Batching
    │ Add resource attributes
    │
    │ Loki HTTP API
    │ Persistent queue if network down
    ▼
Loki
    │
    │ Index by labels
    │ Store compressed chunks
    ▼
Grafana queries Loki
```

**Key Points**:
- Fluent Bit adds buffering layer
- Trace_id preserved for correlation
- All logs sent (no sampling)
- Two-level queuing (Fluent Bit + OTel)

---

## Sampling Strategy

### Why Tail-Based Sampling?

**Head-based sampling** (decision at trace start):
- ❌ Can't know if trace will be slow or error
- ❌ May drop important traces
- ✅ Low latency, simple

**Tail-based sampling** (decision after trace completes):
- ✅ Sees complete trace before deciding
- ✅ Can keep all errors and slow traces
- ✅ Intelligent data reduction
- ⚠️ Requires buffering (10s wait)

### Sampling Policies

Policies are evaluated in order. First matching policy wins.

```yaml
policies:
  # 1. Keep ALL error traces
  - name: error-policy
    type: status_code
    status_code:
      status_codes: [ERROR]

  # 2. Keep traces slower than 200ms
  - name: latency-policy
    type: latency
    latency:
      threshold_ms: 200

  # 3. Sample 10% of remaining (fast, successful)
  - name: probabilistic-policy
    type: probabilistic
    probabilistic:
      sampling_percentage: 10
```

### Expected Sampling Results

With realistic traffic:
- `/api/users` (fast, ~50ms): ~10% sampled
- `/api/products` (medium, ~150ms): ~10% sampled
- `/api/orders` (slow, 300-1500ms): 100% sampled (latency policy)
- `/api/checkout` (20% errors): 100% errors sampled + ~10% successes

**Overall**: ~80-90% data reduction while keeping all important traces

### Benefits

1. **Bandwidth Savings**: 10x reduction in trace data transferred
2. **Cost Savings**: Less storage, less compute for trace backend
3. **Focus on Issues**: All errors and slow requests captured
4. **Representative Sample**: 10% sample of normal requests for baselines

---

## Network Resilience

### The Challenge

Edge devices face intermittent connectivity:
- Network outages
- Bandwidth limitations
- Unreliable connections
- Geographic isolation

**Critical Requirement**: Don't lose observability data during outages!

### Solution: Persistent File Queues

The OTel Collector uses file-backed queues for all exporters:

```yaml
extensions:
  file_storage:
    directory: /var/lib/otelcol/file_storage
    timeout: 10s
    compaction:
      on_start: true
      on_rebound: true

exporters:
  otlp/jaeger:
    sending_queue:
      enabled: true
      storage: file_storage  # ← Persistent queue
      queue_size: 1000
    retry_on_failure:
      enabled: true
      max_interval: 30s
```

### How It Works

**Normal Operation**:
1. Collector receives telemetry
2. Processes and batches data
3. Sends to backends immediately
4. Queue remains small (~0-10 items)

**Network Failure**:
1. Collector receives telemetry (continues working!)
2. Processes and batches data
3. Attempts to send → fails
4. Writes to persistent file queue
5. Queue grows as data accumulates
6. Retries with exponential backoff

**Network Recovery**:
1. Export retry succeeds
2. Queue begins draining
3. Data sent in order (FIFO)
4. Queue size decreases
5. Eventually returns to normal

### Queue Monitoring

Monitor queue health in "Monitoring System Health" dashboard:

- **Queue Size**: Number of items waiting to send
- **Export Failures**: Failed send attempts
- **Export Retries**: Retry attempts

**Healthy**: Queue size < 100
**Warning**: Queue size 100-500 (minor network issues)
**Critical**: Queue size > 500 (prolonged outage)

### Queue Capacity

Each exporter queue:
- Max items: 1000
- Storage: File system (1GB emptyDir)
- Compaction: Automatic cleanup

**Capacity planning**:
- At 100 spans/sec: ~10 seconds of data
- At 1000 spans/sec: ~1 second of data
- Adjust queue_size and storage based on expected outage duration

---

## Running the Demo

### Prerequisites

Install required tools:

```bash
# macOS
brew install docker k3d kubectl k6

# Linux (Ubuntu/Debian)
# Docker: https://docs.docker.com/engine/install/
# k3d: curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
# kubectl: https://kubernetes.io/docs/tasks/tools/
# k6: https://k6.io/docs/getting-started/installation/

# Windows
choco install docker-desktop k3d kubernetes-cli k6
```

### Setup (First Time)

Run the automated setup script:

```bash
./scripts/setup.sh
```

This script will:
1. ✓ Check prerequisites
2. ✓ Build application Docker image
3. ✓ Create k3d cluster (2 nodes)
4. ✓ Label nodes (edge/hub)
5. ✓ Deploy hub components (Jaeger, Prometheus, Loki, Grafana)
6. ✓ Deploy edge components (App, OTel Collector, Fluent Bit)
7. ✓ Wait for all pods to be ready
8. ✓ Display access information

**Expected time**: 3-5 minutes

### Access Services

**Grafana** (always available):
```
URL: http://localhost:30300
Username: admin
Password: admin
```

**Jaeger** (port-forward required):
```bash
kubectl port-forward -n observability svc/jaeger 16686:16686
# Then open: http://localhost:16686
```

**Prometheus** (port-forward required):
```bash
kubectl port-forward -n observability svc/prometheus 9090:9090
# Then open: http://localhost:9090
```

### Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n observability -o wide

# Expected output:
# NAME                              READY   STATUS    NODE
# edge-demo-app-xxx                 1/1     Running   edge-node
# otel-collector-xxx                1/1     Running   edge-node
# fluent-bit-xxx                    1/1     Running   edge-node
# jaeger-xxx                        1/1     Running   hub-node
# prometheus-xxx                    1/1     Running   hub-node
# loki-xxx                          1/1     Running   hub-node
# grafana-xxx                       1/1     Running   hub-node
```

---

## Demo Scenarios

### Scenario 1: Normal Operation

**Goal**: See the system working under normal conditions

1. **Generate load**:
   ```bash
   ./scripts/load-generator.sh
   ```
   This runs a 9-minute k6 load test with realistic traffic patterns.

2. **Open Grafana**: http://localhost:30300

3. **Explore Application Observability Dashboard**:
   - Request rate increasing during load test
   - Error rate ~20% (from /api/checkout endpoint)
   - P95 latency showing slow requests
   - Logs showing errors and warnings
   - Metrics by endpoint

4. **Explore Monitoring System Health Dashboard**:
   - OTel Collector CPU/Memory usage
   - Spans/Metrics/Logs flow (received vs exported)
   - Sampling decisions (see traces being dropped)
   - Queue size (should be near 0)

5. **Check Jaeger**:
   ```bash
   kubectl port-forward -n observability svc/jaeger 16686:16686
   ```
   - Open http://localhost:16686
   - Search for traces from "edge-demo-app"
   - Notice: Only slow and error traces (sampling working!)
   - Click a trace to see spans

6. **Correlation in action**:
   - In Grafana logs panel, click on a trace_id
   - Should open Jaeger with that trace
   - In Jaeger, click "Logs for this span"
   - Should show relevant logs in Loki

### Scenario 2: Network Failure & Recovery

**Goal**: Demonstrate resilience to network outages

1. **Start load generation** (in a separate terminal):
   ```bash
   ./scripts/load-generator.sh
   ```

2. **Monitor queue status** (in another terminal):
   ```bash
   watch -n 2 'kubectl exec -n observability deployment/otel-collector -- wget -qO- http://localhost:8888/metrics | grep otelcol_exporter_queue_size'
   ```

3. **Simulate network failure**:
   ```bash
   ./scripts/simulate-network-failure.sh
   ```
   This applies a NetworkPolicy blocking edge→hub traffic.

4. **Observe**:
   - Load test continues (application still works!)
   - Queue size grows (data being queued)
   - In Grafana "Monitoring Health" dashboard:
     - "Export Queue Size" panel shows growth
     - Export failures increasing
   - In "Application Observability" dashboard:
     - Metrics/logs/traces stop updating (can't reach hub)

5. **Wait 30-60 seconds** (let queue build up)

6. **Restore network**:
   ```bash
   ./scripts/restore-network.sh
   ```

7. **Observe recovery**:
   - Queue drains rapidly
   - Dashboards start updating again
   - All queued data appears (no data loss!)
   - Check for continuity in graphs

### Scenario 3: Sampling Analysis

**Goal**: Understand how tail-based sampling works

1. **Generate controlled traffic**:
   ```bash
   # In a loop, hit different endpoints
   for i in {1..20}; do
     curl http://localhost:8080/api/users    # Fast
     curl http://localhost:8080/api/products # Medium
     curl http://localhost:8080/api/orders   # Slow
     curl http://localhost:8080/api/checkout # Errors
     sleep 1
   done
   ```

2. **Check Jaeger**:
   - Count traces for each endpoint
   - `/api/orders`: Most/all traces (slow, >200ms)
   - `/api/checkout`: All error traces + some successes
   - `/api/users`: Few traces (~10% sampling)
   - `/api/products`: Few traces (~10% sampling)

3. **Check Monitoring Health Dashboard**:
   - "Sampling Decisions by Policy" panel
   - See breakdown:
     - Error policy (red errors)
     - Latency policy (slow requests)
     - Probabilistic policy (10% sample)
   - "Trace Data Reduction %" gauge
   - Should show 80-90% reduction

### Scenario 4: End-to-End Trace Correlation

**Goal**: Follow a single request through all telemetry systems

1. **Make a failing checkout request**:
   ```bash
   curl -v http://localhost:8080/api/checkout
   ```
   Keep trying until you get a 500 error (20% chance).

2. **Copy the trace_id from the response body**.

3. **Find in Jaeger**:
   - Open Jaeger UI
   - Search for the trace_id
   - Examine the trace timeline
   - Note the error status

4. **Find in Loki logs**:
   - In Grafana, open Application Observability dashboard
   - In logs panel, filter: `{app="edge-demo-app"} | json | trace_id="<YOUR_TRACE_ID>"`
   - See the error log entry

5. **Find in Prometheus metrics**:
   - Query: `http_server_request_count_total{http_route="/api/checkout", http_status_code="500"}`
   - Click on an exemplar (if available)
   - Should link to the trace in Jaeger

---

## Dashboard Guide

### Dashboard 1: Application Observability

**Purpose**: Monitor application health and behavior

**Panels**:

1. **Request Rate** (Stat)
   - Current requests per second
   - Query: `rate(http_server_request_count_total[5m])`

2. **Error Rate** (Stat)
   - Percentage of failed requests
   - Query: `rate(http_server_request_count_total{http_status_code=~"5.."}[5m]) / rate(http_server_request_count_total[5m])`
   - Thresholds: Green (<1%), Yellow (<5%), Red (>5%)

3. **Request Latency** (Time series)
   - P50, P95, P99 latencies
   - Shows distribution of response times
   - Useful for spotting slow queries

4. **Request Rate by Endpoint** (Time series)
   - Traffic distribution across endpoints
   - Identify hot endpoints

5. **Error Count by Endpoint** (Time series)
   - Which endpoints are failing
   - Stacked area chart

6. **Application Logs (Errors)** (Logs)
   - Recent error logs
   - Filtered to errors only
   - Click trace_id to jump to Jaeger

7. **Business Metrics - Orders Rate** (Time series)
   - Custom business metric
   - Orders processed per second

8. **Recent Application Logs (All)** (Logs)
   - All log levels
   - Full context

**How to use**:
- Start here for application issues
- Check error rate and latency
- Drill into logs for details
- Click trace_id to see distributed trace

### Dashboard 2: Monitoring System Health

**Purpose**: Monitor the observability stack itself

**Sections**:

**Resource Usage**:
1. **CPU Usage** (Time series)
   - OTel Collector CPU
   - Fluent Bit CPU (approximated)

2. **Memory Usage** (Time series)
   - OTel Collector memory
   - Watch for memory leaks

**OTel Collector Metrics**:
3. **Spans Flow** (Time series)
   - Received spans/sec
   - Exported spans/sec
   - Gap = sampled out

4. **Metrics Flow** (Time series)
   - Received metrics/sec
   - Exported metrics/sec
   - Should be equal (no sampling)

5. **Logs Flow** (Time series)
   - Received logs/sec
   - Exported logs/sec
   - Should be equal (no sampling)

6. **Export Queue Size** (Time series)
   - Critical for network resilience
   - Normal: <100
   - Alert: >500

**Sampling Performance**:
7. **Sampling Decisions by Policy** (Time series)
   - Breakdown by policy (error, latency, probabilistic)
   - Stacked area shows composition

8. **Trace Data Reduction %** (Gauge)
   - Percentage of traces dropped
   - Expected: 80-90%

**Fluent Bit Metrics**:
9. **Records Processed** (Time series)
   - Log records/sec
   - Should match application log rate

10. **Errors & Retries** (Time series)
    - Output errors
    - Output retries
    - Indicates connectivity issues

**How to use**:
- Monitor during network failure scenario
- Watch queue size grow during outage
- Verify sampling is working (80-90% reduction)
- Check for resource issues (CPU/memory)

---

## Troubleshooting

### Pods not starting

**Symptom**: Pods stuck in `Pending` or `ImagePullBackOff`

**Solutions**:
```bash
# Check pod status
kubectl get pods -n observability

# Describe pod for details
kubectl describe pod <POD_NAME> -n observability

# Check events
kubectl get events -n observability --sort-by='.lastTimestamp'

# Common fixes:
# 1. Image not imported
k3d image import edge-demo-app:latest -c edge-observability

# 2. Node labels missing
kubectl label node k3d-edge-observability-agent-0 node-role=edge --overwrite
kubectl label node k3d-edge-observability-agent-1 node-role=hub --overwrite
```

### OTel Collector crashing

**Symptom**: OTel Collector pod restarting

**Solutions**:
```bash
# Check logs
kubectl logs -n observability deployment/otel-collector

# Common issues:
# 1. Invalid config - check syntax
kubectl get configmap otel-collector-config -n observability -o yaml

# 2. Memory limit - increase if needed
# Edit: k8s/edge-node/otel-collector-deployment.yaml
```

### No data in Grafana

**Symptom**: Dashboards show "No data"

**Solutions**:
```bash
# 1. Check datasources in Grafana
#    Settings → Data Sources → Test

# 2. Verify backends are running
kubectl get pods -n observability | grep -E "jaeger|prometheus|loki"

# 3. Check OTel Collector is sending data
kubectl logs -n observability deployment/otel-collector | grep "export"

# 4. Check network connectivity
kubectl exec -n observability deployment/otel-collector -- wget -O- http://prometheus:9090/-/healthy
```

### Load test fails

**Symptom**: k6 can't connect to application

**Solutions**:
```bash
# 1. Verify port-forward is running
lsof -i :8080

# 2. Check application is running
kubectl get pods -n observability -l app=edge-demo-app

# 3. Test directly
kubectl exec -n observability deployment/edge-demo-app -- wget -O- http://localhost:8080/health

# 4. Restart port-forward
kubectl port-forward -n observability svc/edge-demo-app 8080:8080
```

### Network policy not working

**Symptom**: Queue doesn't grow during network failure

**Solutions**:
```bash
# 1. Check NetworkPolicy exists
kubectl get networkpolicy -n observability

# 2. Verify Calico/CNI supports NetworkPolicy
kubectl get pods -n kube-system | grep -i network

# 3. Test connectivity manually
kubectl exec -n observability deployment/otel-collector -- wget -O- http://jaeger:16686 --timeout=5

# Should timeout during network failure
```

### Dashboard panels empty

**Symptom**: Some dashboard panels show "No data"

**Solutions**:
- Wait 1-2 minutes after deployment (metrics need time to accumulate)
- Check time range (top-right) is set to "Last 1 hour"
- Verify data source is correct (Prometheus/Loki/Jaeger)
- Check query syntax (edit panel → view query)

### Cleanup issues

**Symptom**: Cluster won't delete

**Solutions**:
```bash
# Force delete
k3d cluster delete edge-observability --all

# If still stuck, stop Docker and try again
docker ps -a | grep k3d | awk '{print $1}' | xargs docker rm -f
```

---

## Architecture Decisions

### Why k3d over kind/minikube?
- ✓ Fast startup (~30 seconds)
- ✓ Easy multi-node setup
- ✓ Built on k3s (production-grade)
- ✓ Great for demos

### Why tail-based sampling?
- ✓ More intelligent than head-based
- ✓ Keeps all important traces
- ✓ Significant data reduction
- ⚠️ Requires buffering (10s latency)

### Why Fluent Bit over Fluentd?
- ✓ Lightweight (C vs Ruby)
- ✓ Lower memory footprint
- ✓ Better for edge/resource-constrained environments
- ✓ Native Kubernetes support

### Why file storage over memory queues?
- ✓ Survives collector restarts
- ✓ Handles longer outages
- ✓ More reliable for edge
- ⚠️ Slightly slower (disk I/O)

---

## Additional Resources

### Documentation
- [OpenTelemetry Docs](https://opentelemetry.io/docs/)
- [OTel Collector Configuration](https://opentelemetry.io/docs/collector/configuration/)
- [Fluent Bit Documentation](https://docs.fluentbit.io/)
- [Grafana Docs](https://grafana.com/docs/grafana/latest/)

### Extending the Demo
- Add more endpoints to the application
- Implement custom sampling policies
- Add alerting rules to Prometheus
- Deploy on real edge hardware (Raspberry Pi, etc.)
- Add service mesh (Istio, Linkerd)
- Implement anomaly detection

### Production Considerations
- Use PersistentVolumes instead of emptyDir
- Configure authentication/authorization
- Set up TLS for all communication
- Implement proper secrets management
- Add high availability for backends
- Configure retention policies
- Set up alerting and incident response

---

**Questions or Issues?**

Open an issue on GitHub or contact the maintainers.

**Happy Observing! 🔭**
