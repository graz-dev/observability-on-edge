# Maritime Vessel Observability - Edge Computing Demo

A production-realistic observability demo for **edge computing in maritime environments**, showcasing intelligent trace sampling, persistent queuing for network resilience during satellite connectivity loss, and unified visualization of correlated vessel telemetry data.

**Perfect for demonstrating**: IoT monitoring, remote site observability, maritime operations, or any edge deployment with intermittent connectivity.

## 🎯 What This Demo Shows

- **Intelligent Sampling**: Tail-based sampling reduces trace data by 80-90% while keeping all errors and slow requests
- **Network Resilience**: Persistent file queues prevent data loss during network outages
- **Full Correlation**: Seamlessly navigate between metrics, logs, and traces using trace IDs and exemplars
- **Edge-Optimized**: Lightweight collectors designed for resource-constrained environments
- **Production Patterns**: Real-world configuration of OpenTelemetry, Prometheus, Loki, and Jaeger

## 🏗️ Architecture

```
┌─────────── VESSEL (EDGE) ────────┐         ┌───── SHORE HUB ────────────┐
│                                  │         │                            │
│  Vessel Monitor (Go + OTel)      │         │  Grafana                   │
│  - Engine sensors                │         │     ↑                      │
│  - Navigation data               │         │  Prometheus, Loki, Jaeger  │
│  - Diagnostics                   │         │                            │
│         ↓                        │         │                            │
│  OTel Collector                  │  ═══▶   │  [Unified Dashboard]       │
│  • Tail-based sampling           │  sat    │                            │
│  • Persistent queues             │  link   │  View all vessel data:     │
│  • Batching                      │         │  - Engine health           │
│         ↑                        │         │  - GPS tracks              │
│  Fluent Bit (logs)               │         │  - Diagnostic reports      │
│                                  │         │  - System alerts           │
└──────────────────────────────────┘         └────────────────────────────┘
```

## 🚀 Quick Start

### Prerequisites

```bash
# macOS
brew install docker k3d kubectl k6

# Linux
# Install Docker, k3d, kubectl, k6 (see DEMO.md for details)

# Windows
choco install docker-desktop k3d kubernetes-cli k6
```

### Setup (5 minutes)

```bash
# 1. Clone the repository
git clone <repo-url>
cd observability-on-edge

# 2. Run the setup script
./scripts/setup.sh

# 3. Access the dashboards
open http://localhost:30300  # Grafana (admin/admin)
open http://localhost:30686  # Jaeger
```

### Run Demo Scenarios

#### Scenario 1: Normal Operation
```bash
# Generate realistic traffic
./scripts/load-generator.sh

# Open Grafana dashboards:
# - Application Observability
# - Monitoring System Health
```

#### Scenario 2: Satellite Link Loss & Recovery
```bash
# Start vessel monitoring (simulates continuous sensor data)
./scripts/load-generator.sh

# In another terminal, simulate satellite connectivity loss
./scripts/simulate-network-failure.sh

# Watch persistent queue grow in Grafana dashboard
# Vessel continues collecting data locally

# After 30-60 seconds, restore satellite connection
./scripts/restore-network.sh

# Observe: Queue drains, all vessel data syncs to shore hub!
# No sensor data lost during the outage
```

### Cleanup

```bash
./scripts/cleanup.sh
```

## 📊 Components

| Component | Purpose | Image |
|-----------|---------|-------|
| **Vessel Monitor** | Maritime telemetry system | Custom Go app |
| **OTel Collector** | Sampling & collection | `otel/opentelemetry-collector-contrib:0.95.0` |
| **Fluent Bit** | Log collection | `fluent/fluent-bit:2.2` |
| **Jaeger** | Trace storage & UI | `jaegertracing/all-in-one:1.54` |
| **Prometheus** | Metrics storage | `prom/prometheus:v2.49.1` |
| **Loki** | Log aggregation | `grafana/loki:2.9.4` |
| **Grafana** | Unified visualization | `grafana/grafana:10.3.3` |

## 🎓 Key Features

### Tail-Based Sampling

Smart sampling that waits for complete traces before deciding:
- ✅ Keep **all** error traces
- ✅ Keep traces slower than **200ms**
- ✅ Sample **10%** of normal traces
- 📉 Result: **80-90% data reduction**

### Network Resilience

Persistent file queues in OTel Collector:
- Queue data during network outages
- Automatic retry with exponential backoff
- Drain queued data when connectivity returns
- **Zero data loss** during intermittent connectivity

### Full Observability Correlation

- **Logs → Traces**: Click trace_id in logs to view trace in Jaeger
- **Metrics → Traces**: Exemplars link metric data points to traces
- **Traces → Logs**: View related logs from trace timeline
- **Unified View**: Single Grafana interface for all signals

## 📚 Documentation

- **[DEMO.md](DEMO.md)** - Comprehensive guide with:
  - Detailed architecture explanation
  - Component configuration details
  - Data flow diagrams
  - Step-by-step demo scenarios
  - Dashboard usage guide
  - Troubleshooting tips

## 🗂️ Project Structure

```
.
├── app/                          # Go application with OTel
│   ├── main.go                   # Application entry point
│   ├── handlers.go               # HTTP handlers
│   ├── telemetry.go              # OTel instrumentation
│   ├── go.mod                    # Go dependencies
│   └── Dockerfile                # Container image
│
├── configs/                      # Configuration files
│   ├── otel-collector-config.yaml
│   ├── fluentbit-config.yaml
│   ├── prometheus-config.yaml
│   ├── loki-config.yaml
│   └── grafana-*.yaml
│
├── k8s/                          # Kubernetes manifests
│   ├── namespace.yaml
│   ├── edge-node/                # Edge workloads
│   │   ├── app-deployment.yaml
│   │   ├── otel-collector-*.yaml
│   │   └── fluentbit-*.yaml
│   ├── hub-node/                 # Hub workloads
│   │   ├── jaeger-*.yaml
│   │   ├── prometheus-*.yaml
│   │   ├── loki-*.yaml
│   │   └── grafana-*.yaml
│   ├── grafana-dashboards/       # Pre-built dashboards
│   │   ├── app-observability.json
│   │   └── monitoring-health.json
│   └── network-policy-deny.yaml  # For network failure simulation
│
├── load-tests/                   # Load testing
│   └── k6-script.js              # k6 load test scenarios
│
├── scripts/                      # Automation scripts
│   ├── setup.sh                  # Full setup
│   ├── simulate-network-failure.sh
│   ├── restore-network.sh
│   ├── load-generator.sh
│   └── cleanup.sh
│
├── DEMO.md                       # Comprehensive demo guide
└── README.md                     # This file
```

## 🔍 Access Services

### Always Available (NodePort)

**Grafana**:
- **URL**: http://localhost:30300
- **Username**: `admin`
- **Password**: `admin`
- **Dashboards**:
  - Application Observability
  - Monitoring System Health

**Jaeger**:
- **URL**: http://localhost:30686
- **Features**:
  - Trace search and visualization
  - Service dependency graph
  - Trace comparison

### Other Services (Port-forward Required)

**Prometheus**:
```bash
kubectl port-forward -n observability svc/prometheus 9090:9090
# http://localhost:9090
```

**Loki** (via Grafana):
```bash
# Already accessible through Grafana datasource
```

## 🎯 Use Cases

### Primary Scenario: Maritime Vessel Monitoring
This demo simulates a **vessel monitoring system** running on a boat with satellite connectivity:
- ⚓ **Engine sensors**: RPM, temperature, oil pressure (fast, continuous polling)
- 🧭 **Navigation data**: GPS, speed, heading, depth (fast, high-frequency)
- 🔧 **Diagnostics**: Complex engine analysis (slow, resource-intensive)
- 🚨 **System alerts**: Sensor failures and warnings (error-prone)

**The Challenge**: When the vessel loses satellite connection (common at sea), the monitoring system must:
- ✅ Continue collecting all sensor data locally
- ✅ Queue data in persistent storage
- ✅ Sync everything when connectivity returns
- ✅ Reduce bandwidth using intelligent sampling (keep errors + slow diagnostics, drop fast normal reads)

### Other Edge Computing Scenarios
The same patterns apply to:
- 🏭 **Industrial IoT**: Factory equipment monitoring with unreliable network
- 🏪 **Retail PoS**: Point-of-sale systems in remote stores
- 🛢️ **Oil & Gas**: Remote drilling site monitoring
- 🚜 **Agriculture**: Smart farming equipment telemetry
- 📡 **Any edge deployment** with intermittent connectivity and bandwidth constraints

## 🛠️ Customization

### Adjust Sampling Threshold

Edit `configs/otel-collector-config.yaml`:
```yaml
processors:
  tail_sampling:
    policies:
      - name: latency-policy
        type: latency
        latency:
          threshold_ms: 200  # ← Change this
```

### Add Custom Endpoints

Edit `app/handlers.go` and add new handlers:
```go
func (s *Server) myNewHandler(w http.ResponseWriter, r *http.Request) {
    // Your code here
}
```

Register in `app/main.go`:
```go
http.HandleFunc("/api/new", server.tracingMiddleware(server.myNewHandler))
```

### Modify Load Test

Edit `load-tests/k6-script.js` to change:
- Virtual user count
- Test duration
- Request mix
- Custom scenarios

## 🐛 Troubleshooting

### Pods Not Starting
```bash
kubectl get pods -n observability
kubectl describe pod <POD_NAME> -n observability
```

### No Data in Grafana
```bash
# Check datasources
kubectl get pods -n observability | grep -E "jaeger|prometheus|loki"

# Check OTel Collector logs
kubectl logs -n observability deployment/otel-collector
```

### Network Policy Not Working
```bash
# Verify policy exists
kubectl get networkpolicy -n observability

# Test connectivity
kubectl exec -n observability deployment/otel-collector -- wget -O- http://jaeger:16686 --timeout=5
```

See [DEMO.md](DEMO.md) for detailed troubleshooting.

## 📖 Learn More

- **OpenTelemetry**: https://opentelemetry.io/docs/
- **Tail-Based Sampling**: https://opentelemetry.io/docs/collector/configuration/#tailsamplingprocessor
- **Grafana Correlations**: https://grafana.com/docs/grafana/latest/fundamentals/correlations/
- **k3s/k3d**: https://k3d.io/

## 🤝 Contributing

Contributions welcome! Areas for enhancement:
- Additional application endpoints
- More sampling policies
- Advanced correlation examples
- Multi-cluster scenarios
- Production hardening guides

## 📝 License

This project is provided as-is for educational and demonstration purposes.

## 🙏 Acknowledgments

Built with:
- OpenTelemetry Community
- Grafana Labs (Grafana, Loki)
- Prometheus Community
- Jaeger Project
- Fluent Bit Community
- k3s/k3d Projects

---

**Ready to explore edge observability?**

Start with `./scripts/setup.sh` and read [DEMO.md](DEMO.md) for the full experience! 🚀
