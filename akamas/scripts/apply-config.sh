#!/bin/bash
# apply-config.sh — called by Akamas Executor for every experiment.
# Receives parameters as env vars (set by the workflow command prefix):
#   BATCH_TIMEOUT_S, BATCH_SEND_SIZE, TAIL_DECISION_WAIT_S, TAIL_NUM_TRACES,
#   MEMORY_LIMIT_MIB, MEMORY_SPIKE_MIB, GOGC, GOMEMLIMIT_MIB, GOMAXPROCS
#
# Runs inside the akamas-runner pod (Civo cluster) with in-cluster kubectl.
set -euo pipefail

NAMESPACE="${NAMESPACE:-observability}"

# batch_send_max_size must be >= batch_send_size; use 2× as upper cap.
BATCH_SEND_MAX_SIZE=$((BATCH_SEND_SIZE * 2))

# GOMEMLIMIT must be in bytes for the Go runtime env var.
GOMEMLIMIT_BYTES=$((GOMEMLIMIT_MIB * 1024 * 1024))

echo "[apply-config] params:"
echo "  batch: timeout=${BATCH_TIMEOUT_S}s size=${BATCH_SEND_SIZE} max=${BATCH_SEND_MAX_SIZE}"
echo "  tail:  decision_wait=${TAIL_DECISION_WAIT_S}s num_traces=${TAIL_NUM_TRACES}"
echo "  memlimiter: limit=${MEMORY_LIMIT_MIB}Mi spike=${MEMORY_SPIKE_MIB}Mi"
echo "  go: GOGC=${GOGC} GOMEMLIMIT=${GOMEMLIMIT_MIB}Mi GOMAXPROCS=${GOMAXPROCS}"

# ── 1. Regenerate the collector ConfigMap ────────────────────────────────────
kubectl apply -n "$NAMESPACE" -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: ${NAMESPACE}
data:
  otel-collector-config.yaml: |
    extensions:
      health_check:
        endpoint: 0.0.0.0:13133

      file_storage:
        directory: /var/lib/otelcol/file_storage
        timeout: 10s

    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: ${MEMORY_LIMIT_MIB}
        spike_limit_mib: ${MEMORY_SPIKE_MIB}

      batch:
        timeout: ${BATCH_TIMEOUT_S}s
        send_batch_size: ${BATCH_SEND_SIZE}
        send_batch_max_size: ${BATCH_SEND_MAX_SIZE}

      resource:
        attributes:
          - key: deployment.environment
            value: edge
            action: insert
          - key: cluster.name
            value: edge-observability
            action: insert

      tail_sampling:
        decision_wait: ${TAIL_DECISION_WAIT_S}s
        num_traces: ${TAIL_NUM_TRACES}
        expected_new_traces_per_sec: 10
        policies:
          - name: error-policy
            type: status_code
            status_code:
              status_codes:
                - ERROR
          - name: latency-policy
            type: latency
            latency:
              threshold_ms: 200

    exporters:
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

      prometheusremotewrite:
        endpoint: http://prometheus.observability.svc.cluster.local:9090/api/v1/write
        tls:
          insecure: true
        retry_on_failure:
          enabled: true
          initial_interval: 5s
          max_interval: 30s
          max_elapsed_time: 300s

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

    service:
      extensions: [health_check, file_storage]

      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, resource, tail_sampling, batch]
          exporters: [otlp/jaeger]

        metrics:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [prometheusremotewrite]

        logs:
          receivers: [otlp]
          processors: [memory_limiter, resource, batch]
          exporters: [loki]

      telemetry:
        logs:
          level: info
        metrics:
          address: 0.0.0.0:8888
          level: detailed
EOF

# ── 2. Patch Go runtime env vars on the DaemonSet ───────────────────────────
kubectl set env daemonset/otel-collector \
  -n "$NAMESPACE" \
  "GOGC=${GOGC}" \
  "GOMEMLIMIT=${GOMEMLIMIT_BYTES}" \
  "GOMAXPROCS=${GOMAXPROCS}"

# ── 3. Restart and wait for rollout ─────────────────────────────────────────
echo "[apply-config] restarting DaemonSet..."
kubectl rollout restart daemonset/otel-collector -n "$NAMESPACE"
kubectl rollout status daemonset/otel-collector -n "$NAMESPACE" --timeout=120s

echo "[apply-config] collector is ready"
