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
      │ SSH ─── Akamas toolbox ──────────────────────────────────────┐
      │         /work/kubeconfig                                      │
      │              │                                               │
      │              │ kubectl (via kubeconfig → Civo cluster)       │
      │              ▼                                               │
      │         applies collector ConfigMap (edge-obs)               │
      │         patches DaemonSet env vars  (edge-obs)               │
      │         rollout restart + wait      (edge-obs)               │
      │         creates k6 TestRun + waits  (testing)                │
      │                                                               │
      │ Prometheus scrape ─────────────────────────────────────────────
      │      http://<PROMETHEUS_LB_IP>:9090
      └───────────────────────────────────────────────────────────────
```

Akamas runs `apply-config.sh` and `run-workload.sh` directly from its own toolbox using the Civo kubeconfig stored at `/work/kubeconfig`. No in-cluster runner pod is required.

Per-experiment flow (≈ 11 min):
1. Akamas picks a set of parameter values
2. Toolbox runs `apply-config.sh` via kubeconfig → applies the config and restarts the collector (`edge-obs` namespace)
3. Toolbox runs `run-workload.sh` via kubeconfig → creates a k6 TestRun and waits for completion (`testing` namespace)
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

At the demo load (500 VUs, sleep 0.1–0.5 s) the app generates ~2 500 spans/s → ~1 250 traces in flight at default `decision_wait=5s`. The optimisation workload uses 100 VUs to keep experiment duration manageable (~12.5 min) while still generating ~255 traces/s → ~1 275 in flight, which covers the meaningful part of the range.

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

| Aspect | Demo (`k6-script-configmap.yaml`) | Optimisation (`k6-optimization.js`) |
|--------|------------------------------------|-------------------------------------|
| Peak VUs | **500** | **100** |
| Ramp-up | 30 s → 100, 30 s → 250, 1 m → 500 | 30 s → 20, 30 s → 50, 1 m → 100 |
| Steady-state | **40 min** | **10 min** |
| Traffic mix | 50 % engine / 30 % nav / 12 % diag / 8 % alerts | identical |
| Fast-endpoint sleep | 0.1–0.5 s | **0.1–0.5 s** (rapid sensor polling) |
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
├── workflow.yaml           # Workflow: apply-config → run-workload (via Akamas toolbox kubeconfig)
├── study.yaml              # Study: objective, KPIs, parameters, 60 experiments
│
├── scripts/
│   ├── apply-config.sh     # Regenerates ConfigMap + patches DaemonSet env + rollout restart
│   └── run-workload.sh     # Creates k6 TestRun and waits for completion
│
└── k8s/                    # Kubernetes resources to deploy in the Civo cluster
    └── k6-optimization-configmap.yaml # Shortened k6 script (8 min steady-state) for iterations
```

> **Note:** `runner-deployment.yaml` and `runner-rbac.yaml` are intentionally empty — the SSH runner pod has been removed. Akamas uses its own kubeconfig (`/work/kubeconfig`) to run scripts directly against the Civo cluster.

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
score = (working_set_bytes / 1_073_741_824) + (2 × cpu_millicores / 1_000)
      = working_set_GB + 2 × cpu_cores
```

This expresses memory in GB and CPU in cores (×2 to match the edge-node weighting where memory pressure is the tighter constraint on a DaemonSet). At the measured baseline (~52 MB working set, ~50 mc CPU) the two terms contribute roughly equally to the score (~0.048 + ~0.100 = 0.148).

**Memory signal**: `container_memory_working_set_bytes` (cAdvisor) — what `kubectl top` and the K8s OOM killer use. Preferred over `otelcol_process_memory_rss` because Go 1.12+ releases freed heap pages with `MADV_FREE`, causing RSS to remain inflated after GC until the OS needs the memory back. Working set excludes those pages and accurately reflects actual footprint.

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

The `--akamas` flag automatically runs steps 1–3 below and prints the Prometheus IP to configure.

### Option B — manual step by step

**1. Expose Prometheus via LoadBalancer** (already included in `overlays/civo` — done by `kubectl apply -k overlays/civo`)

**2. Deploy the k6 optimisation ConfigMap**

```bash
kubectl apply -f akamas/k8s/k6-optimization-configmap.yaml
```

**3. Retrieve the Prometheus LoadBalancer IP**

```bash
kubectl get svc prometheus -n hub-obs \
  -o custom-columns='NAME:.metadata.name,IP:.status.loadBalancer.ingress[0].ip'
```

**4. Copy the Civo kubeconfig to the Akamas toolbox**

The scripts expect the kubeconfig at `/work/kubeconfig` on the Akamas toolbox.
The `KUBECONFIG` environment variable overrides this path if already set in the toolbox.

**5. Fill in the placeholder in the Akamas config files**

---

## Creating the study on Akamas

All commands use the `akamas` CLI against the server at `localhost:9000`.

**1. Install the optimization pack**

```bash
akamas build op akamas/optimization-pack/
akamas install op <optimization-pack-manifest>.json
```

**2. Create the study resources**

```bash
akamas create system \
  akamas/system.yaml

akamas create component \
  akamas/component.yaml "<system-name>"

akamas create telemetry-instance \
  akamas/telemetry-instance.yaml "<system-name>"

akamas create workflow \
  akamas/workflow.yaml

akamas create study \
  akamas/study.yaml
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
| `baseline` | 1 experiment with current values (3 trials) | ≈ 42 min |
| `optimise` | 150 Bayesian experiments (SOBOL) | ≈ 35 h |

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

**"No Data" on cAdvisor panels?** The `kubernetes-cadvisor` scrape job must be present in `prometheus-config.yaml`. If missing, add it and restart Prometheus: `kubectl rollout restart deployment/prometheus -n hub-obs`.

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

**Recovery from a failed experiment.**
If an experiment fails for infrastructural reasons (Civo network instability, pod eviction), Akamas counts it against `maxFailedExperiments`. With `maxFailedExperiments: 50` the study tolerates up to 50 failures before aborting.

**Prometheus LoadBalancer and security.**
The Prometheus LoadBalancer is publicly exposed on Civo (port 9090, no authentication). Use it only during the study; remove the `overlays/civo/patches/prometheus-lb.yaml` patch from the kustomization when it is no longer needed.

---

## Findings

This section documents the results of the `collector-footprint-v3` study (90 completed optimization experiments out of 150 planned, plus the baseline step with 3 trials).

### Study summary

| | Value |
|--|--|
| Baseline experiments | 1 (3 trials) |
| Optimization experiments completed | 90 |
| Experiments with constraint violations | 1 (Exp 84) |
| Best improvement over baseline | **−39.9%** composite score |
| Best experiment | Exp 38 |

### Baseline vs best result

| Metric | Baseline (avg of trials 2–3) | Best (Exp 38) | Change |
|--------|------------------------------|---------------|--------|
| Working set memory | ~52 MB | ~39 MB | **−25%** |
| CPU usage | ~50 mc | ~24 mc | **−52%** |
| Composite score | ~0.149 | 0.0864 | **−42%** |
| Dropped / refused signals | 0 | 0 | ✓ |

The baseline trial 1 produced a lower score (0.133) due to collector warm-up; trials 2–3 (score ~0.149) reflect the true steady state.

### What the optimizer found

The study converged clearly on three parameters. Everything else had a relatively small or inconsistent effect.

#### 1. `tail_num_traces` → always 1 000 (minimum of the range)

This is the single biggest driver. The tail-sampler holds one in-memory entry per active trace in its LRU map. At baseline `tail_num_traces = 5 000`, the map can hold 5 000 trace entries simultaneously; at the minimum `1 000`, it holds 80% fewer.

At 100 VUs the app generates ~255 traces/s. With `tail_decision_wait_s = 10`, up to ~2 550 traces could be in-flight at once. Because the LRU can only hold 1 000 entries, ~1 550 get evicted immediately and exported without a sampling decision (they are counted as "sampled = true" by the processor). This increases the raw export rate slightly, but critically it keeps the in-memory buffer tiny — which is the direct cause of the ~13 MB working-set reduction.

The SLO (zero dropped/refused signals) is still satisfied because evicted traces are exported, not dropped.

#### 2. `gogc` → always 200 (maximum of the range)

At baseline `gogc = 100` (Go's default), the GC triggers a collection cycle when the live heap doubles. At `gogc = 200` it waits until the heap triples, so GC runs roughly half as often. This cuts CPU spent on garbage collection by ~50%, which explains the ~26 mc CPU reduction.

The risk with a higher GOGC is that the heap grows larger between GC cycles. Here the risk is capped by `GOMEMLIMIT`, which forces aggressive GC regardless of GOGC when the Go heap approaches the configured ceiling. With a small working set (~39 MB), that ceiling is never approached in normal operation, so GOGC=200 reduces CPU without any memory penalty.

#### 3. `gomaxprocs` → always 1

This was already at the optimal value in the baseline. Every experiment with `gomaxprocs = 2` performed worse: the additional OS thread increases scheduling overhead and cache pressure without providing useful parallelism at this load level (single gRPC receiver + three pipeline goroutines). The only `CONSTRAINTS_VIOLATED` experiment (Exp 84) used `gomaxprocs = 2` combined with a tight memory limit, which caused both refused spans (1 175) and dropped spans (177) due to combined memory pressure.

#### 4. `tail_decision_wait_s` → tends toward 10 (maximum)

Counter-intuitive alongside `tail_num_traces = 1 000`: a longer wait should mean more in-flight traces, which should mean more LRU evictions and higher memory. In practice, once `tail_num_traces = 1 000` is set, the LRU immediately evicts anything beyond 1 000 entries regardless of the wait window. Increasing the wait to 10 s therefore does not add memory, and it actually improves sampling accuracy for the traces that do fit in the map (more spans arrive before a decision is made).

#### 5. `batch_send_size`, `batch_timeout_s` — not critical

The top 10 experiments span the full range on both parameters (batch_send_size from 128 to 2 048, batch_timeout_s from 1 to 10 s) with essentially the same score. The batch processor's contribution to working-set memory is small compared to the tail-sampler LRU, so the optimiser did not converge here. Either end of the range is safe.

#### 6. `memory_limit_mib`, `memory_spike_mib`, `gomemlimit_mib` — not critical at low footprint

With working set at ~39 MB and RSS at ~61 MB, any `memory_limit_mib ≥ 128` provides a safe margin below the K8s container limit (512 Mi). The optimiser explored tight values (128 Mi) and loose values (450 Mi) equally in the top results. Similarly, `gomemlimit_mib` in the range 100–380 Mi showed no meaningful difference once `tail_num_traces = 1 000` and `gogc = 200` were set.

### Experiments that performed poorly

| Experiment | Score | Key parameters | Why it was bad |
|-----------|-------|----------------|----------------|
| Exp 31 | 0.194 (−35%) | `tail_num_traces=12 000`, `gogc=50`, `gomaxprocs=1` | `gogc=50` triggered GC twice as often → 72 mc CPU. Large LRU added memory. |
| Exp 32 | 0.184 (−28%) | `tail_num_traces=12 000`, `tail_decision_wait_s=10`, `memory_limit_mib=128` | Large LRU map → 84 MB working set. Tight memory limit caused the limiter to activate. |
| Exp 9 | 0.185 (−28%) | `tail_num_traces=7 188`, `gomaxprocs=2` | High LRU + extra OS thread → 60 mc CPU + 70 MB working set. |
| Exp 84 ⚠️ | 0.152 (VIOLATED) | `tail_num_traces=12 000`, `gomaxprocs=2`, `memory_limit_mib=128` | Only constraint-violated experiment. RSS exceeded the tight limit → 1 175 refused spans + 177 dropped spans. |

The common pattern in failing or poor experiments is a **large `tail_num_traces`** (≥ 5 000). This is the dominant factor; poor `gogc` or `gomaxprocs` values amplify the problem but are secondary.

### Recommended configuration

Based on the consistent convergence across the top 10 experiments:

| Parameter | Baseline | Recommended | Reason |
|-----------|---------|-------------|--------|
| `tail_num_traces` | 5 000 | **1 000** | Largest single memory saving (~13 MB) |
| `tail_decision_wait_s` | 5 s | **10 s** | Better sampling accuracy; no memory cost at low LRU |
| `gogc` | 100 | **200** | ~50% less GC-related CPU overhead |
| `gomaxprocs` | 1 | **1** | Already optimal; do not increase |
| `memory_limit_mib` | 300 Mi | **200 Mi** | Safe margin above observed RSS (~61 MB); can go as low as 128 Mi |
| `memory_spike_mib` | 60 Mi | **20 Mi** | Spike headroom; RSS is stable at low footprint |
| `gomemlimit_mib` | 250 Mi | **150 Mi** | Soft Go heap ceiling; lower is fine at small footprint |
| `batch_send_size` | 512 | 128–2 048 | No significant impact; keep at 512 or lower for lower per-batch heap |
| `batch_timeout_s` | 5 s | 1–5 s | No significant impact; shorter = faster export latency |

> **Caveat:** These values were measured at 100 VUs (optimisation workload). The demo now runs at 500 VUs, generating ~2 500 spans/s (~1 250 traces in flight at `decision_wait=5s`). With `tail_num_traces = 1 000` the LRU will evict ~250 traces per second, exporting them without a sampling decision — this is safe (evicted traces are exported, not dropped) and keeps the buffer tiny. At this load level `memory_limit_mib = 128 Mi` may be tight; prefer `200 Mi` as a safe ceiling.
