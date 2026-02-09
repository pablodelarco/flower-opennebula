# Monitoring and Observability

**Requirements:** OBS-01, OBS-02
**Phase:** 08 - Monitoring and Observability
**Status:** Specification

---

## 1. Purpose and Scope

This section defines the complete monitoring and observability stack for the Flower-OpenNebula federated learning appliances. The stack uses a two-tier approach that balances simplicity with operational depth.

### Two-Tier Monitoring Architecture

**Tier 1 (OBS-01): Structured JSON Logging.** Extends Flower's Python logger with a structured JSON formatter that emits machine-parseable log lines for 12 FL training event types. Zero additional infrastructure required -- works standalone with Docker's default `json-file` log driver. Every deployment gets Tier 1 automatically when `FL_LOG_FORMAT=json` is set.

**Tier 2 (OBS-02): Prometheus/Grafana Monitoring Stack.** Full metrics pipeline with a custom Flower training metrics exporter (11 Prometheus metrics on port 9101), NVIDIA DCGM Exporter sidecar for GPU metrics (8 GPU metrics on port 9400), three pre-built Grafana dashboards, and eight alerting rules (4 FL training + 4 GPU health). Builds on Tier 1. Requires operator-managed monitoring infrastructure (Prometheus, Grafana, Alertmanager) deployed outside the appliance VMs.

### Key Architectural Principle

Appliances run EXPORTERS (data sources). Monitoring infrastructure (Prometheus, Grafana, Alertmanager) is operator-managed and NOT embedded in the appliance VMs. The appliance VMs are immutable (Phase 1 design principle) and dedicated to FL training. Running monitoring daemons alongside training would create resource contention and violate the single-concern design.

### Cross-References

- `spec/01-superlink-appliance.md` -- SuperLink boot sequence (Section 6), Docker container config (Section 7), contextualization (Section 12).
- `spec/02-supernode-appliance.md` -- SuperNode boot sequence (Section 7), GPU detection at Step 9 (Section 7a), Docker config (Section 8).
- `spec/09-training-configuration.md` -- Strategy selection architecture (Section 3), checkpoint evaluate_fn (Section 6), STRATEGY_MAP factory for metric integration points.
- `spec/10-gpu-passthrough.md` -- GPU passthrough stack (Section 2), NVIDIA Container Toolkit (Section 7), FL_GPU_ENABLED variable.
- `spec/03-contextualization-reference.md` -- Variable definitions (Sections 3-4), USER_INPUT format (Section 2), validation strategy (Section 8).

### What This Spec Does NOT Cover

- **Log aggregation (Grafana Loki):** Optional operator addition for centralized log search. Not specified because it is infrastructure-level, not appliance-level.
- **Host-level metrics (Node Exporter):** VM CPU, memory, disk metrics. Useful but orthogonal to FL-specific monitoring.
- **Container metrics (cAdvisor):** Per-container resource usage. Useful but adds complexity beyond the core FL monitoring scope.
- **Flower simulation monitoring:** Flower's built-in monitoring covers Ray-based simulations only, not production SuperLink/SuperNode deployments.

These are mentioned as optional operator additions in the Prometheus scrape configuration (Section 7) but are not part of the core specification.

---

## 2. Monitoring Architecture Diagram

```
+------------------------------------------------------------------+
|                    Monitoring Infrastructure                       |
|           (Operator-managed: separate VM or existing stack)        |
|                                                                    |
|  +------------------+  +------------------+  +-----------------+   |
|  |   Prometheus     |  |    Grafana       |  |  Alertmanager   |   |
|  |   :9090          |  |    :3000         |  |  :9093*         |   |
|  |                  |  |                  |  |                 |   |
|  |  scrape_configs: |  |  Dashboards:     |  |  Routes:        |   |
|  |  - fl_training   |  |  - FL Overview   |  |  - email        |   |
|  |  - dcgm_gpu      |  |  - GPU Health    |  |  - webhook      |   |
|  +--------+---------+  |  - Client Health |  |  - slack        |   |
|           |             +------------------+  +-----------------+   |
+-----------|-------------------------------------------------+------+
            |                                                 |
     scrape |                                          alert rules
            |
   +--------v-------------------------------------------------+
   |                    SuperLink VM                            |
   |  +----------------------+  +----------------------------+ |
   |  | flower-superlink     |  | fl-metrics-exporter        | |
   |  | container            |  | (embedded in ServerApp FAB)| |
   |  | :9091 (ServerAppIo)  |  | :9101 (/metrics)           | |
   |  | :9092 (Fleet API)    |  |                            | |
   |  | :9093 (Control API)  |  |                            | |
   |  | stdout -> JSON logs  |  +----------------------------+ |
   |  +----------------------+                                  |
   +------------------------------------------------------------+

   +------------------------------------------------------------+
   |                  SuperNode VM (GPU)                         |
   |  +----------------------+  +----------------------------+  |
   |  | flower-supernode     |  | dcgm-exporter              |  |
   |  | container            |  | (sidecar container)        |  |
   |  | stdout -> JSON logs  |  | :9400 (/metrics)           |  |
   |  +----------------------+  +----------------------------+  |
   +------------------------------------------------------------+

* Alertmanager port 9093 is on the Monitoring VM, NOT on the SuperLink.
  SuperLink port 9093 is the Flower Control API. These do not conflict
  because they are on different VMs.
```

### Port Allocation Table

All ports used by the appliance and monitoring components. This table documents every port to prevent conflicts.

| Port | Service | VM | Notes |
|------|---------|-----|-------|
| 9090 | Prometheus | Monitoring (operator) | NOT on appliance VMs |
| 9091 | ServerAppIo (Flower) | SuperLink | Existing Phase 1 |
| 9092 | Fleet API (Flower) | SuperLink | Existing Phase 1 -- primary data plane |
| 9093 | Control API (Flower) | SuperLink | Existing Phase 1 -- CLI management |
| 9101 | FL metrics exporter | SuperLink | New Phase 8 -- Prometheus metrics endpoint |
| 9400 | DCGM Exporter | SuperNode | New Phase 8 -- GPU metrics endpoint |
| 3000 | Grafana | Monitoring (operator) | NOT on appliance VMs |

**Port 9093 disambiguation:** Flower's Control API (SuperLink:9093) and Prometheus Alertmanager (Monitoring:9093) share the same port number but run on different VMs. There is no conflict. The Alertmanager is never deployed on the SuperLink VM.

---

## 3. Tier 1 -- Structured JSON Logging (OBS-01)

Structured JSON logging provides machine-parseable log output for FL training events. It requires zero additional infrastructure -- Docker's default `json-file` log driver captures container stdout with timestamps and rotation.

### 3.1 JSON Log Format Specification

Each log entry is a single-line JSON object with the following fields:

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `timestamp` | string (ISO 8601 UTC) | Yes | Event timestamp in `YYYY-MM-DDTHH:MM:SS.mmmZ` format |
| `level` | string | Yes | Log level: `DEBUG`, `INFO`, `WARNING`, `ERROR` |
| `logger` | string | Yes | Logger name: `flwr` (Flower's standard logger) |
| `role` | string | Yes | Appliance role: `superlink` or `supernode` |
| `event` | string | Conditional | FL event type (present when `fl_event` attribute is set on the log record) |
| `data` | object | Conditional | Event-specific data dictionary (present when `fl_data` attribute is set) |
| `message` | string | Yes | Human-readable log message |
| `source` | string | Yes | Source location: `filename:lineno` |

**Example JSON log line:**

```json
{"timestamp":"2026-02-09T14:30:05.123Z","level":"INFO","logger":"flwr","role":"superlink","event":"round_end","data":{"round":5,"num_clients_responded":4,"aggregated_loss":0.234,"aggregated_accuracy":0.891,"round_duration_seconds":12.45},"message":"round_end: {'round': 5, 'num_clients_responded': 4, 'aggregated_loss': 0.234, 'aggregated_accuracy': 0.891, 'round_duration_seconds': 12.45}","source":"server_app.py:87"}
```

### 3.2 FL Event Taxonomy

The spec defines 12 FL training event types that cover the complete training lifecycle from start to finish, plus GPU detection events at boot.

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

### 3.3 Implementation Approach

The JSON formatter replaces Flower's default text handler formatter on the `flwr` logger. It constructs JSON from raw `LogRecord` attributes (not the pre-formatted string), preventing double-encoding artifacts.

**FlowerJSONFormatter reference implementation:**

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

**Key design decisions:**

- The formatter constructs JSON from raw `LogRecord` attributes (`levelname`, `created`, `message`, `filename`, `lineno`) -- NOT from the pre-formatted output string. This prevents the double-encoding pitfall where Flower's pipe-delimited format string interferes with JSON serialization.
- `fl_event` and `fl_data` are custom attributes added to the `LogRecord` by the `log_fl_event()` helper. Standard Flower log messages (without these attributes) are still formatted as JSON, just without the `event` and `data` fields.
- The `role` parameter is set at formatter initialization time based on the appliance type.

**log_fl_event() helper function:**

```python
"""Helper for emitting structured FL training events.

Adds fl_event and fl_data attributes to log records
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
```

### 3.4 Docker Log Capture

Flower containers write to stdout. Docker's default `json-file` log driver captures this output with timestamps and rotation.

**Default Docker log configuration:**
- Max size: 100 MB per log file.
- Max files: 1 (no rotation by default).
- Log location: `/var/lib/docker/containers/<container_id>/<container_id>-json.log`.

**Operator customization:** For production deployments with long-running training jobs, operators can configure Docker's log rotation in `/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "5"
  }
}
```

**Accessing logs:**

```bash
# View Flower container logs (structured JSON when FL_LOG_FORMAT=json)
docker logs flower-superlink
docker logs flower-supernode

# Follow logs in real-time
docker logs -f flower-superlink

# Via systemd journal
journalctl -u flower-superlink -f
```

---

## 4. New Contextualization Variables

Phase 8 introduces four new contextualization variables for monitoring configuration.

### 4.1 Variable Definitions

| # | Variable | USER_INPUT Definition | Type | Default | Validation Rule | Appliance | Purpose |
|---|----------|----------------------|------|---------|-----------------|-----------|---------|
| 1 | `FL_LOG_FORMAT` | `O\|list\|Log output format\|text,json\|text` | list | `text` | One of: `text`, `json` | Both (service-level) | OBS-01: Switch between Flower's default text format and structured JSON. When `json`, the FlowerJSONFormatter replaces the default handler formatter on the `flwr` logger. |
| 2 | `FL_METRICS_ENABLED` | `O\|boolean\|Enable Prometheus metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO` | SuperLink | OBS-02: Master switch for Prometheus metrics. When YES, starts `prometheus_client` HTTP server on `FL_METRICS_PORT`. The ServerApp FAB must include `prometheus_client` in its dependencies. |
| 3 | `FL_METRICS_PORT` | `O\|number\|Prometheus metrics exporter port\|\|9101` | number | `9101` | Integer in range 1024-65535; must not be 9091, 9092, or 9093 | SuperLink | OBS-02: Port for the FL training metrics HTTP endpoint. |
| 4 | `FL_DCGM_ENABLED` | `O\|boolean\|Enable DCGM GPU metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO`; requires `FL_GPU_ENABLED=YES` (Phase 6) | SuperNode | OBS-02: Master switch for DCGM Exporter sidecar container. |

### 4.2 Variable Interaction Matrix

| Variable | Tier | Appliance | Enables | Depends On |
|----------|------|-----------|---------|------------|
| `FL_LOG_FORMAT=json` | Tier 1 (OBS-01) | Both (via OneFlow service-level) | JSON structured logging | Nothing -- standalone |
| `FL_METRICS_ENABLED=YES` | Tier 2 (OBS-02) | SuperLink only | Prometheus FL metrics on `FL_METRICS_PORT` | `prometheus_client` in ServerApp FAB |
| `FL_METRICS_PORT=9101` | Tier 2 (OBS-02) | SuperLink only | Custom metrics port | `FL_METRICS_ENABLED=YES` |
| `FL_DCGM_ENABLED=YES` | Tier 2 (OBS-02) | SuperNode only | DCGM Exporter sidecar on port 9400 | `FL_GPU_ENABLED=YES` (Phase 6) + GPU detected |

### 4.3 USER_INPUT Definitions (Copy-Paste Ready)

**Service-level (OneFlow, applies to both appliances):**

```
FL_LOG_FORMAT = "O|list|Log output format|text,json|text"
```

**SuperLink role-level:**

```
FL_METRICS_ENABLED = "O|boolean|Enable Prometheus metrics exporter||NO"
FL_METRICS_PORT = "O|number|Prometheus metrics exporter port||9101"
```

**SuperNode role-level:**

```
FL_DCGM_ENABLED = "O|boolean|Enable DCGM GPU metrics exporter||NO"
```

---

## 5. Tier 2 -- Flower Training Metrics Exporter (OBS-02)

### 5.1 Purpose

Expose FL training metrics to Prometheus via an HTTP endpoint on the SuperLink VM. Prometheus scrapes this endpoint at its configured interval, storing the time-series data for Grafana visualization and alerting.

### 5.2 Implementation Approach

The metrics exporter uses the `prometheus_client` Python library, embedded in the ServerApp FAB code. It is NOT added to the base Flower Docker image -- this avoids modifying the upstream image and decouples the monitoring dependency from the Flower version.

**Dependency placement:** The `prometheus_client` library is declared as a dependency in the ServerApp FAB's `pyproject.toml`:

```toml
[tool.flwr.app]
# ... existing FAB config ...

[project]
dependencies = [
    "prometheus_client>=0.21",
]
```

### 5.3 Metric Definitions

All 11 Flower training metrics exposed by the exporter:

| Metric Name | Type | Labels | Description |
|------------|------|--------|-------------|
| `fl_round_current` | Gauge | `strategy` | Current training round number |
| `fl_round_total` | Gauge | `strategy` | Total configured training rounds |
| `fl_round_duration_seconds` | Histogram | `strategy` | Duration of each training round (buckets: 1, 5, 10, 30, 60, 120, 300, 600) |
| `fl_aggregated_loss` | Gauge | `strategy` | Aggregated loss after latest round |
| `fl_aggregated_accuracy` | Gauge | `strategy` | Aggregated accuracy after latest round |
| `fl_clients_connected` | Gauge | -- | Number of currently connected SuperNodes |
| `fl_clients_selected` | Gauge | -- | Number of clients selected for current round |
| `fl_clients_responded` | Gauge | -- | Number of clients that responded in current round |
| `fl_clients_failed` | Counter | -- | Total client failures across all rounds |
| `fl_checkpoint_saved_total` | Counter | -- | Total checkpoints saved |
| `fl_training_status` | Gauge | -- | Training status: 0=idle, 1=running, 2=complete, 3=failed |

### 5.4 Label Cardinality Rules

**CRITICAL:** Do NOT use `round` as a Prometheus label. Using round numbers as labels creates unbounded cardinality -- a 1000-round training job would create 1000 time series per metric, eventually causing Prometheus to run out of memory.

**Correct pattern:** Use single Gauge metrics updated in-place each round. Prometheus's time-series collection stores the historical values automatically at its scrape interval.

```python
# GOOD: Single gauge, updated each round. Prometheus stores history.
fl_aggregated_loss = Gauge("fl_aggregated_loss", "Current aggregated loss", ["strategy"])
fl_aggregated_loss.labels(strategy="FedAvg").set(0.234)

# BAD: Label per round creates unbounded cardinality
fl_aggregated_loss = Gauge("fl_aggregated_loss", "Loss per round", ["strategy", "round"])
fl_aggregated_loss.labels(strategy="FedAvg", round="1").set(0.5)
fl_aggregated_loss.labels(strategy="FedAvg", round="2").set(0.4)
# ...creates 1000 series for 1000 rounds
```

### 5.5 Reference Implementation

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
    "fl_training_status",
    "Training status: 0=idle, 1=running, 2=complete, 3=failed"
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

### 5.6 Integration Points

The metrics exporter integrates with the ServerApp at two points:

1. **ServerApp initialization:** When `FL_METRICS_ENABLED=YES`, the `start_http_server(FL_METRICS_PORT)` call is made during ServerApp startup (in the `@app.main()` function), before training begins.

2. **Strategy callbacks:** Metrics are updated in the `evaluate_fn` callback and the strategy factory. The `Result` object's `train_metrics_clientapp` and `evaluate_metrics_clientapp` dictionaries provide per-round loss, accuracy, and client participation data. The `update_round_metrics()` function is called after each round's aggregation completes.

**Activation flow:**

```
FL_METRICS_ENABLED=YES (CONTEXT var)
  -> configure.sh passes metrics-enabled=true to FAB run_config
  -> ServerApp reads run_config["metrics-enabled"]
  -> ServerApp calls start_metrics_server(run_config["metrics-port"])
  -> After each round: update_round_metrics() updates Prometheus gauges
  -> Prometheus scrapes :9101/metrics at configured interval
```

---

## 6. Tier 2 -- DCGM Exporter for GPU Metrics (OBS-02)

### 6.1 Purpose

Expose NVIDIA GPU metrics from SuperNode VMs to Prometheus. GPU utilization, memory usage, temperature, and error state are critical for diagnosing training performance issues and preventing hardware failures.

### 6.2 DCGM Exporter Container

The DCGM (Data Center GPU Manager) Exporter is an official NVIDIA product that exposes GPU metrics in Prometheus format.

**Image:** `nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless`

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

**Required flags:**
- `--gpus all`: Provides GPU access to the container via NVIDIA Container Toolkit.
- `--cap-add SYS_ADMIN`: Required for DCGM to access GPU management interfaces. Without this capability, the DCGM library cannot initialize and the container reports no metrics or crashes.
- `-p 9400:9400`: Exposes the metrics endpoint on the standard DCGM port.

### 6.3 Systemd Unit

The DCGM Exporter runs as a systemd-managed service alongside the SuperNode container.

```ini
# /etc/systemd/system/dcgm-exporter.service
# Generated by configure.sh when FL_DCGM_ENABLED=YES and FL_GPU_ENABLED=YES

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

**Systemd unit design:**

- `After=docker.service flower-supernode.service`: DCGM starts after both Docker and the SuperNode container are running.
- `PartOf=flower-supernode.service`: DCGM is stopped when the SuperNode service stops. This ensures the GPU monitoring sidecar's lifecycle is tied to the training container.
- `Restart=on-failure` with `RestartSec=10`: Automatic restart on DCGM crash, with 10-second backoff.
- `ExecStartPre=-docker rm -f dcgm-exporter`: Clean up any stale container from a previous run. The `-` prefix means failure is non-fatal.
- No `-d` flag in `ExecStart`: systemd requires the foreground process.

### 6.4 Lifecycle

The DCGM Exporter sidecar is started only when ALL three conditions are met:

1. `FL_DCGM_ENABLED=YES` -- Operator explicitly enables DCGM monitoring.
2. `FL_GPU_ENABLED=YES` -- GPU passthrough is enabled (Phase 6).
3. GPU detection succeeds -- `nvidia-smi` returns exit code 0 during boot Step 9.

If any condition is not met, DCGM is not started:
- `FL_DCGM_ENABLED=NO` (default): DCGM unit file is not created.
- `FL_GPU_ENABLED=NO`: DCGM unit file is not created (logged at INFO).
- `FL_GPU_ENABLED=YES` but GPU not detected: Warning logged, DCGM not started.

### 6.5 DCGM Image Pull Strategy

The DCGM Exporter image is NOT pre-baked in the QCOW2 image. It is pulled at boot time when `FL_DCGM_ENABLED=YES`. This decision keeps the base QCOW2 image size stable (DCGM image is approximately 200-300 MB).

**Trade-off:** Enabling DCGM monitoring requires network access at boot time. In air-gapped environments, operators must pre-pull the DCGM image manually before enabling `FL_DCGM_ENABLED=YES`, or include it in a custom QCOW2 build.

**Pull failure handling:** If the DCGM image pull fails (no network, registry unavailable), the bootstrap script logs a WARNING and continues without DCGM. This is a degraded monitoring state, not a fatal error. The SuperNode container starts and trains normally -- only GPU metrics are unavailable.

### 6.6 Key DCGM Metrics

| Metric Name | Type | Description | Alerting Use |
|------------|------|-------------|-------------|
| `DCGM_FI_DEV_GPU_UTIL` | Gauge | GPU utilization (%) | Stalled training: < 5% with active job |
| `DCGM_FI_DEV_MEM_COPY_UTIL` | Gauge | Memory utilization (%) | Memory pressure detection |
| `DCGM_FI_DEV_FB_FREE` | Gauge | Free framebuffer memory (MiB) | OOM prevention |
| `DCGM_FI_DEV_FB_USED` | Gauge | Used framebuffer memory (MiB) | Memory tracking |
| `DCGM_FI_DEV_GPU_TEMP` | Gauge | GPU temperature (C) | Thermal throttling alert |
| `DCGM_FI_DEV_POWER_USAGE` | Gauge | Power draw (W) | Power anomaly detection |
| `DCGM_FI_DEV_XID_ERRORS` | Gauge | Last XID error value | Hardware error detection |
| `DCGM_FI_DEV_SM_CLOCK` | Gauge | SM clock frequency (MHz) | Clock throttling detection |

**Version compatibility:** DCGM Exporter 4.5.1 is tested with NVIDIA driver 545+. Using an older DCGM version with a newer host driver may cause missing metrics or incorrect values due to API incompatibilities.

---

## 7. Tier 2 -- Prometheus Scrape Configuration (OBS-02)

Prometheus is operator-managed infrastructure. This section provides reference configuration that operators add to their existing Prometheus deployment. The appliance does NOT deploy or manage Prometheus.

### 7.1 Scrape Configuration

```yaml
# prometheus.yml snippet -- add to operator's existing Prometheus config
# Replace <superlink_ip> and <supernode_*_ip> with actual VM IP addresses

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

**Configuration details:**

- **`fl_training` job:** Scrapes the custom Flower training metrics exporter on the SuperLink VM. Port 9101 exposes the `/metrics` endpoint served by `prometheus_client`.
- **`dcgm_gpu` job:** Scrapes DCGM Exporter on each GPU-enabled SuperNode VM. Port 9400 is the DCGM standard.
- **Scrape interval:** 15 seconds (Prometheus default). Adjustable by the operator. For training jobs with very short rounds (< 5 seconds), consider reducing to 5 seconds.
- **Labels:** `role` and `deployment` labels are added to all scraped metrics for filtering in Grafana dashboards and alerting rules.

### 7.2 Service Discovery

**Default: Static target configuration.** The operator fills in IP addresses for each VM. This is the simplest approach and works for fixed deployments.

**Dynamic environments:** For deployments where SuperNodes scale up/down via OneFlow elasticity, operators can use Prometheus file-based service discovery (`file_sd_configs`) with a script that queries OneFlow or OneGate for current VM IPs:

```yaml
scrape_configs:
  - job_name: "dcgm_gpu"
    scrape_interval: 15s
    file_sd_configs:
      - files:
          - /etc/prometheus/targets/flower-supernodes.json
        refresh_interval: 30s
```

The discovery script that generates `flower-supernodes.json` is an operator-managed integration and is not specified in detail here. It would query the OneFlow service API and produce a JSON file with current SuperNode IPs.

### 7.3 Network Requirements

Prometheus must be able to reach the metrics endpoints on the appliance VMs. Required port openings:

| Source | Destination | Port | Protocol | Purpose |
|--------|------------|------|----------|---------|
| Prometheus VM | SuperLink VM | 9101 | TCP | FL training metrics scraping |
| Prometheus VM | SuperNode VMs | 9400 | TCP | GPU metrics scraping |

**OpenNebula security groups:** If network security groups are configured, the operator must allow inbound TCP connections from the Prometheus VM to ports 9101 (SuperLink) and 9400 (SuperNode). These ports are only needed when OBS-02 monitoring is enabled.

---

## 8. Tier 2 -- Grafana Dashboard Definitions (OBS-02)

### 8.1 Provisioning Structure

Grafana dashboards are defined as panel specifications in this spec. Operators export them as Grafana JSON using the Grafana UI or API. A reference NVIDIA DCGM dashboard is available at Grafana Dashboard ID 12239.

**Provisioning file structure:**

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

**Grafana datasource provisioning:**

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

**Grafana dashboard provider:**

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

### 8.2 Dashboard 1: FL Training Overview

Provides visibility into FL training convergence, round timing, and overall training status.

| Panel | Type | PromQL Query | Purpose |
|-------|------|-------------|---------|
| Training Progress | Stat | `fl_round_current / fl_round_total` | Round completion progress (0.0 to 1.0) |
| Loss Convergence Curve | Time Series | `fl_aggregated_loss` | Loss over rounds -- visualizes model convergence |
| Accuracy Convergence Curve | Time Series | `fl_aggregated_accuracy` | Accuracy over rounds -- visualizes model improvement |
| Round Duration | Time Series | `rate(fl_round_duration_seconds_sum[5m]) / rate(fl_round_duration_seconds_count[5m])` | Average round duration trend -- detects slowdowns |
| Client Participation | Time Series | `fl_clients_responded` | Clients participating per round -- detects dropout |
| Training Status | Stat | `fl_training_status` | Status indicator: 0=idle, 1=running, 2=complete, 3=failed |

### 8.3 Dashboard 2: GPU Health

Monitors GPU hardware health across all SuperNode VMs. Essential for GPU-accelerated training where hardware issues (thermal throttling, memory exhaustion, XID errors) directly impact training performance.

| Panel | Type | PromQL Query | Purpose |
|-------|------|-------------|---------|
| GPU Utilization | Time Series | `DCGM_FI_DEV_GPU_UTIL` | Per-GPU utilization over time |
| GPU Memory Usage | Time Series | `DCGM_FI_DEV_FB_USED / (DCGM_FI_DEV_FB_USED + DCGM_FI_DEV_FB_FREE) * 100` | Memory usage percentage |
| GPU Temperature | Time Series | `DCGM_FI_DEV_GPU_TEMP` | Temperature with threshold lines at 80C (warning) and 90C (critical) |
| Power Usage | Time Series | `DCGM_FI_DEV_POWER_USAGE` | Power draw over time |
| XID Errors | Stat | `DCGM_FI_DEV_XID_ERRORS` | Last XID error value (0 = no errors) |
| Free Memory | Gauge | `DCGM_FI_DEV_FB_FREE` | Available GPU memory per node in MiB |

### 8.4 Dashboard 3: Client Health

Monitors SuperNode connectivity and failure patterns. Helps operators identify problematic clients and network issues.

| Panel | Type | PromQL Query | Purpose |
|-------|------|-------------|---------|
| Connected Clients | Stat | `fl_clients_connected` | Current connected client count |
| Client Failures | Time Series | `rate(fl_clients_failed[5m])` | Client failure rate over time |
| Client Participation Rate | Time Series | `fl_clients_responded / fl_clients_selected * 100` | Participation percentage per round |
| Client Response Time | Histogram | `fl_round_duration_seconds` | Distribution of round times (proxy for client response time) |

---

## 9. Tier 2 -- Alerting Rules (OBS-02)

Alerting rules are defined as Prometheus recording/alerting rules. Operators add the YAML to their Prometheus `rules_files` configuration.

### 9.1 FL Training Alerts

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
```

### 9.2 GPU Health Alerts

```yaml
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

### 9.3 Alertmanager Integration

Alertmanager configuration is operator-managed. The spec provides a minimal reference configuration:

```yaml
# alertmanager.yml reference -- operator configures their own routing
route:
  receiver: "default"
  group_by: ["alertname", "severity"]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - match:
        severity: critical
      receiver: "critical-alerts"

receivers:
  - name: "default"
    # Configure: email, webhook, Slack, PagerDuty, etc.
  - name: "critical-alerts"
    # Configure: immediate notification channel for critical alerts
```

**Alert severity levels:**

| Severity | Meaning | Example Alerts |
|----------|---------|---------------|
| `critical` | Immediate attention required; training may be failing or hardware at risk | FLTrainingStalled, GPUMemoryExhaustion, GPUTemperatureCritical, GPUXIDError |
| `warning` | Potential issue; training continues but operator should investigate | FLExcessiveClientDropout, FLClientFailureRate, FLTrainingNotStarted, GPUUtilizationDrop |

---

## 10. Boot Sequence Integration

This section defines how monitoring components integrate into the existing appliance boot sequences defined in `spec/01-superlink-appliance.md` (Section 6) and `spec/02-supernode-appliance.md` (Section 7).

### 10.1 SuperLink Boot Sequence Changes

When `FL_LOG_FORMAT=json`:
- **After Step 4 (validate_config):** Configure JSON formatter on the `flwr` logger if `FL_LOG_FORMAT=json`. Call `configure_json_logging(role="superlink")`. This replaces the default text handler formatter before any Flower code produces log output.
- **No new boot steps.** The formatter replacement is embedded in the existing validate/configure step.

When `FL_METRICS_ENABLED=YES`:
- **After Step 10 (start Flower container):** Start `prometheus_client` HTTP server inside the ServerApp if `FL_METRICS_ENABLED=YES`. The `start_http_server(FL_METRICS_PORT)` call is made during ServerApp initialization in the `@app.main()` function.
- **No new boot steps.** The metrics server is started as part of the ServerApp initialization, which occurs within the already-running container.

### 10.2 SuperNode Boot Sequence Changes

When `FL_LOG_FORMAT=json`:
- **After Step 4 (validate_config):** Configure JSON formatter on the `flwr` logger if `FL_LOG_FORMAT=json`. Call `configure_json_logging(role="supernode")`. Same mechanism as SuperLink.

When `FL_DCGM_ENABLED=YES`:
- **New Step 15 (after Step 14 GPU Detection from Phase 6):** Start DCGM Exporter sidecar container.

**Step 15 procedure:**

```
1. IF FL_DCGM_ENABLED != YES:
     Skip DCGM setup
     LOG "INFO: FL_DCGM_ENABLED is not YES, skipping DCGM Exporter"

2. IF FL_GPU_ENABLED != YES:
     Skip DCGM setup
     LOG "INFO: FL_GPU_ENABLED is not YES, DCGM Exporter not applicable"

3. IF FL_GPU_AVAILABLE != YES (from Step 14 GPU Detection):
     Skip DCGM setup
     LOG "WARNING: GPU not available, DCGM Exporter will not start"

4. Pull DCGM Exporter image:
     docker pull nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless
     IF pull fails:
         LOG "WARNING: DCGM Exporter image pull failed. GPU metrics unavailable."
         Continue without DCGM (degraded monitoring, not fatal)

5. Write dcgm-exporter.service systemd unit file
6. systemctl daemon-reload
7. systemctl start dcgm-exporter
8. LOG "INFO: DCGM Exporter started on port 9400"
```

### 10.3 Validation Rules for New Variables

Added to `configure.sh validate_config()` for both appliances:

| Variable | Rule | Error Message |
|----------|------|---------------|
| `FL_LOG_FORMAT` | Must be `text` or `json` | `"Invalid FL_LOG_FORMAT: '${VALUE}'. Must be 'text' or 'json'."` |
| `FL_METRICS_ENABLED` | Must be `YES` or `NO` | `"Invalid FL_METRICS_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_METRICS_PORT` | Integer 1024-65535; must not be 9091, 9092, or 9093 | `"Invalid FL_METRICS_PORT: '${VALUE}'. Must be integer 1024-65535, not 9091-9093."` |
| `FL_DCGM_ENABLED` | Must be `YES` or `NO`; if YES and `FL_GPU_ENABLED` != YES: warning | `"Invalid FL_DCGM_ENABLED: '${VALUE}'. Must be YES or NO."` |

**FL_DCGM_ENABLED conditional warning:**

```bash
if [ "${FL_DCGM_ENABLED:-NO}" = "YES" ] && [ "${FL_GPU_ENABLED:-NO}" != "YES" ]; then
    log "WARN" "FL_DCGM_ENABLED=YES but FL_GPU_ENABLED is not YES. DCGM will not start."
fi
```

---

## 11. Failure Modes and Recovery

| Condition | Symptom | Impact | Recovery |
|-----------|---------|--------|----------|
| FL metrics exporter port conflict | "Address already in use" on 9101 | No FL metrics exposed | Change `FL_METRICS_PORT` to unused port, redeploy |
| DCGM Exporter SYS_ADMIN denied | Empty /metrics response or container crash | No GPU metrics | Verify `--cap-add SYS_ADMIN` in docker run command |
| DCGM image pull fails (no network) | Container not started, WARNING in boot log | No GPU metrics (training continues normally) | Ensure network access at boot or pre-pull DCGM image |
| DCGM version mismatch | Missing metrics or incorrect values | Incomplete GPU data | Use DCGM Exporter 4.5.1+ with NVIDIA driver 545+ |
| Prometheus cannot scrape ports | Target "down" in Prometheus UI | No metrics collected | Open ports 9101/9400 in OpenNebula security groups |
| JSON formatter double-encoding | Broken JSON in log lines | Log parsing fails | Formatter must replace handler, not wrap pre-formatted output |
| Unbounded metric cardinality | Prometheus OOM over time | Monitoring crash | Do not use "round" as label; use single gauge updated per round |

---

## 12. Anti-Patterns

| Anti-Pattern | Why It Fails | Do Instead |
|-------------|-------------|-----------|
| Running Prometheus/Grafana inside appliance VM | Resource contention with FL training; appliance is immutable; violates single-concern design | Deploy monitoring on separate operator-managed infrastructure |
| Parsing nvidia-smi for continuous GPU metrics | Fragile text parsing, no timestamps, misses multi-GPU/MIG edge cases, not designed for continuous monitoring | Use DCGM Exporter with structured Prometheus metrics |
| Adding prometheus_client to Flower Docker image | Modifies base image, creates version coupling between monitoring and Flower releases | Embed in ServerApp FAB dependencies (pyproject.toml) |
| Pushing metrics from container to Prometheus | Violates Prometheus pull model, adds complexity, requires push gateway | Expose /metrics HTTP endpoint; let Prometheus scrape |
| Using "round" as Prometheus label on counters | Unbounded cardinality (1000 rounds = 1000 time series per metric); Prometheus OOM | Single gauge updated per round; Prometheus stores history via time-series collection |
| Enabling FL_DCGM_ENABLED without FL_GPU_ENABLED | DCGM cannot access GPU management interfaces without GPU passthrough | Set `FL_GPU_ENABLED=YES` first (Phase 6 prerequisite) |

---

## 13. New Contextualization Variables Summary

Complete summary of all 4 Phase 8 variables with their USER_INPUT definitions and placement in the OneFlow service template.

| Variable | USER_INPUT Definition | Level | Appliance |
|----------|----------------------|-------|-----------|
| `FL_LOG_FORMAT` | `O\|list\|Log output format\|text,json\|text` | Service-level (OneFlow) | Both (SuperLink + SuperNode) |
| `FL_METRICS_ENABLED` | `O\|boolean\|Enable Prometheus metrics exporter\|\|NO` | SuperLink role | SuperLink only |
| `FL_METRICS_PORT` | `O\|number\|Prometheus metrics exporter port\|\|9101` | SuperLink role | SuperLink only |
| `FL_DCGM_ENABLED` | `O\|boolean\|Enable DCGM GPU metrics exporter\|\|NO` | SuperNode role | SuperNode only |

### Copy-Paste USER_INPUT Definitions

**Service-level:**

```
FL_LOG_FORMAT = "O|list|Log output format|text,json|text"
```

**SuperLink role-level:**

```
FL_METRICS_ENABLED = "O|boolean|Enable Prometheus metrics exporter||NO"
FL_METRICS_PORT = "O|number|Prometheus metrics exporter port||9101"
```

**SuperNode role-level:**

```
FL_DCGM_ENABLED = "O|boolean|Enable DCGM GPU metrics exporter||NO"
```

### Updated Variable Count

Adding 4 Phase 8 variables to the project total:

| Category | Previous Count | Phase 8 Addition | New Count |
|----------|---------------|------------------|-----------|
| SuperLink parameters | 22 | +2 (FL_METRICS_ENABLED, FL_METRICS_PORT) | 24 |
| SuperNode parameters | 12 | +1 (FL_DCGM_ENABLED) | 13 |
| Service-level (new) | 0 | +1 (FL_LOG_FORMAT) | 1 |
| **Total project variables** | **42** | **+4** | **46** |

*Note:* FL_LOG_FORMAT is a service-level variable applied to both appliances via OneFlow. It is counted once, not per appliance.

---

*Specification for OBS-01, OBS-02: Monitoring and Observability / Phase: 08 - Monitoring and Observability / Version: 1.0*
