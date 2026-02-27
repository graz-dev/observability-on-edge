# Akamas — OTel Collector Footprint Optimisation

This folder contains everything needed to run an **Akamas optimisation study** on the OpenTelemetry Collector running on the edge cluster.

**Goal:** minimise the collector's RSS memory and CPU consumption while preserving zero data loss across all three signals (traces, logs, metrics).

---

## Context

The collector runs as a DaemonSet on the edge node (Civo K3s, `node-role=edge`) and manages three pipelines:

- **Traces** → tail-sampling → Jaeger (OTLP gRPC, file-backed queue)
- **Metrics** → Prometheus remote-write (native WAL)
- **Logs** → Loki OTLP HTTP (file-backed queue)

On edge hardware, memory and CPU are constrained resources. Manually tuning nine parameters spread across YAML configuration and Go environment variables requires a prohibitive number of experiments. Akamas replaces manual search with a Bayesian optimiser (SOBOL) that explores the space efficiently.

---

## Setup architecture

```
Akamas server (EKS, :9000 via port-forward)
      │
      │ SSH ──────────────────────────────────────────────────────────┐
      │                                                               │
      │                                            akamas-runner pod  │
      │                                            (Civo, hub node)   │
      │                                               │               │
      │                                               │ kubectl       │
      │                                               │ (in-cluster)  │
      │                                               ▼               │
      │                                   applies collector ConfigMap  │
      │                                   patches DaemonSet env vars  │
      │                                   rollout restart + wait      │
      │                                   creates k6 TestRun + waits  │
      │                                                               │
      │ Prometheus scrape ─────────────────────────────────────────────
      │      http://<PROMETHEUS_LB_IP>:9090
      └───────────────────────────────────────────────────────────────
```

Per-experiment flow (≈ 11 min):
1. Akamas picks a set of parameter values
2. Executor SSH → `apply-config.sh` → applies the config and restarts the collector
3. Executor SSH → `run-workload.sh` → creates a k6 TestRun and waits for completion
4. Akamas reads metrics from Prometheus over the steady-state window (8 min)
5. The optimiser updates its model and picks the next parameter set

---

## k6 optimisation workload

### Design rationale

The optimisation workload is intentionally heavier than the demo test. The key constraint is the tail-sampler LRU map (`tail_num_traces`, range 1 000–20 000): to put traces into the map, the collector must receive them faster than it can decide on them.

```
needed rate = tail_num_traces / decision_wait
           = 1 000 / 5 s = 200 traces/s   (lower bound of the range)
```

At the demo load (8 VUs, sleep 0.5–2.5 s) the app generates ~5 traces/s → only ~25 in flight. The parameter would be invisible to the optimiser. At 100 VUs with fast-endpoint sleep reduced to 0.1–0.5 s the app generates ~255 traces/s → ~1 275 in flight at default `decision_wait`, which covers the meaningful part of the range.

### Test structure

```
 0:00  ──  0:30   ramp-up   0 → 20 VU  (cluster warm-up)
 0:30  ──  1:00   ramp-up  20 → 50 VU  (intermediate ramp)
 1:00  ──  2:00   ramp-up  50 → 100 VU (full load)
 2:00  ── 12:00   steady  100 VU        ← Prometheus measurement window (10 min)
12:00  ── 12:30   ramp-down 100 → 0 VU
```

**Total: ~12.5 min workload + ~90 s collector restart = ~14 min/experiment.**
With 60 experiments the full study takes approximately 14 hours.

| Aspect | Demo (`k6-script.js`) | Optimisation (`k6-optimization.js`) |
|--------|-----------------------|-------------------------------------|
| Peak VUs | 8 | **100** |
| Ramp-up | 30 s → 5 VU, then 39 min → 8 VU | 30 s → 20, 30 s → 50, 1 m → 100 |
| Steady-state | 39 min | **10 min** |
| Traffic mix | 50 % engine / 30 % nav / 12 % diag / 8 % alerts | identical |
| Fast-endpoint sleep | 0.5–2.5 s | **0.1–0.5 s** (rapid sensor polling) |
| Diagnostics sleep | 2–7 s | identical |
| Per-endpoint check thresholds | yes | identical |
| k6 metrics (`slowDiagnostics`, `latency`) | yes | identical |

### What it exercises

- **`tail_num_traces` and `tail_decision_wait_s`**: ~255 traces/s at peak → ~1 275 traces in flight at default `decision_wait=5s`. Reducing `decision_wait` to 2 s increases in-flight count to ~510; increasing `tail_num_traces` past the actual in-flight count has no memory effect. The optimiser can distinguish meaningful values across the full range.
- **Go GC** (`gogc`, `gomemlimit_mib`): higher allocation rate from 100 VUs makes GC cycles more frequent and the RSS signal more pronounced — easier for the optimiser to distinguish configurations.
- **Batch processor** (`batch_timeout_s`, `batch_send_size`): at ~255 items/s the batch fills faster; the interaction between timeout and batch size becomes more visible.
- **Memory limiter**: higher load increases the chance of hitting the soft cap, making `memory_limit_mib` and `memory_spike_mib` consequential.
- **`gomaxprocs`**: at 100 VUs the gRPC listener and processing goroutines genuinely compete for OS threads — the parameter has real CPU impact.

The traffic mix exercises all three collector pipelines: traces with tail-sampling (errors from `/alerts`, latency from `/diagnostics`), logs via Fluent Bit, and metrics via remote-write.

### What it does not cover

Network failure simulation (Act 3 of the demo) is intentionally excluded. The optimisation targets the **normal operating scenario**. File-backed queue behaviour under fill and drain is not observed.

---

## Folder structure

```
akamas/
├── optimization-pack/                  # Custom optimization pack to install on Akamas
│   ├── optimizationPack.yaml           #   pack manifest (name, version, tags)
│   ├── component-types/
│   │   └── otel-collector.yaml         #   OtelCollector component type definition
│   ├── parameters/
│   │   └── otel-collector-params.yaml  #   9 tunable parameters with ranges and defaults
│   └── metrics/
│       └── otel-collector-metrics.yaml #   7 metrics (objectives + SLOs + diagnostics)
│
├── system.yaml             # Akamas system: edge-observability-stack
├── component.yaml          # Component: collector (type OtelCollector, Prometheus labels)
├── telemetry-instance.yaml # Prometheus provider → <PROMETHEUS_LB_IP>:9090
├── workflow.yaml           # Workflow: apply-config → run-workload via SSH
├── study.yaml              # Study: objective, KPIs, parameters, 60 experiments
│
├── scripts/
│   ├── apply-config.sh     # Regenerates ConfigMap + patches DaemonSet env + rollout restart
│   └── run-workload.sh     # Creates k6 TestRun and waits for completion
│
└── k8s/                    # Kubernetes resources to deploy in the Civo cluster
    ├── runner-rbac.yaml              # ServiceAccount + Role + RoleBinding for the runner
    ├── runner-deployment.yaml        # Deployment + LoadBalancer Service for the SSH runner
    ├── runner-scripts-configmap.yaml # apply-config.sh and run-workload.sh mounted in the runner
    └── k6-optimization-configmap.yaml # Shortened k6 script (8 min steady-state) for iterations
```

Changes to the main repository:

```
overlays/civo/patches/prometheus-lb.yaml   # Exposes Prometheus as LoadBalancer (IP for Akamas)
overlays/civo/kustomization.yaml           # Adds the patch above
scripts/setup.sh                           # Adds --akamas flag
```

---

## Tuned parameters

| Parameter | Location | Default | Range | Primary driver |
|-----------|----------|---------|-------|----------------|
| `batch_timeout_s` | ConfigMap | 5 s | 1–10 s | Heap accumulation time before flush |
| `batch_send_size` | ConfigMap | 512 | 128–2048 | Heap per in-flight batch |
| `tail_decision_wait_s` | ConfigMap | 5 s | 2–10 s | **Main memory driver**: trace buffer window |
| `tail_num_traces` | ConfigMap | 10 000 | 1 000–20 000 | Tail-sampler LRU map size |
| `memory_limit_mib` | ConfigMap | 400 Mi | 128–450 Mi | memory_limiter soft cap |
| `memory_spike_mib` | ConfigMap | 80 Mi | 20–80 Mi | Spike headroom above the limit |
| `gogc` | DaemonSet env | 80 | 50–200 | GC target %: lower → more GC → less heap, more CPU |
| `gomemlimit_mib` | DaemonSet env | 300 Mi | 100–380 Mi | Go heap soft ceiling (GOMEMLIMIT) |
| `gomaxprocs` | DaemonSet env | 2 | 1–4 | Go scheduler OS threads (CPU parallelism) |

### Key parameter interactions

- **`tail_decision_wait_s` × `tail_num_traces`** determines the maximum size of the tail-sampler's in-memory buffer. This is the most impactful parameter pair for memory.
- **`gogc` and `gomemlimit_mib`** interact: `GOMEMLIMIT` overrides `GOGC` as the runtime approaches the limit, enforcing a hard RSS ceiling regardless of the GOGC value.
- A low **`gomaxprocs`** reduces CPU but risks goroutine starvation on the gRPC/HTTP listener paths if set below 2.

---

## Objective and SLOs

### Objective function (to minimise)

```
score = 0.6 × (working_set_bytes / 100_000_000) + 0.4 × (cpu_millicores / 80)
```

**Memory signal**: `container_memory_working_set_bytes` (cAdvisor) — what `kubectl top` and the K8s OOM killer use. Preferred over `otelcol_process_memory_rss` because Go 1.12+ releases freed heap pages with `MADV_FREE`, causing RSS to remain inflated after GC until the OS needs the memory back. Working set excludes those pages and accurately reflects actual footprint.

The divisors normalise both signals against the measured baseline (≈ 100 MB working set, ≈ 80 millicores). **Update these values** after running the baseline step and checking the actual numbers in Grafana.

### Safety KPIs (must not be violated)

Two distinct failure modes are tracked — both result in data loss:

**Processor-level drops** — memory_limiter, batch processor, or tail-sampler evict data already inside the pipeline:

| KPI | Prometheus metric | Threshold |
|-----|-------------------|-----------|
| `no_dropped_spans` | `increase(otelcol_processor_dropped_spans[window])` | = 0 |
| `no_dropped_logs` | `increase(otelcol_processor_dropped_log_records[window])` | = 0 |
| `no_dropped_metric_points` | `increase(otelcol_processor_dropped_metric_points[window])` | = 0 |

**Receiver-level refusals** — memory_limiter back-pressure rejects new data before it enters the pipeline (triggered when RSS > `limit_mib + spike_limit_mib`). A configuration with an overly tight `memory_limit_mib` can show zero processor drops while still losing data at ingestion:

| KPI | Prometheus metric | Threshold |
|-----|-------------------|-----------|
| `no_refused_spans` | `increase(otelcol_receiver_refused_spans[window])` | = 0 |
| `no_refused_log_records` | `increase(otelcol_receiver_refused_log_records[window])` | = 0 |
| `no_refused_metric_points` | `increase(otelcol_receiver_refused_metric_points[window])` | = 0 |

If any KPI is violated, Akamas marks the experiment as **unsafe** and penalises that region of the parameter space.

---

## Setup (one-time)

### Prerequisites

- `kubectl` pointing to the Civo cluster (`edge-observability`)
- `akamas` CLI installed and authenticated against the Akamas server (port-forward on `:9000`)
- Cluster already up via `kubectl apply -k overlays/civo`

### Option A — automated with `setup.sh`

```bash
./scripts/setup.sh --env civo --akamas
```

The `--akamas` flag automatically runs steps 1–4 below and prints the two IPs to configure.

### Option B — manual step by step

**1. Expose Prometheus via LoadBalancer** (already included in `overlays/civo` — done by `kubectl apply -k overlays/civo`)

**2. Generate the SSH key pair for the runner**

```bash
ssh-keygen -t ed25519 -f akamas-runner-key -N "" -C "akamas-runner"
```

**3. Create the Secret with the public key in the cluster**

```bash
kubectl create secret generic akamas-runner-pubkey \
  -n observability \
  --from-file=authorized_keys=akamas-runner-key.pub
```

**4. Deploy the runner Kubernetes resources**

```bash
kubectl apply -f akamas/k8s/runner-rbac.yaml
kubectl apply -f akamas/k8s/runner-scripts-configmap.yaml
kubectl apply -f akamas/k8s/runner-deployment.yaml
kubectl apply -f akamas/k8s/k6-optimization-configmap.yaml

kubectl wait --for=condition=ready pod \
  -l app=akamas-runner -n observability --timeout=180s
```

**5. Retrieve the two LoadBalancer IPs**

```bash
kubectl get svc prometheus akamas-runner -n observability \
  -o custom-columns='NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip'
```

**6. Fill in the placeholders in the Akamas config files**

```bash
# telemetry-instance.yaml → Prometheus address
sed -i 's/<PROMETHEUS_LB_IP>/1.2.3.4/g' akamas/telemetry-instance.yaml

# workflow.yaml → SSH runner host (appears twice, once per task)
sed -i 's/<RUNNER_LB_IP>/5.6.7.8/g' akamas/workflow.yaml
```

**7. Copy the private key to the Akamas server**

The method depends on your Akamas setup (kubectl cp, secret, etc.).
The path expected by the workflow is `/opt/akamas/keys/akamas-runner-key`.

```bash
# Example using kubectl cp to the Akamas pod
AKAMAS_POD=$(kubectl get pod -n akamas -l app=akamas -o jsonpath='{.items[0].metadata.name}')
kubectl cp akamas-runner-key ${AKAMAS_POD}:/opt/akamas/keys/akamas-runner-key -n akamas
```

---

## Creating the study on Akamas

All commands use the `akamas` CLI against the server at `localhost:9000`.

**1. Install the optimization pack**

```bash
akamas build optimization-pack akamas/optimization-pack/
akamas install optimization-pack descriptor.json
```

**2. Create the study resources**

```bash
akamas create system \
  --file akamas/system.yaml

akamas create component \
  --system edge-observability-stack \
  --file akamas/component.yaml

akamas create telemetry-instance \
  --file akamas/telemetry-instance.yaml

akamas create workflow \
  --file akamas/workflow.yaml

akamas create study \
  --file akamas/study.yaml
```

**3. Check the baseline before starting**

Look at Grafana to find the actual **working-set memory** (`container_memory_working_set_bytes`) and CPU values of the collector at steady state.
If they differ significantly from the study defaults (100 MB working set / 80 m CPU), update the divisors in the objective function in `study.yaml`:

```yaml
formula: "0.6 * (mem / <BASELINE_MEM_BYTES>) + 0.4 * (cpu / <BASELINE_CPU_MILLICORES>)"
```

**4. Launch the study**

From the Akamas web UI (or CLI), start the `collector-footprint-pareto` study.
The study runs in two phases:

| Phase | Type | Duration |
|-------|------|----------|
| `baseline` | 1 experiment with current values | ≈ 14 min |
| `optimise` | 60 Bayesian experiments (SOBOL) | ≈ 14 h |

**No interaction is required during the 60 experiments.** At the end Akamas presents the optimal configuration found. With `onlineMode: RECOMMEND` (set in `study.yaml`) you decide whether to adopt it.

---

## Applying the optimal configuration

Once Akamas presents its recommendation, apply the values to the cluster configuration files:

1. Update the values in the `otel-collector-config` ConfigMap (`k8s/edge-node/otel-collector-config.yaml`)
2. Update the environment variables in the DaemonSet (`k8s/edge-node/otel-collector-daemonset.yaml`):
   ```yaml
   env:
     - name: GOGC
       value: "<value>"
     - name: GOMEMLIMIT
       value: "<value_in_bytes>"
     - name: GOMAXPROCS
       value: "<value>"
   ```
3. Commit and apply via kustomize

---

## Grafana dashboard — "OTel Collector — Footprint & Go Runtime"

The dashboard (`uid: otelcol-footprint-akamas`) is loaded from `akamas/k8s/grafana-collector-dashboard.json` and has four sections. Every panel maps to a specific Prometheus metric. This section explains each panel in enough detail to validate that the data is correct before starting the study.

> **Data requirements:** Sections 1 and 4 need `container_memory_working_set_bytes` and `container_cpu_usage_seconds_total` from **cAdvisor**. These are only available once the `kubernetes-cadvisor` scrape job is active in Prometheus and at least one scrape cycle (15 s) has completed. All other panels use OTel Collector self-metrics from port 8888 (`job="otel-collector"`).

---

### Section 1 — FOOTPRINT (Akamas objective metrics)

| Panel | Metric | What it shows | Expected value at baseline |
|-------|--------|---------------|--------------------------|
| **Working Set Memory** (stat) | `container_memory_working_set_bytes{pod=~"otel-collector.*", container="otel-collector"}` | cAdvisor working set of the collector container. Excludes file-backed pages that the OS can reclaim — this is what `kubectl top` and the OOM killer use. **Weight 0.6 in the Akamas score.** | ≈ 80–120 MB at demo load; update the study divisor to match your actual baseline |
| **Process RSS** (stat) | `otelcol_process_memory_rss` | RSS reported by the collector process itself. Slightly higher than working set because it includes shared libraries and memory mapped by Go's allocator but not yet returned to the OS (`MADV_FREE`). Useful as a secondary reference but **not** the Akamas objective. | ≈ 100–150 MB |
| **CPU Usage (millicores)** (stat) | `rate(container_cpu_usage_seconds_total{pod=~"otel-collector.*", container="otel-collector"}[2m]) * 1000` | CPU consumption from cAdvisor. Averaged over 2 min to smooth k6 bursts. **Weight 0.4 in the Akamas score.** | ≈ 50–100 m at demo load; update the study divisor to match |
| **Akamas Composite Score** (stat) | `0.6 × (working_set / 100_000_000) + 0.4 × (cpu_millicores / 80)` | The same formula that Akamas minimises. Score = 1.0 means exactly at baseline. Lower is better. Use this panel to verify the divisors before launching the study — if the score is not ≈ 1.0 at baseline load, update the formula in `study.yaml`. | ≈ 1.0 at baseline, green < 0.8, red > 1.2 |
| **Memory Trend — Working Set vs RSS** (timeseries) | Working set (cAdvisor, blue) + RSS (process, purple) | Shows how memory evolves over time. A rising trend means a parameter combination is causing accumulation — Akamas should penalise it. The gap between RSS and working set reflects Go's lazy page release. | Both signals should be flat during the 10-min steady-state window |
| **CPU Trend** (timeseries) | `rate(container_cpu_usage_seconds_total{...}[2m]) * 1000` | CPU in millicores over time. Akamas searches for configurations that reduce both this and the working-set trend simultaneously. | Flat after ramp-up; no sustained growth |

**"No Data" on cAdvisor panels?** The `kubernetes-cadvisor` scrape job must be present in `prometheus-config.yaml`. If missing, add it and restart Prometheus: `kubectl rollout restart deployment/prometheus -n observability`.

---

### Section 2 — GO RUNTIME (heap & GC pressure)

These panels use metrics emitted by the Go runtime via the collector's internal telemetry. They explain *why* the working set behaves as it does when Akamas varies `gogc` and `gomemlimit_mib`.

| Panel | Metric | What it shows | Interpretation |
|-------|--------|---------------|----------------|
| **Go Heap — Allocated vs Total Sys** (timeseries) | `otelcol_process_runtime_heap_alloc_bytes` (green) + `otelcol_process_runtime_total_sys_memory_bytes` (blue) | Heap alloc = live objects currently on the heap. Total sys = total memory requested from the OS by the Go runtime (includes non-heap). A growing gap between the two signals heap fragmentation or unreturned memory. | Expect both to drop sharply when `gogc` is lowered (GC runs more aggressively) and to be capped when `gomemlimit_mib` is set tightly. |
| **Go Allocation Rate (GC Pressure)** (timeseries) | `rate(otelcol_process_runtime_total_alloc_bytes[2m])` | Bytes allocated per second (before GC, all objects). High rate drives GC pressure and RSS growth. Parameters that reduce in-flight data (smaller `batch_send_size`, shorter `tail_decision_wait_s`) lower this rate. | Should be lower for smaller `tail_num_traces` and shorter `tail_decision_wait_s` — verifies that Akamas is actually reducing buffering, not just compressing memory with GC |

---

### Section 3 — DATA INTEGRITY (safety KPIs — all must stay at 0)

Akamas treats any non-zero value here as an **unsafe** experiment. There are two failure modes:

**Receiver-level refusals** — back-pressure from the memory_limiter when RSS > `limit_mib + spike_limit_mib` rejects data before it enters the pipeline:

| Panel | Metric | Threshold |
|-------|--------|-----------|
| **Refused Spans** | `sum(increase(otelcol_receiver_refused_spans[5m])) or vector(0)` | Must be **0** |
| **Refused Metric Points** | `sum(increase(otelcol_receiver_refused_metric_points[5m])) or vector(0)` | Must be **0** |
| **Refused Log Records** | `sum(increase(otelcol_receiver_refused_log_records[5m])) or vector(0)` | Must be **0** |

**Processor-level drops** — memory_limiter, batch, or tail-sampler drop data already inside the pipeline:

| Panel | Metric | Threshold |
|-------|--------|-----------|
| **Dropped Spans** | `sum(increase(otelcol_processor_dropped_spans[5m])) or vector(0)` | Must be **0** |
| **Dropped Metric Points** | `sum(increase(otelcol_processor_dropped_metric_points[5m])) or vector(0)` | Must be **0** |
| **Dropped Log Records** | `sum(increase(otelcol_processor_dropped_log_records[5m])) or vector(0)` | Must be **0** |

The two **timeseries** panels at the bottom of this section show the rate of refused/dropped signals per minute — useful during manual parameter exploration to see the moment a limit is exceeded.

**Why two separate failure modes?** A configuration with an overly tight `memory_limit_mib` can show **zero processor drops** while still losing data at the receiver because the back-pressure fires before data enters the pipeline. Both counters must be checked independently.

---

### Section 4 — PIPELINE THROUGHPUT (signal flow through the collector)

| Panel | Metric | What it shows |
|-------|--------|---------------|
| **Receiver Accepted Rate** (timeseries) | `rate(otelcol_receiver_accepted_{spans,metric_points,log_records}[1m])` | Raw input to the collector from the app and Fluent Bit. Should be **stable across all experiments** — Akamas must not reduce throughput (the load pattern is constant). If this drops between experiments, investigate the k6 workload or the collector restart timing. |
| **Exporter Sent Rate** (timeseries) | `rate(otelcol_exporter_sent_{spans,metric_points,log_records}[1m])` | Signals successfully forwarded to Jaeger, Prometheus, and Loki. Spans will be much lower than accepted spans (tail sampling drops ~70–80% of traces). Metric points and log records should be close to accepted. Should never drop to zero during Akamas experiments (no network disruption). |
| **Export Queue Depth** (timeseries) | `sum(otelcol_exporter_queue_size) or vector(0)` | Batches waiting in the file-backed queue. **Must stay at 0** during Akamas experiments — a non-zero queue means exporter throughput cannot keep up with the producer rate, which would invalidate the steady-state measurement window. A growing queue is an early warning that `batch_send_size` or `batch_timeout_s` is causing head-of-line blocking. |

---

### Section 5 — TAIL SAMPLER (trace sampling decisions)

| Panel | Metric | What it shows |
|-------|--------|---------------|
| **Tail Sampling Decisions** (timeseries) | `rate(otelcol_processor_tail_sampling_count_traces_sampled{sampled="true/false"}[1m])` | Traces kept (green) vs dropped (red) by the tail sampler. The ratio depends on the app's error and latency profile. Should remain **stable across experiments** — the sampling policy (`error-policy` + `latency-policy`) is not an Akamas parameter. A changing ratio would mean the load pattern has changed between experiments. |
| **New Trace IDs Received** (timeseries) | `rate(otelcol_processor_tail_sampling_new_trace_id_received[1m])` | Rate of new trace IDs entering the decision buffer. Proportional to request rate from the k6 workload. At 100 VUs (optimisation workload) this should be ≈ 255/s. At 8 VUs (demo workload) ≈ 5/s. If this is much lower than expected, the app or k6 runner may not be generating load correctly. The `tail_num_traces` parameter directly limits the maximum number of IDs that can be held simultaneously: `in_flight = new_trace_id_rate × tail_decision_wait_s`. Verify that `tail_num_traces > in_flight` so the LRU map doesn't evict active traces. |

---

### Validating the baseline before starting the study

Before launching the optimisation, confirm the following in Grafana:

1. **All six safety KPIs are at 0** — if any are non-zero at baseline load, the default parameters are already too aggressive and must be relaxed before running the study.
2. **Receiver accepted rate is stable** — the k6 optimisation workload is at full load (100 VUs). If the rate is unstable, wait for ramp-up to complete (first 2 min).
3. **Export queue depth is 0** — any non-zero queue at baseline load means the exporters are already bottlenecked.
4. **Working set ≈ your measured value** — update the divisor in `study.yaml`: `formula: "0.6 * (mem / <ACTUAL_WORKING_SET_BYTES>) + 0.4 * (cpu / <ACTUAL_CPU_MILLICORES>)"`. A wrong divisor makes the Akamas score meaningless.
5. **Akamas Composite Score ≈ 1.0** — confirms the divisors are correct.

---

## Operational notes

**The study and the demo are mutually exclusive.**
The workflow restarts the collector every ≈ 11 minutes. Do not run the KubeCon demo while the study is active.

**The runner pod is idle during the demo.**
It runs on the hub node (not the edge node) and consumes ≈ 50m CPU / 64Mi RAM only when Akamas connects via SSH. It does not affect the collector or the app during the demo.

**Recovery from a failed experiment.**
If an experiment fails for infrastructural reasons (Civo network instability, pod eviction), Akamas counts it against `maxFailedExperiments`. With `maxFailedExperiments: 15` the study tolerates up to 15 failures before aborting.

**Prometheus LoadBalancer and security.**
The Prometheus LoadBalancer is publicly exposed on Civo (port 9090, no authentication). Use it only during the study; remove the `overlays/civo/patches/prometheus-lb.yaml` patch from the kustomization when it is no longer needed.
