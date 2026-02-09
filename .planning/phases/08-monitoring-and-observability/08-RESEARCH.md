# Phase 8: Monitoring and Observability - Research

**Researched:** 2026-02-09
**Domain:** Structured logging, Prometheus metrics, Grafana dashboards, GPU telemetry, and alerting for federated learning on Docker-in-VM appliances
**Confidence:** HIGH (structured logging, DCGM/GPU telemetry), MEDIUM (Flower metrics integration, Grafana dashboards), LOW (flwr-monitoring third-party package maturity)

## Summary

This research covers the complete monitoring and observability stack for the Flower-OpenNebula federated learning appliances. The stack has three layers: (1) structured logging for FL training events using Flower's built-in Python logger extended with JSON formatting, (2) Prometheus metrics exporters for both Flower training metrics (custom `prometheus_client` exporter in the ServerApp) and NVIDIA GPU utilization (DCGM Exporter sidecar container), and (3) Grafana dashboards with pre-built panel definitions and Prometheus alerting rules for critical conditions.

Flower's native logging uses Python's `logging` module with a logger named `flwr`, controllable via the `FLWR_LOG_LEVEL` environment variable (already mapped to `FL_LOG_LEVEL` in Phase 1). Flower does NOT natively export Prometheus metrics from the SuperLink or SuperNode processes. The training metrics (per-round loss, accuracy, client participation) are available inside the ServerApp via the `Result` object, which contains `train_metrics_clientapp`, `evaluate_metrics_clientapp`, and `evaluate_metrics_serverapp` -- all indexed by round number. To expose these to Prometheus, the spec must define a custom metrics exporter embedded in the ServerApp code that uses the `prometheus_client` Python library to serve metrics on an HTTP endpoint.

For GPU monitoring, NVIDIA's DCGM Exporter (`nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless`) is the standard production-grade solution. It runs as a Docker sidecar container alongside the SuperNode's Flower container, exposing GPU metrics on port 9400 in Prometheus format. Key metrics include GPU utilization (%), memory utilization (%), temperature, power draw, and framebuffer memory usage. DCGM Exporter requires the `--gpus all` and `--cap-add SYS_ADMIN` flags but is fully compatible with the Docker-in-VM architecture established in Phase 6.

The monitoring architecture uses a pull model: Prometheus scrapes metrics from exporters at configurable intervals. This requires the SuperLink VM to expose port(s) for Flower training metrics and the SuperNode VM to expose port 9400 for GPU metrics. Grafana connects to Prometheus as a data source and renders pre-built dashboards. Alertmanager handles alert routing and notification.

**Primary recommendation:** Define a two-tier monitoring spec: OBS-01 covers structured logging (JSON log format, FL training event taxonomy, log levels) requiring zero additional infrastructure. OBS-02 covers the full Prometheus/Grafana stack (custom Flower metrics exporter in ServerApp, DCGM Exporter sidecar on SuperNodes, Grafana dashboard JSON definitions, Prometheus alerting rules). Both tiers are additive -- OBS-01 works standalone; OBS-02 builds on it.

## Standard Stack

### Core

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Python `logging` (Flower's `flwr` logger) | stdlib | Structured logging for FL events | Flower already uses this; extending it avoids external dependencies |
| `prometheus_client` | 0.21+ | Custom Prometheus metrics exporter in ServerApp | Official Prometheus Python client library; standard for Python metric exporters |
| NVIDIA DCGM Exporter | 4.5.1-4.8.0 | GPU metrics in Prometheus format | Official NVIDIA solution; production-grade GPU telemetry for Docker/Kubernetes |
| Prometheus | 2.53+ | Metrics collection and storage (time-series DB) | Industry standard for pull-based metrics; native Grafana integration |
| Grafana | 11+ | Metrics visualization and dashboards | Industry standard for observability dashboards; JSON-provisioned dashboards |
| Alertmanager | 0.28+ | Alert routing and notification | Standard Prometheus companion for alerting; handles grouping, inhibition, silencing |

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| Docker `json-file` log driver | (Docker CE) | Container log capture with rotation | Always -- default Docker logging; structured JSON logs written to stdout are captured automatically |
| Grafana Loki | 3.0+ | Centralized log aggregation | Optional -- when operators want to aggregate logs from multiple VMs into a searchable system |
| Node Exporter | 1.8+ | Host-level VM metrics (CPU, memory, disk, network) | Optional -- when operators want infrastructure metrics alongside FL/GPU metrics |
| cAdvisor | 0.49+ | Container-level resource metrics | Optional -- when operators want per-container CPU/memory metrics within the VM |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| DCGM Exporter | `nvidia_gpu_exporter` (utkuozdemir) | Lighter weight (uses nvidia-smi binary parsing), works on consumer GPUs, but limited maintenance and less comprehensive metrics than DCGM |
| `prometheus_client` in ServerApp | `flwr-monitoring` PyPI package | Third-party package wrapping strategies with Prometheus; but unclear maintenance, limited docs, adds dependency outside Flower core |
| Prometheus + Grafana | OpenTelemetry Collector | OTel is more flexible for multi-signal (metrics+logs+traces) but adds complexity; Prometheus/Grafana is simpler and better documented for this use case |
| JSON structured logging | logfmt | logfmt is 30-40% more compact but less widely supported by log aggregation tools; JSON is universal |
| Grafana Loki | ELK stack (Elasticsearch + Logstash + Kibana) | ELK is more powerful for full-text search but far heavier (Java-based); Loki is lightweight and uses the same query language as Grafana |

### Installation

```bash
# Inside SuperLink VM (monitoring host -- optional sidecar)
pip install prometheus_client  # For custom Flower metrics exporter

# Monitoring infrastructure (separate VM or operator's existing stack)
docker pull prom/prometheus:v2.53.0
docker pull grafana/grafana:11.0.0
docker pull prom/alertmanager:v0.28.0

# Inside SuperNode VM (GPU monitoring sidecar)
docker pull nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless
```

## Architecture Patterns

### Recommended Monitoring Architecture

```
+------------------------------------------------------------------+
|                    Monitoring Infrastructure                       |
|  (Operator-managed: separate VM or existing Prometheus/Grafana)   |
|                                                                   |
|  +------------------+  +------------------+  +-----------------+  |
|  |   Prometheus     |  |    Grafana       |  |  Alertmanager   |  |
|  |   :9090          |  |    :3000         |  |  :9093          |  |
|  |                  |  |                  |  |                 |  |
|  |  scrape_configs: |  |  Dashboards:     |  |  Routes:        |  |
|  |  - fl_training   |  |  - FL Overview   |  |  - email        |  |
|  |  - dcgm_gpu      |  |  - GPU Health    |  |  - webhook      |  |
|  |  - node_exporter |  |  - Client Health |  |  - slack        |  |
|  +------------------+  +------------------+  +-----------------+  |
|           |                     |                    |            |
+-----------|---------------------|--------------------|-----------+
            |                     |                    |
     scrape |              datasource            alert rules
            |
   +--------v--------------------------------------------------+
   |                    SuperLink VM                             |
   |  +----------------------+  +---------------------------+   |
   |  | flower-superlink     |  | fl-metrics-exporter       |   |
   |  | container            |  | (embedded in ServerApp    |   |
   |  | :9092 (Fleet API)    |  |  or sidecar process)      |   |
   |  | :9093 (Control API)  |  | :9101 (/metrics)          |   |
   |  | stdout -> JSON logs  |  |                           |   |
   |  +----------------------+  +---------------------------+   |
   +------------------------------------------------------------+

   +------------------------------------------------------------+
   |                    SuperNode VM (GPU)                       |
   |  +----------------------+  +---------------------------+   |
   |  | flower-supernode     |  | dcgm-exporter             |   |
   |  | container            |  | (sidecar container)       |   |
   |  | stdout -> JSON logs  |  | :9400 (/metrics)          |   |
   |  +----------------------+  +---------------------------+   |
   +------------------------------------------------------------+
```

### Pattern 1: Structured JSON Logging for FL Events

**What:** Extend Flower's Python logger to emit structured JSON log lines for FL training events. Each log entry contains a fixed set of fields (timestamp, level, event type, and event-specific data) enabling machine-parseable log analysis.

**When to use:** Always -- this is the OBS-01 baseline that works without any additional infrastructure.

**Log format specification:**

```json
{
  "timestamp": "2026-02-09T14:30:00.123Z",
  "level": "INFO",
  "logger": "flwr",
  "event": "round_start",
  "data": {
    "round": 5,
    "num_clients_selected": 4,
    "strategy": "FedAvg"
  }
}
```

**FL Event Taxonomy (required events for OBS-01):**

| Event Type | Level | Trigger | Data Fields |
|-----------|-------|---------|-------------|
| `training_start` | INFO | ServerApp main() begins | `strategy`, `num_rounds`, `min_clients` |
| `round_start` | INFO | Strategy selects clients for round N | `round`, `num_clients_selected`, `strategy` |
| `round_end` | INFO | Strategy completes aggregation for round N | `round`, `num_clients_responded`, `aggregated_loss`, `aggregated_accuracy`, `round_duration_seconds` |
| `training_end` | INFO | All rounds complete | `total_rounds`, `final_loss`, `final_accuracy`, `total_duration_seconds` |
| `client_join` | INFO | SuperNode connects to SuperLink | `node_id`, `client_address` |
| `client_leave` | INFO | SuperNode disconnects from SuperLink | `node_id`, `reason` |
| `checkpoint_saved` | INFO | Checkpoint written to disk | `round`, `path`, `size_bytes` |
| `evaluation_result` | INFO | evaluate_fn callback returns | `round`, `loss`, `accuracy`, `num_examples` |
| `client_failure` | WARNING | Client fails during fit/evaluate | `round`, `node_id`, `error_type` |
| `training_stalled` | WARNING | Round exceeded timeout threshold | `round`, `waiting_since_seconds`, `connected_clients`, `required_clients` |
| `gpu_detected` | INFO | GPU validation at SuperNode boot | `gpu_name`, `gpu_memory_mb`, `driver_version` |
| `gpu_unavailable` | WARNING | GPU requested but not available | `fallback_device` |

**Implementation approach:** The spec defines a JSON log formatter class that wraps Flower's `FLOWER_LOGGER` (`flwr` logger name). The formatter intercepts log records and emits them as single-line JSON. This works because Flower uses Python's standard `logging` module, and custom formatters can be attached to the existing console handler.

**Confidence:** HIGH -- Python's logging module formatter API is stable and well-documented. Flower's logger is a standard Python logger.

### Pattern 2: Custom Flower Metrics Exporter (prometheus_client)

**What:** Embed a Prometheus metrics HTTP endpoint in the ServerApp code. After each round, the ServerApp updates Prometheus gauge/counter metrics with the latest training results. Prometheus scrapes this endpoint at its configured interval.

**When to use:** OBS-02 -- when the operator deploys the Prometheus/Grafana stack.

**Metric definitions (Flower training metrics):**

| Prometheus Metric Name | Type | Labels | Description |
|----------------------|------|--------|-------------|
| `fl_round_current` | Gauge | `strategy` | Current training round number |
| `fl_round_total` | Gauge | `strategy` | Total configured rounds |
| `fl_round_duration_seconds` | Histogram | `strategy` | Duration of each training round |
| `fl_aggregated_loss` | Gauge | `strategy`, `round` | Aggregated loss after round |
| `fl_aggregated_accuracy` | Gauge | `strategy`, `round` | Aggregated accuracy after round |
| `fl_clients_connected` | Gauge | -- | Number of currently connected SuperNodes |
| `fl_clients_selected` | Gauge | `round` | Number of clients selected for current round |
| `fl_clients_responded` | Gauge | `round` | Number of clients that responded in current round |
| `fl_clients_failed` | Counter | -- | Total client failures across all rounds |
| `fl_checkpoint_saved_total` | Counter | -- | Total checkpoints saved |
| `fl_training_status` | Gauge | -- | Training status (0=idle, 1=running, 2=complete, 3=failed) |

**Implementation approach:** The `prometheus_client` library provides `start_http_server(port)` to expose a `/metrics` endpoint. The ServerApp code updates metrics after each round using the `evaluate_fn` callback and the `Result` object's `train_metrics_clientapp` and `evaluate_metrics_clientapp` dictionaries.

**Port allocation:** Port 9101 for the Flower metrics exporter (avoids conflict with standard ports: 9090 Prometheus, 9092 Fleet API, 9093 Control API, 9400 DCGM).

**Confidence:** MEDIUM -- the `prometheus_client` library is well-documented and standard. The integration point with Flower's ServerApp (embedding metric updates in evaluate_fn and the strategy factory) is architecturally sound but the exact code needs validation against Flower 1.25.0's callback interface.

### Pattern 3: DCGM Exporter as Sidecar Container on SuperNode

**What:** Run the NVIDIA DCGM Exporter as a second Docker container alongside the Flower SuperNode container on GPU-enabled VMs. DCGM Exporter exposes GPU metrics on port 9400 in Prometheus format.

**When to use:** OBS-02 on SuperNode VMs where `FL_GPU_ENABLED=YES`.

**Docker run command:**

```bash
docker run -d \
  --name dcgm-exporter \
  --restart unless-stopped \
  --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless
```

**Key DCGM metrics for FL training:**

| DCGM Metric Name | Type | Description | Alerting Use |
|------------------|------|-------------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | Gauge | GPU utilization (%) | Stalled training: < 5% with active job |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | Gauge | Memory utilization (%) | Memory pressure detection |
| `DCGM_FI_DEV_FB_FREE` | Gauge | Free framebuffer memory (MiB) | OOM prevention |
| `DCGM_FI_DEV_FB_USED` | Gauge | Used framebuffer memory (MiB) | Memory tracking |
| `DCGM_FI_DEV_GPU_TEMP` | Gauge | GPU temperature (C) | Thermal throttling alert |
| `DCGM_FI_DEV_POWER_USAGE` | Gauge | Power draw (W) | Power anomaly detection |
| `DCGM_FI_DEV_XID_ERRORS` | Gauge | Last XID error value | Hardware error detection |
| `DCGM_FI_DEV_SM_CLOCK` | Gauge | SM clock frequency (MHz) | Clock throttling detection |

**Sidecar lifecycle:** The DCGM Exporter container starts alongside the SuperNode container during bootstrap. It is managed by its own systemd unit (`dcgm-exporter.service`) with `After=flower-supernode.service`. If `FL_GPU_ENABLED=NO` or GPU detection fails, the sidecar is not started.

**Confidence:** HIGH -- DCGM Exporter is a well-documented, official NVIDIA product. The Docker-in-VM architecture supports running multiple containers. Port 9400 is the DCGM standard.

### Pattern 4: Grafana Dashboard Provisioning

**What:** Ship pre-built Grafana dashboard JSON files that operators import into their Grafana instance. Dashboards use Prometheus as the data source and are organized into three focus areas: FL Training Overview, GPU Health, and Client Health.

**When to use:** OBS-02 -- when the operator has Grafana deployed.

**Dashboard provisioning structure:**

```
grafana/
  provisioning/
    datasources/
      prometheus.yaml          # Prometheus data source config
    dashboards/
      dashboards.yaml          # Dashboard provider config
  dashboards/
    fl-training-overview.json  # FL training convergence dashboard
    gpu-health.json            # GPU utilization and health dashboard
    client-health.json         # Client connectivity and health dashboard
```

**Dashboard 1: FL Training Overview**

| Panel | Type | Query (PromQL) | Purpose |
|-------|------|---------------|---------|
| Training Progress | Stat | `fl_round_current / fl_round_total` | Progress bar showing round completion |
| Loss Convergence Curve | Time Series | `fl_aggregated_loss` | Loss over rounds (convergence visualization) |
| Accuracy Convergence Curve | Time Series | `fl_aggregated_accuracy` | Accuracy over rounds |
| Round Duration | Time Series | `rate(fl_round_duration_seconds_sum[5m]) / rate(fl_round_duration_seconds_count[5m])` | Average round duration trend |
| Client Participation | Time Series | `fl_clients_responded` | Clients participating per round |
| Training Status | Stat | `fl_training_status` | Current status (idle/running/complete/failed) |

**Dashboard 2: GPU Health**

| Panel | Type | Query (PromQL) | Purpose |
|-------|------|---------------|---------|
| GPU Utilization | Time Series | `DCGM_FI_DEV_GPU_UTIL` | Per-GPU utilization over time |
| GPU Memory Usage | Time Series | `DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 100` | Memory usage percentage |
| GPU Temperature | Time Series | `DCGM_FI_DEV_GPU_TEMP` | Temperature with threshold lines |
| Power Usage | Time Series | `DCGM_FI_DEV_POWER_USAGE` | Power draw over time |
| XID Errors | Stat | `DCGM_FI_DEV_XID_ERRORS` | Last XID error (0 = no errors) |
| Free Memory | Gauge | `DCGM_FI_DEV_FB_FREE` | Available GPU memory per node |

**Dashboard 3: Client Health**

| Panel | Type | Query (PromQL) | Purpose |
|-------|------|---------------|---------|
| Connected Clients | Stat | `fl_clients_connected` | Current client count |
| Client Failures | Time Series | `rate(fl_clients_failed[5m])` | Client failure rate |
| Client Participation Rate | Time Series | `fl_clients_responded / fl_clients_selected * 100` | Participation percentage |
| Client Response Time | Histogram | `fl_round_duration_seconds` | Distribution of round times |

**Confidence:** MEDIUM -- the PromQL queries and panel types are standard Grafana patterns. The specific metric names depend on the custom exporter implementation defined in Pattern 2. Dashboard JSON files are well-documented in Grafana.

### Pattern 5: Prometheus Alerting Rules

**What:** Define Prometheus alerting rules that detect critical conditions in FL training and GPU health. Rules are shipped as a YAML file that operators add to their Prometheus configuration.

**When to use:** OBS-02 -- when the operator has Prometheus + Alertmanager deployed.

**Alert rule definitions:**

```yaml
groups:
  - name: fl_training_alerts
    rules:
      - alert: FLTrainingStalled
        expr: |
          fl_training_status == 1
          and fl_round_current == fl_round_current offset 10m
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: "FL training stalled -- no round progress in 15 minutes"
          description: "Round {{ $value }} has not progressed. Check client connectivity."

      - alert: FLExcessiveClientDropout
        expr: |
          fl_clients_connected < fl_clients_selected * 0.5
          and fl_training_status == 1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "More than 50% of selected clients have dropped"
          description: "Only {{ $value }} clients connected out of selected."

      - alert: FLClientFailureRate
        expr: rate(fl_clients_failed[10m]) > 0.5
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "High client failure rate"
          description: "Client failures averaging {{ $value }}/sec over 10 minutes."

      - alert: FLTrainingNotStarted
        expr: fl_training_status == 0 and fl_round_total > 0
        for: 30m
        labels:
          severity: warning
        annotations:
          summary: "FL training configured but not started"
          description: "Training has been idle for 30 minutes with rounds configured."

  - name: gpu_health_alerts
    rules:
      - alert: GPUMemoryExhaustion
        expr: |
          DCGM_FI_DEV_FB_FREE
          / (DCGM_FI_DEV_FB_FREE + DCGM_FI_DEV_FB_USED) * 100 < 10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "GPU memory nearly exhausted (< 10% free)"
          description: "GPU {{ $labels.gpu }} on {{ $labels.instance }} has {{ $value }}% free memory."

      - alert: GPUUtilizationDrop
        expr: |
          DCGM_FI_DEV_GPU_UTIL < 5
          and DCGM_FI_DEV_FB_USED > 100
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "GPU allocated but idle"
          description: "GPU {{ $labels.gpu }} has < 5% utilization but {{ $value }}MiB memory allocated. Possible stalled training."

      - alert: GPUTemperatureCritical
        expr: DCGM_FI_DEV_GPU_TEMP > 90
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "GPU temperature critical (> 90C)"
          description: "GPU {{ $labels.gpu }} at {{ $value }}C. Risk of thermal throttling or shutdown."

      - alert: GPUXIDError
        expr: DCGM_FI_DEV_XID_ERRORS > 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "GPU XID error detected"
          description: "GPU {{ $labels.gpu }} reported XID error {{ $value }}. May indicate hardware failure."
```

**Confidence:** HIGH for GPU alerts (DCGM metric names are well-documented). MEDIUM for FL training alerts (depend on custom metric names from Pattern 2).

### Anti-Patterns to Avoid

- **Pushing metrics from inside the container:** Prometheus uses a pull model. The exporter exposes an HTTP endpoint; Prometheus scrapes it. Do not build a push-based metrics forwarder.
- **Running Prometheus/Grafana inside the appliance VM:** Monitoring infrastructure should be operator-managed, not embedded in the FL appliance. The appliance only runs exporters (metrics sources).
- **Parsing nvidia-smi output as a substitute for DCGM:** While nvidia-smi parsing works for basic checks (Phase 6 validation scripts), it is not suitable for continuous metrics. DCGM provides structured, timestamped metrics with consistent field names.
- **Adding prometheus_client as a runtime dependency in the Flower Docker image:** The metrics exporter should be embedded in the ServerApp FAB code (which runs inside the container via pip install at FAB build time), not added to the base Flower Docker image.
- **High-cardinality labels on metrics:** Do not use `round` as a label on most metrics (creates unbounded cardinality). Use it only for gauges that are updated in-place per round, not for counters or histograms.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GPU metrics collection | Custom nvidia-smi parser cron job | DCGM Exporter sidecar container | DCGM provides 50+ GPU metrics with consistent naming, proper timestamps, and Prometheus format. Parsing nvidia-smi misses edge cases (multi-GPU, MIG, error states). |
| Prometheus metrics endpoint | Custom HTTP server with metric formatting | `prometheus_client` Python library | Library handles metric types (Gauge, Counter, Histogram), content types, encoding, and thread safety. Custom implementation will have bugs. |
| Log aggregation | Custom log shipping scripts | Docker json-file driver + optional Loki | Docker's default log driver captures stdout/stderr with timestamps and rotation. Loki adds centralized search. |
| Dashboard definitions | Manual Grafana UI configuration | JSON-provisioned dashboards | JSON files are version-controlled, reproducible, and can be imported into any Grafana instance. Manual configuration is not repeatable. |
| Alert routing | Custom alert scripts polling metrics | Prometheus Alertmanager | Alertmanager handles grouping, deduplication, silencing, inhibition, and multi-channel routing. Custom scripts will miss edge cases. |
| Time-series storage | Custom metric database | Prometheus TSDB | Prometheus is purpose-built for time-series metrics with efficient storage, PromQL query language, and 15-second default resolution. |

**Key insight:** The monitoring spec defines WHAT metrics to expose and WHERE, not how to build the monitoring infrastructure. Prometheus, Grafana, and Alertmanager are operator-managed infrastructure. The appliance only provides exporters (data sources) and dashboard/alert definitions (configuration as code).

## Common Pitfalls

### Pitfall 1: DCGM Exporter Requires SYS_ADMIN Capability

**What goes wrong:** DCGM Exporter container starts but reports no metrics or crashes with permission errors.

**Why it happens:** DCGM needs `SYS_ADMIN` capability to access GPU management interfaces. Without it, the DCGM library cannot initialize.

**How to avoid:** Always include `--cap-add SYS_ADMIN` in the Docker run command for DCGM Exporter. This is documented but easy to miss.

```bash
docker run -d --gpus all --cap-add SYS_ADMIN -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless
```

**Warning signs:** Empty `/metrics` response, container exit with DCGM initialization error.

**Confidence:** HIGH -- documented in DCGM Exporter README.

### Pitfall 2: DCGM Version Mismatch with Host Driver

**What goes wrong:** DCGM Exporter starts but some metrics are missing or report incorrect values.

**Why it happens:** The DCGM client library version inside the exporter container must be >= the DCGM/driver version on the host. A container with an older DCGM version talking to a newer host driver may have API incompatibilities.

**How to avoid:** Use the latest DCGM Exporter image. Document the tested combination (DCGM Exporter 4.5.1 with NVIDIA driver 545+). Pin the exporter version in the spec.

**Warning signs:** Missing metrics fields, DCGM initialization warnings in container logs.

**Confidence:** MEDIUM -- documented in DCGM compatibility notes, exact version combinations vary.

### Pitfall 3: Prometheus Cannot Scrape Metrics Inside VMs

**What goes wrong:** Prometheus is deployed but cannot reach the metrics endpoints on port 9101 (FL metrics) or 9400 (DCGM) inside the appliance VMs.

**Why it happens:** VM firewall rules or OpenNebula security groups block inbound connections on non-standard ports. The Docker port mapping publishes to the VM's interface, but network policies may block external access.

**How to avoid:** The spec must document required port openings for monitoring. The operator's Prometheus server needs network access to:
- SuperLink VM: port 9101 (Flower training metrics)
- SuperNode VMs: port 9400 (DCGM GPU metrics)

These are optional ports that are only needed when OBS-02 monitoring is enabled.

**Warning signs:** Prometheus target shows "down" status, `context deadline exceeded` errors.

**Confidence:** HIGH -- standard networking consideration for any Prometheus deployment.

### Pitfall 4: Flower Logger Format Conflicts with JSON Wrapper

**What goes wrong:** JSON-formatted log lines contain double-encoded messages or broken JSON because Flower's internal log format string includes pipe characters and brackets that interfere with JSON serialization.

**Why it happens:** Flower's default log format is `"%(levelname)s %(name)s %(asctime)s | %(filename)s:%(lineno)d | %(message)s"`. If a JSON formatter wraps the already-formatted message string, it produces nested formatting artifacts.

**How to avoid:** The JSON formatter must replace Flower's default handler formatter entirely (not wrap it). The formatter should construct the JSON from the raw `LogRecord` attributes (`levelname`, `asctime`, `message`, `filename`, `lineno`), not from the pre-formatted output.

```python
class FlowerJSONFormatter(logging.Formatter):
    def format(self, record):
        log_entry = {
            "timestamp": self.formatTime(record, datefmt="%Y-%m-%dT%H:%M:%S.%fZ"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "file": f"{record.filename}:{record.lineno}",
        }
        return json.dumps(log_entry)
```

**Warning signs:** Log lines containing `{` or `|` inside message values, JSON parse errors in log aggregation.

**Confidence:** HIGH -- standard Python logging formatter pattern.

### Pitfall 5: Unbounded Metric Cardinality from Round Labels

**What goes wrong:** Prometheus memory usage grows linearly with training rounds because each round creates new time-series entries.

**Why it happens:** If metrics use `round` as a label (e.g., `fl_aggregated_loss{round="1"}`, `fl_aggregated_loss{round="2"}`, ...), each round creates a new time series. A 1000-round training job creates 1000 time series per metric.

**How to avoid:** Use `round` labels only on gauges that are updated in-place (overwriting the previous value). For metrics that track per-round values, use the Prometheus pattern of updating a single gauge and relying on Prometheus's time-series collection to track the history:

```python
# GOOD: Single gauge, updated each round. Prometheus stores historical values.
fl_aggregated_loss = Gauge("fl_aggregated_loss", "Current aggregated loss", ["strategy"])
fl_aggregated_loss.labels(strategy="FedAvg").set(0.234)

# BAD: Label per round creates unbounded cardinality
fl_aggregated_loss = Gauge("fl_aggregated_loss", "Loss per round", ["strategy", "round"])
fl_aggregated_loss.labels(strategy="FedAvg", round="1").set(0.5)
fl_aggregated_loss.labels(strategy="FedAvg", round="2").set(0.4)
# ...creates 1000 series for 1000 rounds
```

**Warning signs:** Prometheus `scrape_samples_scraped` increasing over time, Prometheus OOM.

**Confidence:** HIGH -- well-known Prometheus anti-pattern.

### Pitfall 6: Monitoring Ports Conflict with Flower Service Ports

**What goes wrong:** The Flower metrics exporter fails to bind to its port because another Flower process is already using it.

**Why it happens:** Port assignment overlap. Flower uses 9091 (ServerAppIo), 9092 (Fleet API), 9093 (Control API). Prometheus itself defaults to 9090. DCGM uses 9400.

**How to avoid:** Use port 9101 for the FL metrics exporter (avoiding the 9090-9093 range used by Flower and Prometheus). Document all port assignments in the spec.

| Port | Service | VM |
|------|---------|-----|
| 9090 | Prometheus (operator) | Monitoring VM |
| 9091 | ServerAppIo (Flower) | SuperLink |
| 9092 | Fleet API (Flower) | SuperLink |
| 9093 | Control API (Flower) | SuperLink |
| 9101 | FL metrics exporter | SuperLink |
| 9400 | DCGM Exporter | SuperNode |

**Warning signs:** `Address already in use` error on exporter startup.

**Confidence:** HIGH -- straightforward port allocation.

## Code Examples

### JSON Log Formatter for Flower

```python
"""Structured JSON log formatter for Flower FL training events.

Replaces Flower's default text log format with single-line JSON entries.
Attach to the flwr logger's console handler during ServerApp/ClientApp initialization.
"""
import json
import logging
import time
from typing import Any

class FlowerJSONFormatter(logging.Formatter):
    """Format log records as single-line JSON for structured logging (OBS-01)."""

    def __init__(self, role: str = "superlink"):
        super().__init__()
        self.role = role

    def format(self, record: logging.LogRecord) -> str:
        log_entry: dict[str, Any] = {
            "timestamp": time.strftime(
                "%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)
            ) + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "logger": record.name,
            "role": self.role,
            "message": record.getMessage(),
            "source": f"{record.filename}:{record.lineno}",
        }
        # Include structured event data if present
        if hasattr(record, "fl_event"):
            log_entry["event"] = record.fl_event
        if hasattr(record, "fl_data"):
            log_entry["data"] = record.fl_data
        return json.dumps(log_entry, separators=(",", ":"))


def configure_json_logging(role: str = "superlink") -> None:
    """Replace Flower's default log format with structured JSON.

    Call during appliance boot, before ServerApp/ClientApp starts.
    """
    flower_logger = logging.getLogger("flwr")
    formatter = FlowerJSONFormatter(role=role)

    for handler in flower_logger.handlers:
        if isinstance(handler, logging.StreamHandler):
            handler.setFormatter(formatter)
```

**Source:** Based on Python `logging.Formatter` API and Flower's logger module structure (`flwr.common.logger`).

### FL Training Event Logging Helper

```python
"""Helper functions for emitting structured FL training events.

These functions add fl_event and fl_data attributes to log records
for structured JSON output.
"""
import logging

logger = logging.getLogger("flwr")


def log_fl_event(event: str, data: dict, level: int = logging.INFO) -> None:
    """Log a structured FL training event."""
    record = logger.makeRecord(
        name=logger.name,
        level=level,
        fn="",
        lno=0,
        msg=f"{event}: {data}",
        args=(),
        exc_info=None,
    )
    record.fl_event = event  # type: ignore[attr-defined]
    record.fl_data = data  # type: ignore[attr-defined]
    logger.handle(record)


# Usage in ServerApp:
def on_round_end(server_round: int, loss: float, accuracy: float,
                 num_clients: int, duration: float) -> None:
    log_fl_event("round_end", {
        "round": server_round,
        "aggregated_loss": round(loss, 6),
        "aggregated_accuracy": round(accuracy, 6),
        "num_clients_responded": num_clients,
        "round_duration_seconds": round(duration, 2),
    })
```

### Prometheus Metrics Exporter (ServerApp Integration)

```python
"""Flower training metrics exporter for Prometheus (OBS-02).

Exposes FL training metrics on an HTTP endpoint for Prometheus scraping.
Embedded in the ServerApp FAB code; activated when FL_METRICS_ENABLED=YES.
"""
from prometheus_client import (
    Counter, Gauge, Histogram, start_http_server,
)

# --- Metric Definitions ---

FL_ROUND_CURRENT = Gauge(
    "fl_round_current", "Current training round number",
    ["strategy"]
)
FL_ROUND_TOTAL = Gauge(
    "fl_round_total", "Total configured training rounds",
    ["strategy"]
)
FL_ROUND_DURATION = Histogram(
    "fl_round_duration_seconds", "Duration of training rounds",
    ["strategy"],
    buckets=[1, 5, 10, 30, 60, 120, 300, 600]
)
FL_AGGREGATED_LOSS = Gauge(
    "fl_aggregated_loss", "Aggregated loss after latest round",
    ["strategy"]
)
FL_AGGREGATED_ACCURACY = Gauge(
    "fl_aggregated_accuracy", "Aggregated accuracy after latest round",
    ["strategy"]
)
FL_CLIENTS_CONNECTED = Gauge(
    "fl_clients_connected", "Number of connected SuperNodes"
)
FL_CLIENTS_SELECTED = Gauge(
    "fl_clients_selected", "Clients selected for current round"
)
FL_CLIENTS_RESPONDED = Gauge(
    "fl_clients_responded", "Clients that responded in current round"
)
FL_CLIENTS_FAILED = Counter(
    "fl_clients_failed", "Total client failures"
)
FL_CHECKPOINT_SAVED = Counter(
    "fl_checkpoint_saved_total", "Total checkpoints saved"
)
FL_TRAINING_STATUS = Gauge(
    "fl_training_status", "Training status: 0=idle, 1=running, 2=complete, 3=failed"
)


def start_metrics_server(port: int = 9101) -> None:
    """Start the Prometheus metrics HTTP server on the given port."""
    start_http_server(port)


def update_round_metrics(
    strategy: str,
    round_num: int,
    total_rounds: int,
    loss: float,
    accuracy: float,
    num_selected: int,
    num_responded: int,
    duration_seconds: float,
) -> None:
    """Update Prometheus metrics after a training round."""
    FL_ROUND_CURRENT.labels(strategy=strategy).set(round_num)
    FL_ROUND_TOTAL.labels(strategy=strategy).set(total_rounds)
    FL_ROUND_DURATION.labels(strategy=strategy).observe(duration_seconds)
    FL_AGGREGATED_LOSS.labels(strategy=strategy).set(loss)
    FL_AGGREGATED_ACCURACY.labels(strategy=strategy).set(accuracy)
    FL_CLIENTS_SELECTED.set(num_selected)
    FL_CLIENTS_RESPONDED.set(num_responded)
```

**Source:** Based on `prometheus_client` [official documentation](https://github.com/prometheus/client_python).

### DCGM Exporter Systemd Unit (SuperNode Sidecar)

```ini
# /etc/systemd/system/dcgm-exporter.service
# Generated by configure.sh when FL_GPU_ENABLED=YES and FL_METRICS_ENABLED=YES

[Unit]
Description=NVIDIA DCGM Exporter for GPU Metrics
After=docker.service flower-supernode.service
Requires=docker.service
PartOf=flower-supernode.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStartPre=-/usr/bin/docker rm -f dcgm-exporter
ExecStart=/usr/bin/docker run \
  --name dcgm-exporter \
  --gpus all \
  --cap-add SYS_ADMIN \
  -p 9400:9400 \
  nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless
ExecStop=/usr/bin/docker stop dcgm-exporter

[Install]
WantedBy=multi-user.target
```

### Prometheus Scrape Configuration (Operator Reference)

```yaml
# prometheus.yml snippet -- add to operator's existing Prometheus config
# Static target discovery (IP addresses known at deployment time)

scrape_configs:
  - job_name: "fl_training"
    scrape_interval: 15s
    static_configs:
      - targets:
          - "<superlink_ip>:9101"
        labels:
          role: "superlink"
          deployment: "flower-opennebula"

  - job_name: "dcgm_gpu"
    scrape_interval: 15s
    static_configs:
      - targets:
          - "<supernode_1_ip>:9400"
          - "<supernode_2_ip>:9400"
        labels:
          role: "supernode"
          deployment: "flower-opennebula"
```

### Grafana Datasource Provisioning

```yaml
# grafana/provisioning/datasources/prometheus.yaml
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

### Grafana Dashboard Provider

```yaml
# grafana/provisioning/dashboards/dashboards.yaml
apiVersion: 1
providers:
  - name: "Flower-OpenNebula"
    orgId: 1
    folder: "Flower FL Monitoring"
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `nvidia-docker2` for GPU monitoring containers | NVIDIA Container Toolkit + `--gpus` flag | 2020 | DCGM Exporter uses `--gpus all` with Container Toolkit. Old `--runtime=nvidia` still works but is deprecated. |
| nvidia-smi parsing for GPU metrics | DCGM Exporter for Prometheus | DCGM 2.x (2020+) | DCGM provides structured metrics in Prometheus format. nvidia-smi parsing is fragile and lacks timestamps. |
| Custom log aggregation pipelines | Docker json-file driver + optional Loki | Loki 2.0 (2021+) | Docker captures stdout/stderr by default. Loki adds centralized querying without heavy infrastructure (vs ELK). |
| Grafana manual dashboard configuration | JSON-provisioned dashboards via API/filesystem | Grafana 5.0 (2018+) | Provisioned dashboards are reproducible, version-controlled, and automatically loaded on Grafana startup. |
| `flwr.server.start_server()` with no metrics | `ServerApp` + `Result` object with per-round metrics | Flower 1.20+ | The Result object provides structured access to train_metrics, evaluate_metrics indexed by round number. |
| Ray-based simulation monitoring | Production SuperLink/SuperNode monitoring (custom) | Not built yet in Flower | Flower's built-in monitoring only covers Ray simulations. Production monitoring requires custom exporters (this spec). |

**Deprecated/outdated:**
- `flwr.server.start_server()`: Deprecated in Flower 1.20+. Use `ServerApp` + `@app.main()` with `strategy.start()`. Metrics access through `Result` object.
- `nvidia-docker2` package: Deprecated. Use `nvidia-container-toolkit` package instead.
- Grafana Promtail: Superseded by Grafana Alloy as the recommended log collector for Loki.

## New Contextualization Variables (Phase 8)

### SuperLink Variables

| Variable | USER_INPUT | Type | Default | Validation | Purpose |
|----------|-----------|------|---------|------------|---------|
| `FL_METRICS_ENABLED` | `O\|boolean\|Enable Prometheus metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO` | Master switch for OBS-02 Prometheus metrics on SuperLink |
| `FL_METRICS_PORT` | `O\|number\|Prometheus metrics exporter port\|\|9101` | number | `9101` | Integer in range 1024-65535; must not conflict with 9091-9093 | Port for Flower training metrics HTTP endpoint |

### SuperNode Variables

| Variable | USER_INPUT | Type | Default | Validation | Purpose |
|----------|-----------|------|---------|------------|---------|
| `FL_DCGM_ENABLED` | `O\|boolean\|Enable DCGM GPU metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO`; requires `FL_GPU_ENABLED=YES` | Master switch for OBS-02 DCGM Exporter sidecar |

### Service-Level Variables (OneFlow)

| Variable | USER_INPUT | Type | Default | Validation | Purpose |
|----------|-----------|------|---------|------------|---------|
| `FL_LOG_FORMAT` | `O\|list\|Log output format\|text,json\|text` | list | `text` | One of: `text`, `json` | OBS-01: Switch between Flower's default text format and structured JSON |

### Variable Interaction Notes

- `FL_METRICS_ENABLED=YES` on SuperLink: starts the `prometheus_client` HTTP server on `FL_METRICS_PORT`. The ServerApp FAB must include `prometheus_client` in its dependencies.
- `FL_DCGM_ENABLED=YES` on SuperNode: starts the DCGM Exporter sidecar container. Requires `FL_GPU_ENABLED=YES` (Phase 6). If GPU is not available, DCGM is not started (warning logged).
- `FL_LOG_FORMAT=json`: replaces Flower's default text formatter with the `FlowerJSONFormatter`. Applies to both SuperLink and SuperNode. Affects all log output including Flower internal logs.
- `FL_LOG_LEVEL` (existing, Phase 1): controls verbosity. Unchanged but interacts with the new JSON format. In JSON mode, the same log levels apply.

## Open Questions

1. **How to get per-round client count from SuperLink in real-time?**
   - What we know: The `Result` object contains per-round metrics after training completes. The strategy callbacks (`aggregate_fit`, `aggregate_evaluate`) have access to per-round results during training.
   - What's unclear: How to expose real-time connected client count from the SuperLink process. The Control API may expose this, but the exact endpoint and response format need verification against Flower 1.25.0.
   - Recommendation: Start with round-level metrics from the strategy callbacks. If real-time client count is needed, investigate the SuperLink Control API (`localhost:9093`) during implementation.
   - **Confidence:** LOW -- the Control API surface is not well-documented for programmatic metric extraction.

2. **DCGM Exporter image size and pre-baking strategy**
   - What we know: The DCGM Exporter image is ~200-300 MB. The SuperNode QCOW2 already has the Flower SuperNode image pre-pulled (~2 GB).
   - What's unclear: Whether pre-pulling the DCGM Exporter image during QCOW2 build is feasible within the 3 GB size target, or if it should be pulled at boot time when `FL_DCGM_ENABLED=YES`.
   - Recommendation: Boot-time pull for DCGM Exporter (not pre-baked). This keeps the base QCOW2 size stable. DCGM is an optional monitoring addon -- pulling on demand is acceptable.
   - **Confidence:** MEDIUM -- size estimates need validation.

3. **flwr-monitoring third-party package maturity**
   - What we know: A `flwr-monitoring` package exists on PyPI that wraps Flower strategies with Prometheus monitoring.
   - What's unclear: Package maintenance status, version compatibility with Flower 1.25.0, the exact metrics it exposes, and whether it works with the modern ServerApp API.
   - Recommendation: Do NOT depend on `flwr-monitoring`. Build the custom exporter using `prometheus_client` directly. This avoids a third-party dependency of unknown quality.
   - **Confidence:** LOW -- could not fetch package documentation; unclear maintenance status.

4. **Prometheus service discovery for dynamic SuperNode scaling**
   - What we know: Static target configuration in `prometheus.yml` works for fixed deployments. OneFlow can scale SuperNodes dynamically.
   - What's unclear: How to automatically update Prometheus targets when SuperNodes scale up/down.
   - Recommendation: Document static target configuration as the default. Note that operators with dynamic environments can use Prometheus file-based service discovery (`file_sd_configs`) with a script that queries OneFlow/OneGate for current VM IPs. Full dynamic discovery is a Phase 9 concern.
   - **Confidence:** MEDIUM -- static targets are well-documented; dynamic discovery via OneFlow is novel integration.

## Sources

### Primary (HIGH confidence)
- [Flower logging configuration](https://flower.ai/docs/framework/how-to-configure-logging.html) -- FLWR_LOG_LEVEL, logger configuration
- [Flower logger source code](https://flower.ai/docs/framework/_modules/flwr/common/logger.html) -- Logger module internals, FLOWER_LOGGER name, format strings
- [Flower Result API](https://flower.ai/docs/framework/ref-api/flwr.serverapp.strategy.Result.html) -- Result class with per-round metrics dictionaries
- [Flower aggregate evaluation results](https://flower.ai/docs/framework/how-to-aggregate-evaluation-results.html) -- evaluate_metrics_aggr_fn, train_metrics_aggr_fn callbacks
- [Flower custom metrics example](https://flower.ai/docs/examples/custom-metrics.html) -- Client-side metric reporting pattern
- [NVIDIA DCGM Exporter GitHub](https://github.com/NVIDIA/dcgm-exporter) -- Docker run command, metrics, configuration, port 9400
- [NVIDIA DCGM Exporter docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/dcgm-exporter.html) -- Official documentation
- [NVIDIA DCGM Grafana dashboard 12239](https://grafana.com/grafana/dashboards/12239-nvidia-dcgm-exporter-dashboard/) -- Pre-built GPU dashboard
- [Prometheus alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/) -- Rule syntax and configuration
- [Grafana dashboard provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/) -- JSON provisioning, datasource configuration
- [prometheus/client_python](https://github.com/prometheus/client_python) -- Official Prometheus Python client library
- [Docker json-file logging driver](https://docs.docker.com/engine/logging/drivers/json-file/) -- Default Docker log driver behavior

### Secondary (MEDIUM confidence)
- [Flower simulation monitoring blog](https://flower.ai/blog/2023-02-06-monitoring-simulation-in-flower/) -- Ray-based simulation monitoring (not production SuperLink)
- [HackerNoon: Prometheus Alertmanager on GPUs](https://hackernoon.com/setting-up-prometheus-alertmanager-on-gpus-for-improved-ml-lifecycle) -- GPU alerting patterns for ML
- [Awesome Prometheus Alerts](https://samber.github.io/awesome-prometheus-alerts/rules.html) -- Community alerting rule collection
- [dockprom stack](https://github.com/stefanprodan/dockprom) -- Reference Docker Compose monitoring stack (Prometheus + Grafana + Node Exporter + cAdvisor + Alertmanager)
- [Grafana Loki Docker driver](https://grafana.com/docs/loki/latest/send-data/docker-driver/) -- Log aggregation for Docker containers

### Tertiary (LOW confidence)
- [flwr-monitoring PyPI](https://pypi.org/project/flwr-monitoring/) -- Third-party package (could not fetch documentation; maintenance status unclear)
- [nvidia_gpu_exporter](https://github.com/utkuozdemir/nvidia_gpu_exporter) -- Community nvidia-smi-based exporter (limited maintenance)

## Metadata

**Confidence breakdown:**
- Structured logging (OBS-01): HIGH -- Python logging formatter API is stable; Flower's logger is standard Python logging
- Prometheus metrics exporter: MEDIUM -- prometheus_client library is well-documented; integration point with Flower ServerApp evaluate_fn needs implementation validation
- DCGM Exporter (GPU metrics): HIGH -- official NVIDIA product with clear Docker deployment pattern
- Grafana dashboards: MEDIUM -- standard Grafana provisioning; PromQL queries depend on custom metric names
- Alerting rules: MEDIUM -- standard Prometheus alerting syntax; FL-specific thresholds need tuning in practice
- New contextualization variables: HIGH -- follows established Phase 1-7 variable design patterns

**Research date:** 2026-02-09
**Valid until:** 2026-03-09 (30 days -- monitoring tools are stable; DCGM Exporter updates monthly)
