# System Architecture

This diagram illustrates the flow of telemetry data (metrics, traces, and logs) from the **Edge Nodes** to the **Monitoring Hub**.

```mermaid
graph TB
    subgraph "Edge Node (DaemonSet)"
        App["Noise Generator (Go App)"]
        FB["Fluent Bit (DaemonSet)"]
        Collector["OTel Collector (DaemonSet)"]
        Queue[("Persistent Queue (Disk)")]
    end

    subgraph "Monitoring Hub (Server)"
        Prometheus["Prometheus"]
        Jaeger["Jaeger"]
        Loki["Loki"]
        Grafana["Grafana"]
    end

    %% Data Flows
    App -->|"Traces (OTLP/gRPC)"| Collector
    App -.->|"Logs (Stdout/Stderr)"| FB
    FB -->|"Parsed Logs (OTLP/HTTP)"| Collector
    
    Collector <-->|Buffering| Queue
    
    Collector -->|Metrics (Scrape)| Prometheus
    Collector -->|"Traces (OTLP/gRPC)"| Jaeger
    Collector -->|"Logs (OTLP/HTTP)"| Loki

    %% Visualization
    Grafana -->|Query| Prometheus
    Grafana -->|Query| Jaeger
    Grafana -->|Query| Loki

    %% Styling
    style App fill:#f9f,stroke:#333,stroke-width:2px
    style Collector fill:#bbf,stroke:#333,stroke-width:2px
    style FB fill:#dfd,stroke:#333,stroke-width:2px
    style Grafana fill:#f96,stroke:#333,stroke-width:2px
```

## Components Description

### Edge Layer
- **Noise Generator**: Simulates a production application. Generates traces directly via OTel SDK and emits logs to stdout.
- **Fluent Bit**: Lightweight log processor. It tailors container logs, parses them using regex (on the edge!), filters out noise (like 200 OK logs), and enriches them with metadata (e.g., `edge_region`).
- **OTel Collector**: The central nervous system on the edge. It aggregates traces from the app and logs from Fluent Bit. It manages its own **Persistent Queue** on disk to survive network outages.

### Hub Layer (Central Observability)
- **Prometheus**: Stores and queries metrics.
- **Jaeger**: Distributed tracing backend.
- **Loki**: Log aggregation system.
- **Grafana**: The unified UI for visualizing all three pillars of observability.
