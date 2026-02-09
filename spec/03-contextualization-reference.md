# Contextualization Variable Reference

**Requirement:** APPL-03
**Phase:** 01 - Base Appliance Architecture
**Status:** Specification

---

## 1. Purpose and Scope

This document is the single authoritative reference for every OpenNebula contextualization variable used by the Flower SuperLink and SuperNode marketplace appliances. It serves as an implementation checklist: an engineer building either appliance can print this document and check off each variable as it is implemented in the contextualization scripts.

**Scope:** All variables defined in Phase 1 (base appliance architecture), Phase 5 (training configuration), Phase 7 (gRPC keepalive and certificate SAN for multi-site federation), Phase 8 (monitoring and observability), plus placeholder variables for Phase 2 (TLS), Phase 3 (ML frameworks), and Phase 6 (GPU). Placeholder variables are documented here for completeness but are not functional in Phase 1. Phase 5 variables are functional and documented in Section 3. Phase 7 variables are functional and documented in Sections 3-4. Phase 8 variables (FL_LOG_FORMAT, FL_METRICS_ENABLED, FL_METRICS_PORT, FL_DCGM_ENABLED) are functional and documented in Sections 3-5.

**Source of truth hierarchy:**
1. This document is the authoritative reference for variable names, types, defaults, and validation rules.
2. `spec/01-superlink-appliance.md` and `spec/02-supernode-appliance.md` define the appliance behavior that each variable controls.
3. If there is a conflict between this document and an appliance spec, this document takes precedence for variable definitions.

**Variable count summary:**

| Category | Count | Appliance |
|----------|-------|-----------|
| SuperLink parameters | 24 | SuperLink only |
| SuperNode parameters | 13 | SuperNode only |
| Shared infrastructure | 5 | Both |
| Service-level (OneFlow) | 1 | Both (via OneFlow) |
| Phase 5 strategy/checkpointing | 8 | SuperLink |
| Phase 6 GPU configuration | 3 | SuperNode |
| Phase 7 gRPC keepalive/cert | 3 | Both/SuperLink |
| Phase 8 monitoring/logging | 4 | SuperLink/SuperNode/Service |
| Phase 2+ placeholders | 5 | Both (not functional in Phase 1) |
| **Total** | **46** | |

*Note:* The Phase 5 count (8) is included in the SuperLink parameters count (24 = 11 original + 8 Phase 5 + 3 Phase 7 + 2 Phase 8). The Phase 6 count (3) is included in the SuperNode parameters count (13 = 7 original + 3 Phase 6 + 2 Phase 7 + 1 Phase 8). The separate Phase 5, Phase 6, Phase 7, and Phase 8 rows are for traceability. SuperNode count includes FL_USE_CASE added in Phase 3. The Phase 7 count (3) reflects 3 unique variables: FL_GRPC_KEEPALIVE_TIME and FL_GRPC_KEEPALIVE_TIMEOUT apply to both appliances, FL_CERT_EXTRA_SAN applies to SuperLink only. The Phase 8 count (4) reflects 4 unique variables: FL_LOG_FORMAT is service-level (counted once, applied to both appliances via OneFlow), FL_METRICS_ENABLED and FL_METRICS_PORT are SuperLink role-level, FL_DCGM_ENABLED is SuperNode role-level.

---

## 2. USER_INPUT Format Reference

OpenNebula USER_INPUTs define the variables that are presented to users in Sunstone (the web UI) when instantiating a VM template. Each USER_INPUT follows a pipe-delimited format:

```
VARIABLE_NAME = "M|type|Description|options|default"
```

**Field definitions:**

| Field | Position | Values | Description |
|-------|----------|--------|-------------|
| Mandatory flag | 1 | `M` (mandatory) or `O` (optional) | Whether the user must provide a value. `O` means the default is used if unset. |
| Type | 2 | See type table below | Input widget type in Sunstone UI. |
| Description | 3 | Free text | Human-readable label shown to the user. |
| Options | 4 | Type-specific | Comma-separated list for `list` types, `min..max` for `range` types, empty for others. |
| Default | 5 | Any | Default value pre-filled in the UI. |

**Supported types:**

| Type | Widget | Options Field | Example |
|------|--------|---------------|---------|
| `text` | Free-form text input | (unused) | `"O\|text\|Server address\|\|0.0.0.0:9092"` |
| `text64` | Base64-encoded text area | (unused) | `"O\|text64\|Custom script"` |
| `password` | Masked password input | (unused) | `"O\|password\|Auth token"` |
| `number` | Integer input | (unused) | `"O\|number\|Training rounds\|\|3"` |
| `number-float` | Float input | (unused) | `"O\|number-float\|Learning rate\|\|0.01"` |
| `range` | Integer slider | `min..max` | `"O\|range\|Memory (MB)\|2048..65536\|8192"` |
| `range-float` | Float slider | `min..max` | `"O\|range-float\|CPU\|0.5..16.0\|4.0"` |
| `list` | Single-select dropdown | `opt1,opt2,...` | `"O\|list\|Strategy\|FedAvg,FedProx\|FedAvg"` |
| `list-multiple` | Multi-select | `opt1,opt2,...` | `"O\|list-multiple\|Features\|tls,gpu"` |
| `boolean` | Yes/No toggle | (unused) | `"O\|boolean\|Enable GPU\|\|NO"` |
| `fixed` | Non-editable display | (unused) | `"M\|fixed\|\| \|superlink"` |

**Source:** OpenNebula 7.0 VM Template reference documentation.

---

## 3. SuperLink Parameters

These 24 variables configure the Flower SuperLink appliance. All are optional. Zero-config deployment works with all defaults (see Section 9). Variables #1-11 are Phase 1 (base architecture). Variables #12-19 are Phase 5 (training configuration: strategy parameters and checkpointing). Variables #20-22 are Phase 7 (multi-site federation: gRPC keepalive and certificate SAN). Variables #23-24 are Phase 8 (monitoring: Prometheus metrics exporter).

**Appliance:** SuperLink only
**Spec reference:** `spec/01-superlink-appliance.md`, Section 12

| # | Context Variable | USER_INPUT Definition | Type | Default | Validation Rule | Flower Mapping |
|---|------------------|----------------------|------|---------|-----------------|----------------|
| 1 | `FLOWER_VERSION` | `O\|text\|Flower Docker image version tag\|\|1.25.0` | text | `1.25.0` | Non-empty string matching `[0-9]+\.[0-9]+\.[0-9]+` pattern | Docker image tag: `flwr/superlink:${FLOWER_VERSION}` |
| 2 | `FL_NUM_ROUNDS` | `O\|number\|Number of federated learning rounds\|\|3` | number | `3` | Positive integer (>0) | ServerApp config: `num_server_rounds` |
| 3 | `FL_STRATEGY` | `O\|list\|Aggregation strategy\|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg\|FedAvg` | list | `FedAvg` | One of: `FedAvg`, `FedProx`, `FedAdam`, `Krum`, `Bulyan`, `FedTrimmedAvg` | ServerApp config: `strategy` class name |
| 4 | `FL_MIN_FIT_CLIENTS` | `O\|number\|Minimum clients for training round\|\|2` | number | `2` | Positive integer (>0) | Strategy param: `min_fit_clients` |
| 5 | `FL_MIN_EVALUATE_CLIENTS` | `O\|number\|Minimum clients for evaluation\|\|2` | number | `2` | Positive integer (>0) | Strategy param: `min_evaluate_clients` |
| 6 | `FL_MIN_AVAILABLE_CLIENTS` | `O\|number\|Minimum available clients to start\|\|2` | number | `2` | Positive integer (>0) | Strategy param: `min_available_clients` |
| 7 | `FL_FLEET_API_ADDRESS` | `O\|text\|Fleet API listen address (host:port)\|\|0.0.0.0:9092` | text | `0.0.0.0:9092` | `host:port` format; port in range 1-65535 | CLI flag: `--fleet-api-address` |
| 8 | `FL_CONTROL_API_ADDRESS` | `O\|text\|Control API listen address (host:port)\|\|0.0.0.0:9093` | text | `0.0.0.0:9093` | `host:port` format; port in range 1-65535 | Implied by port mapping; controls `--control-api-address` if supported |
| 9 | `FL_ISOLATION` | `O\|list\|App execution isolation mode\|subprocess,process\|subprocess` | list | `subprocess` | One of: `subprocess`, `process` | CLI flag: `--isolation` |
| 10 | `FL_DATABASE` | `O\|text\|Database path for state persistence\|\|state/state.db` | text | `state/state.db` | Non-empty string; path relative to container workdir | CLI flag: `--database` |
| 11 | `FL_LOG_LEVEL` | `O\|list\|Log verbosity\|DEBUG,INFO,WARNING,ERROR\|INFO` | list | `INFO` | One of: `DEBUG`, `INFO`, `WARNING`, `ERROR` | Environment variable: `FLWR_LOG_LEVEL` |
| 12 | `FL_PROXIMAL_MU` | `O\|number-float\|FedProx proximal term (mu)\|\|1.0` | number-float | `1.0` | Non-negative float (>=0.0); ignored if `FL_STRATEGY` != `FedProx` | Strategy param: `proximal_mu` |
| 13 | `FL_SERVER_LR` | `O\|number-float\|Server-side learning rate\|\|0.1` | number-float | `0.1` | Positive float (>0.0); ignored if `FL_STRATEGY` != `FedAdam` | Strategy param: `eta` (server learning rate) |
| 14 | `FL_CLIENT_LR` | `O\|number-float\|Client-side learning rate\|\|0.1` | number-float | `0.1` | Positive float (>0.0); ignored if `FL_STRATEGY` != `FedAdam` | Strategy param: `eta_l` (client learning rate) |
| 15 | `FL_NUM_MALICIOUS` | `O\|number\|Expected malicious clients (Krum/Bulyan)\|\|0` | number | `0` | Non-negative integer (>=0); if Krum: `n>=2f+3`; if Bulyan: `n>=4f+3` | Strategy param: `num_malicious_clients` |
| 16 | `FL_TRIM_BETA` | `O\|number-float\|Trim fraction per tail (FedTrimmedAvg)\|\|0.2` | number-float | `0.2` | Float in range (0.0, 0.5) exclusive; ignored if `FL_STRATEGY` != `FedTrimmedAvg` | Strategy param: `beta` |
| 17 | `FL_CHECKPOINT_ENABLED` | `O\|boolean\|Enable model checkpointing\|\|NO` | boolean | `NO` | `YES` or `NO` | ServerApp: enables checkpoint saving |
| 18 | `FL_CHECKPOINT_INTERVAL` | `O\|number\|Save checkpoint every N rounds\|\|5` | number | `5` | Positive integer (>0); ignored if `FL_CHECKPOINT_ENABLED` != `YES` | ServerApp: checkpoint frequency |
| 19 | `FL_CHECKPOINT_PATH` | `O\|text\|Checkpoint directory (container path)\|\|/app/checkpoints` | text | `/app/checkpoints` | Non-empty string; ignored if `FL_CHECKPOINT_ENABLED` != `YES` | Docker mount: `-v /opt/flower/checkpoints:{path}:rw` |
| 20 | `FL_GRPC_KEEPALIVE_TIME` | `O\|number\|gRPC keepalive interval in seconds\|\|60` | number | `60` | Positive integer (>0). Warning if <10. | gRPC channel option: `grpc.keepalive_time_ms` (value * 1000) |
| 21 | `FL_GRPC_KEEPALIVE_TIMEOUT` | `O\|number\|gRPC keepalive ACK timeout in seconds\|\|20` | number | `20` | Positive integer (>0). Must be < `FL_GRPC_KEEPALIVE_TIME`. | gRPC channel option: `grpc.keepalive_timeout_ms` (value * 1000) |
| 22 | `FL_CERT_EXTRA_SAN` | `O\|text\|Additional SAN entries for auto-generated cert (comma-separated)\|\|` | text | (empty) | If set: comma-separated entries matching `IP:<addr>` or `DNS:<name>` pattern. Only effective when `FL_TLS_ENABLED=YES` and auto-generating certs. | Added to SAN in cert generation (`[alt_names]` section of CSR config) |
| 23 | `FL_METRICS_ENABLED` | `O\|boolean\|Enable Prometheus metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO` | When YES: starts `prometheus_client` HTTP server on `FL_METRICS_PORT`. ServerApp FAB must include `prometheus_client` dependency. See [`spec/13-monitoring-observability.md`](13-monitoring-observability.md) Section 5. |
| 24 | `FL_METRICS_PORT` | `O\|number\|Prometheus metrics exporter port\|\|9101` | number | `9101` | Integer 1024-65535; must not be 9091, 9092, or 9093 (Flower ports). Only effective when `FL_METRICS_ENABLED=YES`. | Prometheus metrics HTTP endpoint port for FL training metrics exporter. |

### SuperLink USER_INPUT Block (Copy-Paste Ready)

```
USER_INPUTS = [
  # Phase 1: Base architecture (variables 1-11)
  FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0",
  FL_NUM_ROUNDS = "O|number|Number of federated learning rounds||3",
  FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg|FedAvg",
  FL_MIN_FIT_CLIENTS = "O|number|Minimum clients for training round||2",
  FL_MIN_EVALUATE_CLIENTS = "O|number|Minimum clients for evaluation||2",
  FL_MIN_AVAILABLE_CLIENTS = "O|number|Minimum available clients to start||2",
  FL_FLEET_API_ADDRESS = "O|text|Fleet API listen address (host:port)||0.0.0.0:9092",
  FL_CONTROL_API_ADDRESS = "O|text|Control API listen address (host:port)||0.0.0.0:9093",
  FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess",
  FL_DATABASE = "O|text|Database path for state persistence||state/state.db",
  FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO",

  # Phase 5: Strategy parameters (variables 12-16)
  FL_PROXIMAL_MU = "O|number-float|FedProx proximal term (mu)||1.0",
  FL_SERVER_LR = "O|number-float|Server-side learning rate||0.1",
  FL_CLIENT_LR = "O|number-float|Client-side learning rate||0.1",
  FL_NUM_MALICIOUS = "O|number|Expected malicious clients (Krum/Bulyan)||0",
  FL_TRIM_BETA = "O|number-float|Trim fraction per tail (FedTrimmedAvg)||0.2",

  # Phase 5: Checkpointing (variables 17-19)
  FL_CHECKPOINT_ENABLED = "O|boolean|Enable model checkpointing||NO",
  FL_CHECKPOINT_INTERVAL = "O|number|Save checkpoint every N rounds||5",
  FL_CHECKPOINT_PATH = "O|text|Checkpoint directory (container path)||/app/checkpoints",

  # Phase 7: Multi-site federation (variables 20-22)
  FL_GRPC_KEEPALIVE_TIME = "O|number|gRPC keepalive interval in seconds||60",
  FL_GRPC_KEEPALIVE_TIMEOUT = "O|number|gRPC keepalive ACK timeout in seconds||20",
  FL_CERT_EXTRA_SAN = "O|text|Additional SAN entries for auto-generated cert (comma-separated)||",

  # Phase 8: Monitoring (variables 23-24)
  FL_METRICS_ENABLED = "O|boolean|Enable Prometheus metrics exporter||NO",
  FL_METRICS_PORT = "O|number|Prometheus metrics exporter port||9101"
]
```

---

## 4. SuperNode Parameters

These 13 variables configure the Flower SuperNode appliance. All are optional. Zero-config deployment discovers the SuperLink via OneGate and connects with default settings (see Section 9). Variables #1-7 are Phase 1 (base architecture). Variables #8-10 are Phase 6 (GPU configuration). Variables #11-12 are Phase 7 (multi-site federation: gRPC keepalive). Variable #13 is Phase 8 (monitoring: DCGM GPU metrics exporter).

**Appliance:** SuperNode only
**Spec reference:** `spec/02-supernode-appliance.md`, Section 13

| # | Context Variable | USER_INPUT Definition | Type | Default | Validation Rule | Flower Mapping |
|---|------------------|----------------------|------|---------|-----------------|----------------|
| 1 | `FLOWER_VERSION` | `O\|text\|Flower Docker image version tag\|\|1.25.0` | text | `1.25.0` | Non-empty string matching `[0-9]+\.[0-9]+\.[0-9]+` pattern | Docker image tag: `flwr/supernode:${FLOWER_VERSION}` |
| 2 | `FL_SUPERLINK_ADDRESS` | `O\|text\|SuperLink Fleet API address (host:port)\|\|` | text | (empty) | If set: `host:port` format; port in range 1-65535. Empty triggers OneGate discovery. | CLI flag: `--superlink` |
| 3 | `FL_NODE_CONFIG` | `O\|text\|Space-separated key=value node config\|\|` | text | (empty) | If set: space-separated `key=value` pairs. Keys must be alphanumeric with hyphens. | CLI flag: `--node-config` |
| 4 | `FL_MAX_RETRIES` | `O\|number\|Max reconnection attempts (0=unlimited)\|\|0` | number | `0` | Non-negative integer (>=0). `0` means unlimited. | CLI flag: `--max-retries` |
| 5 | `FL_MAX_WAIT_TIME` | `O\|number\|Max wait time for connection in seconds (0=unlimited)\|\|0` | number | `0` | Non-negative integer (>=0). `0` means unlimited. | CLI flag: `--max-wait-time` |
| 6 | `FL_ISOLATION` | `O\|list\|App execution isolation mode\|subprocess,process\|subprocess` | list | `subprocess` | One of: `subprocess`, `process` | CLI flag: `--isolation` |
| 7 | `FL_LOG_LEVEL` | `O\|list\|Log verbosity\|DEBUG,INFO,WARNING,ERROR\|INFO` | list | `INFO` | One of: `DEBUG`, `INFO`, `WARNING`, `ERROR` | Environment variable: `FLWR_LOG_LEVEL` |
| 8 | `FL_GPU_ENABLED` | `O\|boolean\|Enable GPU passthrough (requires GPU-enabled VM template)\|\|NO` | boolean | `NO` | Must be `YES` or `NO` (case-insensitive) | Docker run flag: `--gpus all` when YES |
| 9 | `FL_CUDA_VISIBLE_DEVICES` | `O\|text\|GPU device IDs visible to container (e.g., 0 or 0,1)\|\|all` | text | `all` | If not `all`, must be comma-separated integers (e.g., `0`, `0,1`, `0,1,2`). Only effective when `FL_GPU_ENABLED=YES`. | Docker env: `-e CUDA_VISIBLE_DEVICES` |
| 10 | `FL_GPU_MEMORY_FRACTION` | `O\|number-float\|GPU memory fraction for PyTorch (0.0-1.0)\|\|0.8` | number-float | `0.8` | Float between 0.0 and 1.0 inclusive. Only effective when `ML_FRAMEWORK=pytorch` and `FL_GPU_ENABLED=YES`. | PyTorch: `torch.cuda.set_per_process_memory_fraction()` |
| 11 | `FL_GRPC_KEEPALIVE_TIME` | `O\|number\|gRPC keepalive interval in seconds\|\|60` | number | `60` | Positive integer (>0). Warning if <10. | gRPC channel option: `grpc.keepalive_time_ms` (value * 1000) |
| 12 | `FL_GRPC_KEEPALIVE_TIMEOUT` | `O\|number\|gRPC keepalive ACK timeout in seconds\|\|20` | number | `20` | Positive integer (>0). Must be < `FL_GRPC_KEEPALIVE_TIME`. | gRPC channel option: `grpc.keepalive_timeout_ms` (value * 1000) |
| 13 | `FL_DCGM_ENABLED` | `O\|boolean\|Enable DCGM GPU metrics exporter\|\|NO` | boolean | `NO` | `YES` or `NO`. Requires `FL_GPU_ENABLED=YES` (Phase 6). If GPU not available, sidecar not started (warning logged). | When YES: starts DCGM Exporter sidecar container (docker pull + docker run on port 9400). See [`spec/13-monitoring-observability.md`](13-monitoring-observability.md) Section 6. |

**GPU configuration notes:**
- `FL_GPU_ENABLED` is the master switch for GPU passthrough. When `NO` (default), variables #9-10 are ignored.
- `FL_CUDA_VISIBLE_DEVICES` controls which GPUs the container sees. Default `all` exposes every GPU assigned to the VM.
- `FL_GPU_MEMORY_FRACTION` is a soft limit for PyTorch only. TensorFlow uses memory growth by default (no fraction needed). See `spec/10-gpu-passthrough.md` for complete GPU stack configuration and validation procedures.

### SuperNode USER_INPUT Block (Copy-Paste Ready)

```
USER_INPUTS = [
  # Phase 1: Base architecture (variables 1-7)
  FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0",
  FL_SUPERLINK_ADDRESS = "O|text|SuperLink Fleet API address (host:port)||",
  FL_NODE_CONFIG = "O|text|Space-separated key=value node config||",
  FL_MAX_RETRIES = "O|number|Max reconnection attempts (0=unlimited)||0",
  FL_MAX_WAIT_TIME = "O|number|Max wait time for connection in seconds (0=unlimited)||0",
  FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess",
  FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO",

  # Phase 6: GPU configuration (variables 8-10)
  FL_GPU_ENABLED = "O|boolean|Enable GPU passthrough (requires GPU-enabled VM template)||NO",
  FL_CUDA_VISIBLE_DEVICES = "O|text|GPU device IDs visible to container (e.g., 0 or 0,1)||all",
  FL_GPU_MEMORY_FRACTION = "O|number-float|GPU memory fraction for PyTorch (0.0-1.0)||0.8",

  # Phase 7: Multi-site federation (variables 11-12)
  FL_GRPC_KEEPALIVE_TIME = "O|number|gRPC keepalive interval in seconds||60",
  FL_GRPC_KEEPALIVE_TIMEOUT = "O|number|gRPC keepalive ACK timeout in seconds||20",

  # Phase 8: Monitoring (variable 13)
  FL_DCGM_ENABLED = "O|boolean|Enable DCGM GPU metrics exporter||NO"
]
```

---

## 5. Shared Infrastructure Parameters

These 5 variables are set in the VM template CONTEXT section for both appliances. They are NOT exposed as USER_INPUTs -- they are infrastructure-level settings managed by the template author, not the end user deploying the appliance.

**Appliance:** Both SuperLink and SuperNode
**Spec reference:** `spec/01-superlink-appliance.md` Section 12, `spec/02-supernode-appliance.md` Section 13

| # | Context Variable | Value | Type | Purpose | Notes |
|---|------------------|-------|------|---------|-------|
| 1 | `TOKEN` | `YES` | fixed | Enables OneGate authentication token generation. Provides `/run/one-context/token.txt`. | Required for OneGate service discovery (SuperNode) and readiness publication (both). Without `TOKEN=YES`, all OneGate API calls fail. |
| 2 | `NETWORK` | `YES` | fixed | Enables network configuration by the contextualization agent. | Standard for all OpenNebula appliances. Without it, the VM has no network configuration. |
| 3 | `REPORT_READY` | `YES` | fixed | Reports VM readiness to OneGate after the health check passes. | Signals to OneFlow that the appliance role is operational. Gates on `READY_SCRIPT_PATH`. |
| 4 | `READY_SCRIPT_PATH` | `/opt/flower/scripts/health-check.sh` | fixed | Path to the script that determines if the appliance is ready. | SuperLink: checks TCP port 9092. SuperNode: checks container running state. Exit code 0 = ready. |
| 5 | `SSH_PUBLIC_KEY` | `$USER[SSH_PUBLIC_KEY]` | from user | Injects the deploying user's SSH public key for operator access. | Standard OpenNebula pattern. Enables SSH debugging access to the VM. |

### Infrastructure CONTEXT Block (Template Author Reference)

```
CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  READY_SCRIPT_PATH = "/opt/flower/scripts/health-check.sh",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
  START_SCRIPT_BASE64 = "<base64-encoded launcher script>"
]
```

**`START_SCRIPT_BASE64`:** Contains the base64-encoded launcher script that triggers `/opt/flower/scripts/configure.sh` and `/opt/flower/scripts/bootstrap.sh`. The exact content is implementation-specific and not defined in this reference. It is the entry point for all Flower-specific initialization.

---

## 5a. Service-Level Parameters (OneFlow)

This variable is set at the OneFlow service level, applying to all roles (both SuperLink and SuperNode). It is exposed as a USER_INPUT at the service level rather than per-role. This follows the same pattern as `FLOWER_VERSION` and `FL_LOG_LEVEL` in OneFlow templates (see `spec/08-single-site-orchestration.md`).

**Appliance:** Both SuperLink and SuperNode (via OneFlow service-level)
**Spec reference:** `spec/13-monitoring-observability.md`, Section 3

| # | Context Variable | USER_INPUT Definition | Type | Default | Validation Rule | Flower Mapping |
|---|------------------|----------------------|------|---------|-----------------|----------------|
| 1 | `FL_LOG_FORMAT` | `O\|list\|Log output format\|text,json\|text` | list | `text` | One of: `text`, `json` | When `json`: FlowerJSONFormatter replaces default text formatter on `flwr` logger. When `text`: Flower's default format (no change). See [`spec/13-monitoring-observability.md`](13-monitoring-observability.md) Section 3. |

### Service-Level USER_INPUT (Copy-Paste Ready)

```
# Phase 8: Monitoring -- service-level (applies to all roles)
FL_LOG_FORMAT = "O|list|Log output format|text,json|text"
```

---

## 6. Phase 2+ Placeholder Parameters

These 5 variables are documented for forward compatibility. They appear in the USER_INPUTS definitions but have no effect in Phase 1. The contextualization scripts SHALL recognize these variables but skip their processing with a log message: "Variable X is a Phase N feature; ignoring in current appliance version."

**Status:** Placeholder -- not functional in Phase 1.

**Note:** `FL_GPU_ENABLED`, `FL_CUDA_VISIBLE_DEVICES`, and `FL_GPU_MEMORY_FRACTION` were previously placeholders. As of Phase 6, they are now functional and documented in Section 4 (SuperNode Parameters).

| # | Context Variable | USER_INPUT Definition | Phase | Default | Appliance | Purpose |
|---|------------------|----------------------|-------|---------|-----------|---------|
| 1 | `FL_TLS_ENABLED` | `O\|boolean\|Enable TLS encryption\|\|NO` | Phase 2 | `NO` | Both | Master switch for TLS. When `YES`, the appliance uses certificates instead of `--insecure`. |
| 2 | `FL_SSL_CA_CERTFILE` | `O\|text64\|CA certificate (base64 PEM)` | Phase 2 | (empty) | Both | Base64-encoded CA certificate for TLS trust chain. SuperLink uses for server cert verification; SuperNode uses for `--root-certificates`. |
| 3 | `FL_SSL_CERTFILE` | `O\|text64\|Server certificate (base64 PEM)` | Phase 2 | (empty) | SuperLink | Base64-encoded server certificate. Used with `--ssl-certfile`. |
| 4 | `FL_SSL_KEYFILE` | `O\|text64\|Server private key (base64 PEM)` | Phase 2 | (empty) | SuperLink | Base64-encoded server private key. Used with `--ssl-keyfile`. |
| 5 | `ML_FRAMEWORK` | `O\|list\|ML framework\|pytorch,tensorflow,sklearn\|pytorch` | Phase 3 | `pytorch` | SuperNode | Selects the ML framework variant image. Affects which `flwr/supernode` image tag is used. |

### Placeholder USER_INPUT Block (For Reference)

```
# Phase 2: TLS (not functional in Phase 1)
FL_TLS_ENABLED = "O|boolean|Enable TLS encryption||NO"
FL_SSL_CA_CERTFILE = "O|text64|CA certificate (base64 PEM)"
FL_SSL_CERTFILE = "O|text64|Server certificate (base64 PEM)"
FL_SSL_KEYFILE = "O|text64|Server private key (base64 PEM)"

# Phase 3: ML Framework (not functional in Phase 1)
ML_FRAMEWORK = "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch"
```

---

## 7. Naming Convention Rationale

The variable naming follows established OpenNebula marketplace conventions and avoids conflicts with built-in OpenNebula context variables.

### Prefix Rules

| Prefix | Scope | Examples | Rationale |
|--------|-------|----------|-----------|
| `FLOWER_` | Product-level settings | `FLOWER_VERSION` | Follows OpenNebula marketplace convention for product-scoped variables (cf. `WORDPRESS_VERSION`, `MINIO_VERSION`). Used for settings that identify the product, not configure its behavior. |
| `FL_` | Flower behavior configuration | `FL_NUM_ROUNDS`, `FL_STRATEGY`, `FL_SUPERLINK_ADDRESS` | Short prefix for Flower-specific configuration. Distinctive and unlikely to collide with OpenNebula built-in variables (`ETH0_*`, `NETWORK`, `TOKEN`, etc.) or other marketplace appliances. |
| `ML_` | ML framework settings | `ML_FRAMEWORK` | Separate prefix for ML-layer settings that are not Flower-specific. Could apply to non-Flower ML appliances in the future. |
| (none) | OpenNebula infrastructure | `TOKEN`, `NETWORK`, `REPORT_READY`, `SSH_PUBLIC_KEY` | Standard OpenNebula variables. No prefix because they are platform-level, not application-level. |

### Style Rules

- **All uppercase:** Standard OpenNebula CONTEXT variable style. Consistent with `ETH0_IP`, `VMID`, `TOKEN`.
- **Underscores as separators:** `FL_NUM_ROUNDS`, not `FL-NUM-ROUNDS` or `FlNumRounds`. Follows shell variable naming conventions and OpenNebula standard.
- **Descriptive names:** `FL_SUPERLINK_ADDRESS`, not `FL_SLA` or `FL_ADDR`. Variable names should be self-documenting in log output and configuration files.
- **No underscores in values:** Only in variable names. Values use standard formats (comma-separated lists, dotted versions, colon-separated host:port).

### Collision Avoidance

The `FL_` prefix was chosen after verifying it does not collide with:
- OpenNebula built-in CONTEXT variables (none use `FL_` prefix)
- Common one-apps appliance variables (WordPress uses `WORDPRESS_*`, MinIO uses `MINIO_*`)
- Linux environment conventions (`HOME`, `PATH`, `USER`, `LANG`, etc.)

---

## 8. Validation Strategy

The appliance boot scripts SHALL validate all contextualization variables during the configure stage (boot Step 4 for SuperLink, Step 3 for SuperNode). Validation uses a **fail-fast** approach: the first validation error aborts boot with a clear error message.

### Validation Rules by Variable

| Variable | Rule | Error Message Template |
|----------|------|----------------------|
| `FLOWER_VERSION` | Non-empty; matches semver-like pattern `[0-9]+\.[0-9]+\.[0-9]+` | `"Invalid FLOWER_VERSION: '${VALUE}'. Expected format: X.Y.Z (e.g., 1.25.0)"` |
| `FL_NUM_ROUNDS` | Positive integer (>0) | `"Invalid FL_NUM_ROUNDS: '${VALUE}'. Must be a positive integer."` |
| `FL_STRATEGY` | Exact match: `FedAvg`, `FedProx`, `FedAdam`, `Krum`, `Bulyan`, or `FedTrimmedAvg` | `"Unknown FL_STRATEGY: '${VALUE}'. Valid options: FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg."` |
| `FL_MIN_FIT_CLIENTS` | Positive integer (>0) | `"Invalid FL_MIN_FIT_CLIENTS: '${VALUE}'. Must be a positive integer."` |
| `FL_MIN_EVALUATE_CLIENTS` | Positive integer (>0) | `"Invalid FL_MIN_EVALUATE_CLIENTS: '${VALUE}'. Must be a positive integer."` |
| `FL_MIN_AVAILABLE_CLIENTS` | Positive integer (>0) | `"Invalid FL_MIN_AVAILABLE_CLIENTS: '${VALUE}'. Must be a positive integer."` |
| `FL_FLEET_API_ADDRESS` | Matches `host:port` where port is 1-65535 | `"Invalid FL_FLEET_API_ADDRESS: '${VALUE}'. Expected format: host:port."` |
| `FL_CONTROL_API_ADDRESS` | Matches `host:port` where port is 1-65535 | `"Invalid FL_CONTROL_API_ADDRESS: '${VALUE}'. Expected format: host:port."` |
| `FL_ISOLATION` | Exact match: `subprocess` or `process` | `"Unknown FL_ISOLATION: '${VALUE}'. Valid options: subprocess, process."` |
| `FL_DATABASE` | Non-empty string | `"FL_DATABASE cannot be empty."` |
| `FL_LOG_LEVEL` | Exact match: `DEBUG`, `INFO`, `WARNING`, or `ERROR` | `"Unknown FL_LOG_LEVEL: '${VALUE}'. Valid options: DEBUG, INFO, WARNING, ERROR."` |
| `FL_SUPERLINK_ADDRESS` | If non-empty: matches `host:port` format | `"Invalid FL_SUPERLINK_ADDRESS: '${VALUE}'. Expected format: host:port or leave empty for OneGate discovery."` |
| `FL_NODE_CONFIG` | If non-empty: space-separated `key=value` pairs | `"Invalid FL_NODE_CONFIG: '${VALUE}'. Expected format: 'key1=val1 key2=val2'."` |
| `FL_MAX_RETRIES` | Non-negative integer (>=0) | `"Invalid FL_MAX_RETRIES: '${VALUE}'. Must be a non-negative integer."` |
| `FL_MAX_WAIT_TIME` | Non-negative integer (>=0) | `"Invalid FL_MAX_WAIT_TIME: '${VALUE}'. Must be a non-negative integer."` |
| `FL_PROXIMAL_MU` | Non-negative float (>=0.0) | `"Invalid FL_PROXIMAL_MU: '${VALUE}'. Must be a non-negative float."` |
| `FL_SERVER_LR` | Positive float (>0.0) | `"Invalid FL_SERVER_LR: '${VALUE}'. Must be a positive float."` |
| `FL_CLIENT_LR` | Positive float (>0.0) | `"Invalid FL_CLIENT_LR: '${VALUE}'. Must be a positive float."` |
| `FL_NUM_MALICIOUS` | Non-negative integer (>=0); if Krum: `n>=2f+3`; if Bulyan: `n>=4f+3` | `"Invalid FL_NUM_MALICIOUS: '${VALUE}'. Must be a non-negative integer."` |
| `FL_TRIM_BETA` | Float in range (0.0, 0.5) exclusive | `"Invalid FL_TRIM_BETA: '${VALUE}'. Must be a float between 0.0 and 0.5 (exclusive)."` |
| `FL_CHECKPOINT_ENABLED` | Exact match: `YES` or `NO` | `"Invalid FL_CHECKPOINT_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_CHECKPOINT_INTERVAL` | Positive integer (>0); ignored if `FL_CHECKPOINT_ENABLED != YES` | `"Invalid FL_CHECKPOINT_INTERVAL: '${VALUE}'. Must be a positive integer."` |
| `FL_CHECKPOINT_PATH` | Non-empty string; ignored if `FL_CHECKPOINT_ENABLED != YES` | `"FL_CHECKPOINT_PATH cannot be empty."` |
| `FL_GPU_ENABLED` | Exact match: `YES` or `NO` (case-insensitive) | `"Invalid FL_GPU_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_CUDA_VISIBLE_DEVICES` | If not `all`: must be comma-separated integers (e.g., `0`, `0,1`, `0,1,2`). Ignored if `FL_GPU_ENABLED != YES`. | `"Invalid FL_CUDA_VISIBLE_DEVICES: '${VALUE}'. Must be 'all' or comma-separated GPU IDs (e.g., 0,1)."` |
| `FL_GPU_MEMORY_FRACTION` | Float between 0.0 and 1.0 inclusive. Ignored if `FL_GPU_ENABLED != YES`. | `"Invalid FL_GPU_MEMORY_FRACTION: '${VALUE}'. Must be a float between 0.0 and 1.0."` |
| `FL_GRPC_KEEPALIVE_TIME` | Positive integer (>0). Warning if <10. | `"Invalid FL_GRPC_KEEPALIVE_TIME: '${VALUE}'. Must be a positive integer."` |
| `FL_GRPC_KEEPALIVE_TIMEOUT` | Positive integer (>0). Must be < `FL_GRPC_KEEPALIVE_TIME`. | `"Invalid FL_GRPC_KEEPALIVE_TIMEOUT: '${VALUE}'. Must be a positive integer less than FL_GRPC_KEEPALIVE_TIME."` |
| `FL_CERT_EXTRA_SAN` | If set: comma-separated entries matching pattern `IP:[0-9.]+` or `DNS:[a-zA-Z0-9.-]+`. | `"Invalid FL_CERT_EXTRA_SAN: '${VALUE}'. Must be comma-separated entries in format IP:<addr> or DNS:<name>."` |
| `FL_LOG_FORMAT` | Must be `text` or `json` | `"Invalid FL_LOG_FORMAT: '${VALUE}'. Must be 'text' or 'json'."` |
| `FL_METRICS_ENABLED` | Must be `YES` or `NO` | `"Invalid FL_METRICS_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_METRICS_PORT` | Integer 1024-65535; must not be 9091, 9092, or 9093 | `"Invalid FL_METRICS_PORT: '${VALUE}'. Must be integer 1024-65535, not 9091-9093."` |
| `FL_DCGM_ENABLED` | Must be `YES` or `NO`. Cross-check: if YES and `FL_GPU_ENABLED` != YES, log warning (not fatal). | `"Invalid FL_DCGM_ENABLED: '${VALUE}'. Must be YES or NO."` |

### Validation Pseudocode

```bash
validate_config() {
    local errors=0

    # Version format
    if [ -n "$FLOWER_VERSION" ] && ! [[ "$FLOWER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "ERROR" "Invalid FLOWER_VERSION: '${FLOWER_VERSION}'. Expected format: X.Y.Z"
        errors=$((errors + 1))
    fi

    # Positive integers (SuperLink)
    for var in FL_NUM_ROUNDS FL_MIN_FIT_CLIENTS FL_MIN_EVALUATE_CLIENTS FL_MIN_AVAILABLE_CLIENTS; do
        val=$(eval echo \$$var)
        if [ -n "$val" ] && ! [[ "$val" =~ ^[1-9][0-9]*$ ]]; then
            log "ERROR" "Invalid $var: '$val'. Must be a positive integer."
            errors=$((errors + 1))
        fi
    done

    # Non-negative integers (SuperNode)
    for var in FL_MAX_RETRIES FL_MAX_WAIT_TIME; do
        val=$(eval echo \$$var)
        if [ -n "$val" ] && ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Invalid $var: '$val'. Must be a non-negative integer."
            errors=$((errors + 1))
        fi
    done

    # Enum validations
    case "${FL_STRATEGY:-FedAvg}" in
        FedAvg|FedProx|FedAdam|Krum|Bulyan|FedTrimmedAvg) ;;
        *) log "ERROR" "Unknown FL_STRATEGY: '${FL_STRATEGY}'."; errors=$((errors + 1)) ;;
    esac

    case "${FL_ISOLATION:-subprocess}" in
        subprocess|process) ;;
        *) log "ERROR" "Unknown FL_ISOLATION: '${FL_ISOLATION}'."; errors=$((errors + 1)) ;;
    esac

    case "${FL_LOG_LEVEL:-INFO}" in
        DEBUG|INFO|WARNING|ERROR) ;;
        *) log "ERROR" "Unknown FL_LOG_LEVEL: '${FL_LOG_LEVEL}'."; errors=$((errors + 1)) ;;
    esac

    # host:port format
    for var in FL_FLEET_API_ADDRESS FL_CONTROL_API_ADDRESS FL_SUPERLINK_ADDRESS; do
        val=$(eval echo \$$var)
        if [ -n "$val" ] && ! [[ "$val" =~ ^[^:]+:[0-9]+$ ]]; then
            log "ERROR" "Invalid $var: '$val'. Expected format: host:port."
            errors=$((errors + 1))
        fi
    done

    # Node config format (space-separated key=value)
    if [ -n "$FL_NODE_CONFIG" ]; then
        for pair in $FL_NODE_CONFIG; do
            if ! [[ "$pair" =~ ^[a-zA-Z0-9_-]+=.+$ ]]; then
                log "ERROR" "Invalid FL_NODE_CONFIG pair: '$pair'. Expected format: key=value."
                errors=$((errors + 1))
            fi
        done
    fi

    # --- Phase 5: Strategy parameters and checkpointing ---

    # Float validations (non-negative: FL_PROXIMAL_MU; positive: FL_SERVER_LR, FL_CLIENT_LR)
    if [ -n "$FL_PROXIMAL_MU" ] && ! [[ "$FL_PROXIMAL_MU" =~ ^[0-9]*\.?[0-9]+$ ]]; then
        log "ERROR" "Invalid FL_PROXIMAL_MU: '${FL_PROXIMAL_MU}'. Must be a non-negative float."
        errors=$((errors + 1))
    fi
    for var in FL_SERVER_LR FL_CLIENT_LR; do
        val=$(eval echo \$$var)
        if [ -n "$val" ]; then
            if ! [[ "$val" =~ ^[0-9]*\.?[0-9]+$ ]] || \
               [ "$(echo "$val <= 0" | bc -l 2>/dev/null)" = "1" ]; then
                log "ERROR" "Invalid $var: '$val'. Must be a positive float."
                errors=$((errors + 1))
            fi
        fi
    done

    # FL_NUM_MALICIOUS: non-negative integer
    if [ -n "$FL_NUM_MALICIOUS" ] && ! [[ "$FL_NUM_MALICIOUS" =~ ^[0-9]+$ ]]; then
        log "ERROR" "Invalid FL_NUM_MALICIOUS: '${FL_NUM_MALICIOUS}'. Must be a non-negative integer."
        errors=$((errors + 1))
    fi

    # FL_TRIM_BETA: float in range (0.0, 0.5) exclusive
    if [ -n "$FL_TRIM_BETA" ]; then
        if ! [[ "$FL_TRIM_BETA" =~ ^[0-9]*\.?[0-9]+$ ]] || \
           [ "$(echo "$FL_TRIM_BETA <= 0" | bc -l 2>/dev/null)" = "1" ] || \
           [ "$(echo "$FL_TRIM_BETA >= 0.5" | bc -l 2>/dev/null)" = "1" ]; then
            log "ERROR" "Invalid FL_TRIM_BETA: '${FL_TRIM_BETA}'. Must be between 0.0 and 0.5 (exclusive)."
            errors=$((errors + 1))
        fi
    fi

    # FL_CHECKPOINT_ENABLED: boolean
    if [ -n "$FL_CHECKPOINT_ENABLED" ]; then
        case "${FL_CHECKPOINT_ENABLED}" in
            YES|NO) ;;
            *) log "ERROR" "Invalid FL_CHECKPOINT_ENABLED: '${FL_CHECKPOINT_ENABLED}'. Must be YES or NO."
               errors=$((errors + 1)) ;;
        esac
    fi

    # FL_CHECKPOINT_INTERVAL, FL_CHECKPOINT_PATH: only when checkpointing enabled
    if [ "${FL_CHECKPOINT_ENABLED:-NO}" = "YES" ]; then
        if [ -n "$FL_CHECKPOINT_INTERVAL" ] && ! [[ "$FL_CHECKPOINT_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
            log "ERROR" "Invalid FL_CHECKPOINT_INTERVAL: '${FL_CHECKPOINT_INTERVAL}'. Must be a positive integer."
            errors=$((errors + 1))
        fi
        if [ -z "${FL_CHECKPOINT_PATH}" ]; then
            log "ERROR" "FL_CHECKPOINT_PATH cannot be empty when FL_CHECKPOINT_ENABLED=YES."
            errors=$((errors + 1))
        fi
    fi

    # Byzantine client count validation
    local n="${FL_MIN_AVAILABLE_CLIENTS:-2}"
    local f="${FL_NUM_MALICIOUS:-0}"
    if [ "${FL_STRATEGY:-FedAvg}" = "Krum" ] && [ "$f" -gt 0 ] 2>/dev/null; then
        local min_n=$((2 * f + 3))
        if [ "$n" -lt "$min_n" ]; then
            log "ERROR" "Krum requires n >= 2*f+3. FL_MIN_AVAILABLE_CLIENTS=$n, FL_NUM_MALICIOUS=$f requires n >= $min_n."
            errors=$((errors + 1))
        fi
    fi
    if [ "${FL_STRATEGY:-FedAvg}" = "Bulyan" ] && [ "$f" -gt 0 ] 2>/dev/null; then
        local min_n=$((4 * f + 3))
        if [ "$n" -lt "$min_n" ]; then
            log "ERROR" "Bulyan requires n >= 4*f+3. FL_MIN_AVAILABLE_CLIENTS=$n, FL_NUM_MALICIOUS=$f requires n >= $min_n."
            errors=$((errors + 1))
        fi
    fi

    # Conditional ignore logging for strategy-specific params
    if [ -n "$FL_PROXIMAL_MU" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedProx" ]; then
        log "INFO" "FL_PROXIMAL_MU ignored -- only applies to FedProx strategy"
    fi
    if [ -n "$FL_SERVER_LR" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedAdam" ]; then
        log "INFO" "FL_SERVER_LR ignored -- only applies to FedAdam strategy"
    fi
    if [ -n "$FL_CLIENT_LR" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedAdam" ]; then
        log "INFO" "FL_CLIENT_LR ignored -- only applies to FedAdam strategy"
    fi
    if [ -n "$FL_NUM_MALICIOUS" ] && [ "${FL_STRATEGY:-FedAvg}" != "Krum" ] && [ "${FL_STRATEGY:-FedAvg}" != "Bulyan" ]; then
        log "INFO" "FL_NUM_MALICIOUS ignored -- only applies to Krum or Bulyan strategy"
    fi
    if [ -n "$FL_TRIM_BETA" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedTrimmedAvg" ]; then
        log "INFO" "FL_TRIM_BETA ignored -- only applies to FedTrimmedAvg strategy"
    fi

    # --- Phase 6: GPU configuration ---

    # FL_GPU_ENABLED: boolean
    if [ -n "$FL_GPU_ENABLED" ]; then
        case "$(echo "$FL_GPU_ENABLED" | tr '[:lower:]' '[:upper:]')" in
            YES|NO) ;;
            *) log "ERROR" "Invalid FL_GPU_ENABLED: '${FL_GPU_ENABLED}'. Must be YES or NO."
               errors=$((errors + 1)) ;;
        esac
    fi

    # FL_CUDA_VISIBLE_DEVICES: 'all' or comma-separated integers
    if [ -n "$FL_CUDA_VISIBLE_DEVICES" ] && [ "$FL_CUDA_VISIBLE_DEVICES" != "all" ]; then
        if ! [[ "$FL_CUDA_VISIBLE_DEVICES" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
            log "ERROR" "Invalid FL_CUDA_VISIBLE_DEVICES: '${FL_CUDA_VISIBLE_DEVICES}'. Must be 'all' or comma-separated GPU IDs (e.g., 0,1)."
            errors=$((errors + 1))
        fi
    fi

    # FL_GPU_MEMORY_FRACTION: float between 0.0 and 1.0
    if [ -n "$FL_GPU_MEMORY_FRACTION" ]; then
        if ! [[ "$FL_GPU_MEMORY_FRACTION" =~ ^[0-9]*\.?[0-9]+$ ]] || \
           [ "$(echo "$FL_GPU_MEMORY_FRACTION < 0" | bc -l 2>/dev/null)" = "1" ] || \
           [ "$(echo "$FL_GPU_MEMORY_FRACTION > 1" | bc -l 2>/dev/null)" = "1" ]; then
            log "ERROR" "Invalid FL_GPU_MEMORY_FRACTION: '${FL_GPU_MEMORY_FRACTION}'. Must be a float between 0.0 and 1.0."
            errors=$((errors + 1))
        fi
    fi

    # --- Phase 7: gRPC keepalive and certificate SAN ---

    # FL_GRPC_KEEPALIVE_TIME: positive integer
    if [ -n "$FL_GRPC_KEEPALIVE_TIME" ] && ! [[ "$FL_GRPC_KEEPALIVE_TIME" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "Invalid FL_GRPC_KEEPALIVE_TIME: '${FL_GRPC_KEEPALIVE_TIME}'. Must be a positive integer."
        errors=$((errors + 1))
    fi
    if [ -n "$FL_GRPC_KEEPALIVE_TIME" ] && [ "${FL_GRPC_KEEPALIVE_TIME:-60}" -lt 10 ] 2>/dev/null; then
        log "WARN" "FL_GRPC_KEEPALIVE_TIME=${FL_GRPC_KEEPALIVE_TIME} is aggressive and may cause excessive network traffic"
    fi

    # FL_GRPC_KEEPALIVE_TIMEOUT: positive integer, must be < keepalive_time
    if [ -n "$FL_GRPC_KEEPALIVE_TIMEOUT" ] && ! [[ "$FL_GRPC_KEEPALIVE_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
        log "ERROR" "Invalid FL_GRPC_KEEPALIVE_TIMEOUT: '${FL_GRPC_KEEPALIVE_TIMEOUT}'. Must be a positive integer."
        errors=$((errors + 1))
    fi
    if [ -n "$FL_GRPC_KEEPALIVE_TIMEOUT" ] && [ -n "$FL_GRPC_KEEPALIVE_TIME" ]; then
        if [ "$FL_GRPC_KEEPALIVE_TIMEOUT" -ge "$FL_GRPC_KEEPALIVE_TIME" ] 2>/dev/null; then
            log "ERROR" "FL_GRPC_KEEPALIVE_TIMEOUT (${FL_GRPC_KEEPALIVE_TIMEOUT}) must be less than FL_GRPC_KEEPALIVE_TIME (${FL_GRPC_KEEPALIVE_TIME})."
            errors=$((errors + 1))
        fi
    fi

    # FL_CERT_EXTRA_SAN: comma-separated IP:<addr> or DNS:<name> entries
    if [ -n "$FL_CERT_EXTRA_SAN" ]; then
        IFS=',' read -ra SAN_ENTRIES <<< "$FL_CERT_EXTRA_SAN"
        for entry in "${SAN_ENTRIES[@]}"; do
            entry=$(echo "$entry" | xargs)  # trim whitespace
            if ! [[ "$entry" =~ ^IP:[0-9.]+ ]] && ! [[ "$entry" =~ ^DNS:[a-zA-Z0-9.-]+$ ]]; then
                log "ERROR" "Invalid FL_CERT_EXTRA_SAN entry: '${entry}'. Expected format: IP:<addr> or DNS:<name>."
                errors=$((errors + 1))
            fi
        done
    fi

    # --- Phase 8: Monitoring and observability ---

    # FL_LOG_FORMAT: must be 'text' or 'json'
    case "${FL_LOG_FORMAT:-text}" in
        text|json) ;;
        *) log "ERROR" "Invalid FL_LOG_FORMAT: '${FL_LOG_FORMAT}'. Must be 'text' or 'json'."
           errors=$((errors + 1)) ;;
    esac

    # FL_METRICS_ENABLED: boolean
    if [ -n "$FL_METRICS_ENABLED" ]; then
        case "${FL_METRICS_ENABLED}" in
            YES|NO) ;;
            *) log "ERROR" "Invalid FL_METRICS_ENABLED: '${FL_METRICS_ENABLED}'. Must be YES or NO."
               errors=$((errors + 1)) ;;
        esac
    fi

    # FL_METRICS_PORT: integer 1024-65535, not 9091-9093
    if [ -n "$FL_METRICS_PORT" ]; then
        if ! [[ "$FL_METRICS_PORT" =~ ^[0-9]+$ ]] || \
           [ "$FL_METRICS_PORT" -lt 1024 ] || [ "$FL_METRICS_PORT" -gt 65535 ]; then
            log "ERROR" "Invalid FL_METRICS_PORT: '${FL_METRICS_PORT}'. Must be integer 1024-65535, not 9091-9093."
            errors=$((errors + 1))
        elif [ "$FL_METRICS_PORT" -eq 9091 ] || [ "$FL_METRICS_PORT" -eq 9092 ] || [ "$FL_METRICS_PORT" -eq 9093 ]; then
            log "ERROR" "Invalid FL_METRICS_PORT: '${FL_METRICS_PORT}'. Must be integer 1024-65535, not 9091-9093."
            errors=$((errors + 1))
        fi
    fi

    # FL_DCGM_ENABLED: boolean
    if [ -n "$FL_DCGM_ENABLED" ]; then
        case "${FL_DCGM_ENABLED}" in
            YES|NO) ;;
            *) log "ERROR" "Invalid FL_DCGM_ENABLED: '${FL_DCGM_ENABLED}'. Must be YES or NO."
               errors=$((errors + 1)) ;;
        esac
    fi

    # FL_DCGM_ENABLED conditional warning
    if [ "${FL_DCGM_ENABLED:-NO}" = "YES" ] && [ "${FL_GPU_ENABLED:-NO}" != "YES" ]; then
        log "WARN" "FL_DCGM_ENABLED=YES but FL_GPU_ENABLED is not YES. DCGM will not start."
    fi

    # Conditional ignore logging for monitoring-specific params
    if [ "${FL_METRICS_ENABLED:-NO}" != "YES" ]; then
        if [ -n "$FL_METRICS_PORT" ] && [ "${FL_METRICS_PORT}" != "9101" ]; then
            log "INFO" "FL_METRICS_PORT ignored -- FL_METRICS_ENABLED is not YES"
        fi
    fi

    # Conditional ignore logging for GPU-specific params
    if [ "${FL_GPU_ENABLED:-NO}" != "YES" ]; then
        if [ -n "$FL_CUDA_VISIBLE_DEVICES" ] && [ "$FL_CUDA_VISIBLE_DEVICES" != "all" ]; then
            log "INFO" "FL_CUDA_VISIBLE_DEVICES ignored -- FL_GPU_ENABLED is not YES"
        fi
        if [ -n "$FL_GPU_MEMORY_FRACTION" ]; then
            log "INFO" "FL_GPU_MEMORY_FRACTION ignored -- FL_GPU_ENABLED is not YES"
        fi
    fi

    # Abort on errors
    if [ $errors -gt 0 ]; then
        log "FATAL" "$errors configuration error(s). Aborting boot."
        exit 1
    fi

    log "INFO" "Configuration validation passed."
}
```

### Validation Principles

1. **Fail-fast:** The first validation error is logged, but all variables are checked before aborting. This allows the operator to fix all errors in one pass rather than discovering them one at a time.
2. **Clear error messages:** Every error message includes the variable name, the invalid value, and the expected format. An operator should be able to fix the error without consulting documentation.
3. **Optional variables skip validation when unset:** If a variable is not provided by the user, validation is skipped and the default value is used. Only user-provided values are validated.
4. **Defaults are always valid:** The default values listed in this document are guaranteed to pass validation. They do not need to be validated.

---

## 9. Zero-Config Deployment Scenario

Both appliances are designed to work with zero user configuration. This section documents the exact behavior when a user deploys the SuperLink and SuperNode from the marketplace without changing any USER_INPUT values.

### Scenario: 1 SuperLink + 2 SuperNodes via OneFlow

**Preconditions:**
- OneFlow service template defines a `superlink` role (1 VM) and a `supernode` role (2 VMs).
- Deployment strategy is `straight` (SuperLink deploys first).
- All USER_INPUTs left at defaults (user clicks "Deploy" without changes).

**Step-by-step behavior:**

```
T=0s    OneFlow starts deploying SuperLink role
T=5s    SuperLink VM reaches RUNNING (OS booted)
T=15s   SuperLink configure.sh completes:
          FLOWER_VERSION = 1.25.0 (default)
          FL_NUM_ROUNDS = 3 (default)
          FL_STRATEGY = FedAvg (default)
          FL_MIN_FIT_CLIENTS = 2 (default)
          FL_MIN_EVALUATE_CLIENTS = 2 (default)
          FL_MIN_AVAILABLE_CLIENTS = 2 (default)
          FL_FLEET_API_ADDRESS = 0.0.0.0:9092 (default)
          FL_ISOLATION = subprocess (default)
          FL_DATABASE = state/state.db (default)
          FL_LOG_LEVEL = INFO (default)
T=25s   SuperLink container starts (from pre-baked image, no pull)
T=35s   SuperLink health check passes (port 9092 listening)
T=36s   SuperLink publishes to OneGate:
          FL_READY=YES
          FL_ENDPOINT=192.168.1.100:9092
          FL_VERSION=1.25.0
          FL_ROLE=superlink
T=37s   SuperLink VM reports READY via REPORT_READY

T=38s   OneFlow starts deploying SuperNode role (2 VMs in parallel)
T=48s   SuperNode VMs reach RUNNING (OS booted)
T=55s   SuperNode configure.sh on each VM:
          FL_SUPERLINK_ADDRESS = (empty) -> triggers OneGate discovery
          OneGate pre-check: connectivity verified
          Discovery attempt 1: FL_ENDPOINT=192.168.1.100:9092 found
          SUPERLINK_ADDRESS = 192.168.1.100:9092
T=60s   SuperNode containers start with --superlink 192.168.1.100:9092
          --insecure
          --isolation subprocess
          --max-retries 0 (unlimited)
          --max-wait-time 0 (unlimited)
T=65s   SuperNode containers reach running state
T=66s   SuperNode VMs publish FL_NODE_READY=YES to OneGate
T=67s   SuperNode VMs report READY via REPORT_READY

T=68s   All roles READY. SuperLink has 2 connected SuperNodes.
        FL_MIN_AVAILABLE_CLIENTS=2 is satisfied.
        Federated learning can begin when a Flower run is submitted.
```

**What the user sees:** A fully connected Flower federation ready for training. They submit a Flower run via the Control API (port 9093) or the Flower CLI, and FedAvg executes for 3 rounds across 2 clients.

### Zero-Config Resolved Configuration Summary

| Setting | SuperLink Value | SuperNode Value |
|---------|----------------|-----------------|
| Flower version | 1.25.0 | 1.25.0 |
| TLS mode | Insecure (no TLS) | Insecure (no TLS) |
| Isolation | Subprocess | Subprocess |
| Strategy | FedAvg | n/a (server-side) |
| Rounds | 3 | n/a (server-side) |
| Min clients | 2 fit / 2 eval / 2 available | n/a |
| Fleet API | 0.0.0.0:9092 | Connects to SuperLink:9092 |
| Reconnection | n/a | Unlimited retries, no timeout |
| Discovery | n/a (SuperLink is the target) | OneGate dynamic discovery |
| Log level | INFO | INFO |

---

## 10. Parameter Interaction Notes

This section documents non-obvious interactions between parameters that an implementer should be aware of.

### 10a. FLOWER_VERSION Must Match Across Appliances

**Variables involved:** `FLOWER_VERSION` (both SuperLink and SuperNode)

The SuperLink and SuperNode MUST run the same Flower version. A version mismatch causes gRPC protocol errors (UNIMPLEMENTED or INTERNAL status codes) because Flower's internal protobuf schemas change between versions.

**Enforcement strategy:** In OneFlow service templates, set `FLOWER_VERSION` at the service level (applied to all roles) rather than per-role. The appliance does NOT enforce version matching at boot -- it cannot know what version the other side is running. Version mismatch manifests as runtime gRPC errors.

### 10b. FL_MIN_*_CLIENTS Interaction

**Variables involved:** `FL_MIN_FIT_CLIENTS`, `FL_MIN_EVALUATE_CLIENTS`, `FL_MIN_AVAILABLE_CLIENTS`

These three variables interact to control when training rounds begin:

1. `FL_MIN_AVAILABLE_CLIENTS` gates when ANY round can start. If fewer clients are connected, the SuperLink waits.
2. `FL_MIN_FIT_CLIENTS` gates each training round. Must be <= `FL_MIN_AVAILABLE_CLIENTS` for training to ever start.
3. `FL_MIN_EVALUATE_CLIENTS` gates evaluation rounds. If set higher than connected clients, evaluation is skipped (not failed).

**Constraint:** `FL_MIN_FIT_CLIENTS <= FL_MIN_AVAILABLE_CLIENTS`. The validation script SHOULD warn (not fail) if this constraint is violated, as the SuperLink will simply wait indefinitely for enough clients.

### 10c. FL_SUPERLINK_ADDRESS vs OneGate Discovery

**Variables involved:** `FL_SUPERLINK_ADDRESS` (SuperNode), `TOKEN` (infrastructure)

The interaction follows a strict priority:

1. If `FL_SUPERLINK_ADDRESS` is set (non-empty), it is used directly. OneGate is not queried.
2. If `FL_SUPERLINK_ADDRESS` is empty AND `TOKEN=YES` (OneGate token available), dynamic discovery is used.
3. If both are unavailable, boot fails.

**Implication for OneFlow templates:** In OneFlow deployments, do NOT set `FL_SUPERLINK_ADDRESS` -- leave it empty so OneGate discovery works automatically. Only set it for manual/standalone deployments or cross-site federation (Phase 7).

### 10d. FL_ISOLATION Mode Affects Container Count

**Variables involved:** `FL_ISOLATION` (both appliances)

- `subprocess` (default): One container per VM. The SuperExec/ClientApp runs as a subprocess within the Flower container. Simplest mode.
- `process`: Requires additional containers (SuperExec, app containers) and Docker networking between them. NOT recommended for Phase 1. May be useful for Phase 3 (ML framework variants) where different framework versions need different containers.

**Both sides must agree:** If the SuperLink uses `subprocess`, SuperNodes SHOULD also use `subprocess`. Mixing isolation modes is technically possible but untested and may cause unexpected behavior.

### 10e. FL_DATABASE Path Is Container-Internal

**Variables involved:** `FL_DATABASE` (SuperLink)

The default value `state/state.db` is relative to the Flower container's working directory (`/app/`). The resolved path inside the container is `/app/state/state.db`. This maps to `/opt/flower/state/state.db` on the host via the Docker volume mount.

**Do not set an absolute host path.** The variable value is passed directly to the `--database` CLI flag, which Flower interprets inside the container. A value like `/opt/flower/state/state.db` would attempt to create a database at that path inside the container, which is not the mounted volume.

### 10f. FL_NODE_CONFIG Partitioning Convention

**Variables involved:** `FL_NODE_CONFIG` (SuperNode)

The `--node-config` flag passes arbitrary key-value pairs to the ClientApp. The convention for data partitioning is:

```
FL_NODE_CONFIG = "partition-id=0 num-partitions=2"
```

In a OneFlow deployment with N SuperNodes, each SuperNode SHOULD receive a different `partition-id` (0 through N-1) and the same `num-partitions` (N). This allows the ClientApp to select its data shard.

**OneFlow template approach:** Use the OneFlow VM index `${VMID}` or a service-level counter to assign partition IDs. The exact mechanism is defined in Phase 4 (Single-Site Orchestration).

### 10g. FL_STRATEGY and Strategy-Specific Parameters

**Variables involved:** `FL_STRATEGY`, `FL_PROXIMAL_MU`, `FL_SERVER_LR`, `FL_CLIENT_LR`, `FL_NUM_MALICIOUS`, `FL_TRIM_BETA`

Strategy-specific parameters are only meaningful when the corresponding strategy is selected. The boot validation logs an INFO message when a strategy-specific parameter is set but the selected strategy does not use it.

**Interaction rules:**

- **When `FL_STRATEGY=FedAvg` (default):** `FL_PROXIMAL_MU`, `FL_SERVER_LR`, `FL_CLIENT_LR`, `FL_NUM_MALICIOUS`, and `FL_TRIM_BETA` are all ignored. configure.sh logs: "INFO: FL_PROXIMAL_MU ignored -- only applies to FedProx strategy" (and similarly for each set variable).

- **When `FL_STRATEGY=Krum`:** `FL_NUM_MALICIOUS` is validated against `FL_MIN_AVAILABLE_CLIENTS`. If `n < 2f+3`, boot logs a fatal error. Krum requires sufficient clients for its mathematical guarantee.

- **When `FL_STRATEGY=Bulyan`:** `FL_NUM_MALICIOUS` is validated against `FL_MIN_AVAILABLE_CLIENTS`. If `n < 4f+3`, boot logs a fatal error. Bulyan has stricter requirements than Krum.

- **When `FL_STRATEGY=FedProx` and `FL_PROXIMAL_MU=0.0`:** FedProx becomes mathematically identical to FedAvg. configure.sh logs a warning: "WARN: FL_PROXIMAL_MU=0.0 makes FedProx identical to FedAvg. Consider using FedAvg directly."

### 10h. FL_CHECKPOINT_ENABLED and Checkpoint Variables

**Variables involved:** `FL_CHECKPOINT_ENABLED`, `FL_CHECKPOINT_INTERVAL`, `FL_CHECKPOINT_PATH`

Checkpointing is disabled by default. When disabled, the checkpoint-related variables are ignored and no checkpoint volume mount is added to the Docker run command.

**Interaction rules:**

- **When `FL_CHECKPOINT_ENABLED=NO` (default):** `FL_CHECKPOINT_INTERVAL` and `FL_CHECKPOINT_PATH` are ignored. No `/opt/flower/checkpoints` directory is created. No `-v /opt/flower/checkpoints:/app/checkpoints:rw` mount is added to the Docker run command. Boot proceeds normally with no checkpoint infrastructure.

- **When `FL_CHECKPOINT_ENABLED=YES`:** configure.sh creates `/opt/flower/checkpoints` with `chown 49999:49999`, adds `-v /opt/flower/checkpoints:/app/checkpoints:rw` to the Docker run command, and passes `checkpoint-enabled=true`, `checkpoint-interval`, and `checkpoint-path` to the FAB via run_config.

### 10i. FL_GPU_ENABLED and GPU Configuration Variables

**Variables involved:** `FL_GPU_ENABLED`, `FL_CUDA_VISIBLE_DEVICES`, `FL_GPU_MEMORY_FRACTION`

GPU passthrough is disabled by default. When disabled, GPU-related variables are ignored and no `--gpus` flag is added to the Docker run command.

**Interaction rules:**

- **When `FL_GPU_ENABLED=NO` (default):** `FL_CUDA_VISIBLE_DEVICES` and `FL_GPU_MEMORY_FRACTION` are ignored. No GPU flags are added to Docker run. Container runs CPU-only regardless of GPU hardware availability.

- **When `FL_GPU_ENABLED=YES`:** configure.sh adds `--gpus all` and `-e CUDA_VISIBLE_DEVICES=${FL_CUDA_VISIBLE_DEVICES:-all}` to the Docker run command. If `nvidia-smi` fails (no GPU available), a WARNING is logged but boot continues -- the container starts and ClientApp falls back to CPU training.

- **FL_GPU_MEMORY_FRACTION interaction with ML_FRAMEWORK:** This variable only takes effect when `ML_FRAMEWORK=pytorch` and `FL_GPU_ENABLED=YES`. For TensorFlow, memory growth is enabled by default via `TF_FORCE_GPU_ALLOW_GROWTH=true` (no fraction needed). For scikit-learn, there is no GPU support, so the variable is always ignored.

- **FL_CUDA_VISIBLE_DEVICES with single-GPU VM:** In the default configuration (one GPU per VM), `FL_CUDA_VISIBLE_DEVICES=all` is correct and means "use the one GPU assigned to this VM." Set to a specific device ID (e.g., `0`) only when multiple GPUs are assigned via multiple PCI entries in the VM template.

**Cross-reference:** See `spec/10-gpu-passthrough.md` for complete GPU stack configuration, validation procedures, and decision records.

### 10j. FL_GRPC_KEEPALIVE_TIME and FL_GRPC_KEEPALIVE_TIMEOUT Coordination

**Variables involved:** `FL_GRPC_KEEPALIVE_TIME`, `FL_GRPC_KEEPALIVE_TIMEOUT` (both SuperLink and SuperNode)

Both keepalive variables must be set consistently on the SuperLink and SuperNode for correct operation. The gRPC client (SuperNode) sends keepalive pings at `FL_GRPC_KEEPALIVE_TIME` intervals. The gRPC server (SuperLink) must accept pings at this frequency.

**Coordination rules:**

- **Client keepalive_time >= server min_recv_ping_interval:** The server's minimum accepted ping interval is configured to 30 seconds (half of the default 60-second keepalive_time). If the client sends pings more frequently than the server permits, the server responds with a GOAWAY frame containing `ENHANCE_YOUR_CALM` and closes the connection.

- **Both sides should use the same `FL_GRPC_KEEPALIVE_TIME` value.** With 60 seconds on both, the server's 30-second min_recv_ping_interval provides a 2x safety margin.

- **`FL_GRPC_KEEPALIVE_TIMEOUT` < `FL_GRPC_KEEPALIVE_TIME`:** The timeout (default: 20s) must be shorter than the ping interval (default: 60s). If timeout >= ping interval, the connection may be declared dead before the next ping is sent.

- **Single-site deployments do not need keepalive tuning.** The default 60-second interval is only necessary for WAN paths through middleboxes. In single-site deployments, keepalive is unnecessary but harmless (small periodic ping overhead).

**Deployment order when changing values:** Update the server-side (SuperLink) first to accept the new ping frequency, then update clients (SuperNodes). Rolling out client changes first may trigger GOAWAY errors.

**Cross-reference:** See `spec/12-multi-site-federation.md`, Section 7 for the complete gRPC keepalive specification including recommended values, firewall timeout analysis, and translation to gRPC channel options.

### 10k. FL_CERT_EXTRA_SAN and TLS Certificate Generation

**Variables involved:** `FL_CERT_EXTRA_SAN` (SuperLink), `FL_TLS_ENABLED` (both), `FL_SSL_CERTFILE`/`FL_SSL_KEYFILE` (SuperLink)

`FL_CERT_EXTRA_SAN` is only effective when TLS is enabled AND the SuperLink auto-generates its certificates (the default path). If operator-provided certificates are used (`FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` are set), `FL_CERT_EXTRA_SAN` is ignored -- the operator controls the SAN in their own certificate.

**Interaction rules:**

- **When `FL_TLS_ENABLED=NO`:** `FL_CERT_EXTRA_SAN` is ignored. No certificates are generated.

- **When `FL_TLS_ENABLED=YES` and `FL_SSL_CERTFILE` is set:** `FL_CERT_EXTRA_SAN` is ignored. Operator-provided certs are used as-is. configure.sh logs: "INFO: FL_CERT_EXTRA_SAN ignored -- using operator-provided certificates."

- **When `FL_TLS_ENABLED=YES` and auto-generating certs:** `FL_CERT_EXTRA_SAN` entries are appended to the `[alt_names]` section of the certificate signing request. The auto-generated SAN includes the VM's primary IP plus any entries from `FL_CERT_EXTRA_SAN`.

**Use cases for FL_CERT_EXTRA_SAN:**
- WireGuard tunnel IP: `IP:10.10.9.0` (SuperNodes connect via tunnel)
- Public IP for direct access: `IP:203.0.113.50`
- DNS name: `DNS:flower.example.com`
- Multiple entries: `IP:10.10.9.0,DNS:flower.example.com`

**Cross-reference:** See `spec/12-multi-site-federation.md`, Sections 5 and 8 for complete multi-site TLS certificate trust distribution workflows.

### 10l. FL_METRICS_ENABLED and FL_METRICS_PORT

**Variables involved:** `FL_METRICS_ENABLED`, `FL_METRICS_PORT` (SuperLink)

`FL_METRICS_PORT` is only effective when `FL_METRICS_ENABLED=YES`. If `FL_METRICS_ENABLED=NO` (default), the port is unused and no metrics HTTP server is started.

**Interaction rules:**

- **When `FL_METRICS_ENABLED=NO` (default):** `FL_METRICS_PORT` is ignored. No Prometheus metrics endpoint is started. The ServerApp FAB does not need `prometheus_client` in its dependencies.

- **When `FL_METRICS_ENABLED=YES`:** The `prometheus_client` HTTP server starts on `FL_METRICS_PORT` (default 9101) during ServerApp initialization. The ServerApp FAB MUST include `prometheus_client` in its `pyproject.toml` dependencies. If the FAB does not include `prometheus_client`, the import fails and the ServerApp crashes.

- **Port conflict prevention:** `FL_METRICS_PORT` must not be 9091, 9092, or 9093 (Flower's SuperLink ports). The default 9101 is safe. Validation rejects Flower port values.

**Cross-reference:** See `spec/13-monitoring-observability.md` Section 5 for the complete metrics exporter specification.

### 10m. FL_DCGM_ENABLED and FL_GPU_ENABLED

**Variables involved:** `FL_DCGM_ENABLED` (SuperNode), `FL_GPU_ENABLED` (SuperNode)

`FL_DCGM_ENABLED=YES` requires `FL_GPU_ENABLED=YES` for the DCGM Exporter sidecar to start. If GPU is not detected at boot (Phase 6 Step 9), the DCGM sidecar is not started regardless of `FL_DCGM_ENABLED`.

**Interaction rules:**

- **When `FL_DCGM_ENABLED=NO` (default):** No DCGM Exporter sidecar is started. No dcgm-exporter.service systemd unit is created.

- **When `FL_DCGM_ENABLED=YES` and `FL_GPU_ENABLED=YES` and GPU detected:** DCGM Exporter image is pulled at boot time (`nvcr.io/nvidia/k8s/dcgm-exporter:4.5.1-4.8.0-distroless`), systemd unit created, sidecar started on port 9400.

- **When `FL_DCGM_ENABLED=YES` and `FL_GPU_ENABLED=NO`:** Warning logged: "FL_DCGM_ENABLED=YES but FL_GPU_ENABLED is not YES. DCGM will not start." Boot continues normally.

- **When `FL_DCGM_ENABLED=YES` and `FL_GPU_ENABLED=YES` but GPU not available:** Warning logged during GPU detection (Step 9). DCGM sidecar not started. Training falls back to CPU.

- **DCGM image pull failure:** If the DCGM Exporter image pull fails (no network, registry unavailable), a WARNING is logged and boot continues without DCGM. This is degraded monitoring, not fatal. Training proceeds normally.

**Cross-reference:** See `spec/13-monitoring-observability.md` Section 6 for the complete DCGM Exporter specification.

### 10n. FL_LOG_FORMAT and FL_LOG_LEVEL

**Variables involved:** `FL_LOG_FORMAT` (service-level), `FL_LOG_LEVEL` (both appliances)

Both variables apply simultaneously. The JSON format respects the same log level filtering. When `FL_LOG_FORMAT=json`, log entries below the `FL_LOG_LEVEL` threshold are still suppressed -- the formatter only changes output format, not filtering behavior.

**Interaction rules:**

- **When `FL_LOG_FORMAT=text` (default):** Flower's default log format is used. `FL_LOG_LEVEL` controls verbosity as normal.

- **When `FL_LOG_FORMAT=json`:** The FlowerJSONFormatter replaces the default text handler formatter on the `flwr` logger. All log entries are emitted as single-line JSON objects. `FL_LOG_LEVEL` still controls which entries are emitted.

- **Service-level scope:** `FL_LOG_FORMAT` is set at the OneFlow service level, ensuring consistent logging format across both SuperLink and SuperNode in a deployment.

**Cross-reference:** See `spec/13-monitoring-observability.md` Section 3 for the FlowerJSONFormatter specification and FL event taxonomy.

---

## Appendix: Complete Variable Cross-Reference Matrix

This matrix shows every variable and which appliance uses it.

| Variable | SuperLink | SuperNode | Infrastructure | Phase |
|----------|-----------|-----------|----------------|-------|
| `FLOWER_VERSION` | Y | Y | -- | 1 |
| `FL_NUM_ROUNDS` | Y | -- | -- | 1 |
| `FL_STRATEGY` | Y | -- | -- | 1 (extended Phase 5) |
| `FL_MIN_FIT_CLIENTS` | Y | -- | -- | 1 |
| `FL_MIN_EVALUATE_CLIENTS` | Y | -- | -- | 1 |
| `FL_MIN_AVAILABLE_CLIENTS` | Y | -- | -- | 1 |
| `FL_FLEET_API_ADDRESS` | Y | -- | -- | 1 |
| `FL_CONTROL_API_ADDRESS` | Y | -- | -- | 1 |
| `FL_ISOLATION` | Y | Y | -- | 1 |
| `FL_DATABASE` | Y | -- | -- | 1 |
| `FL_LOG_LEVEL` | Y | Y | -- | 1 |
| `FL_SUPERLINK_ADDRESS` | -- | Y | -- | 1 |
| `FL_NODE_CONFIG` | -- | Y | -- | 1 |
| `FL_MAX_RETRIES` | -- | Y | -- | 1 |
| `FL_MAX_WAIT_TIME` | -- | Y | -- | 1 |
| `TOKEN` | -- | -- | Y | 1 |
| `NETWORK` | -- | -- | Y | 1 |
| `REPORT_READY` | -- | -- | Y | 1 |
| `READY_SCRIPT_PATH` | -- | -- | Y | 1 |
| `SSH_PUBLIC_KEY` | -- | -- | Y | 1 |
| `FL_PROXIMAL_MU` | Y | -- | -- | 5 |
| `FL_SERVER_LR` | Y | -- | -- | 5 |
| `FL_CLIENT_LR` | Y | -- | -- | 5 |
| `FL_NUM_MALICIOUS` | Y | -- | -- | 5 |
| `FL_TRIM_BETA` | Y | -- | -- | 5 |
| `FL_CHECKPOINT_ENABLED` | Y | -- | -- | 5 |
| `FL_CHECKPOINT_INTERVAL` | Y | -- | -- | 5 |
| `FL_CHECKPOINT_PATH` | Y | -- | -- | 5 |
| `FL_TLS_ENABLED` | Y | Y | -- | 2 |
| `FL_SSL_CA_CERTFILE` | Y | Y | -- | 2 |
| `FL_SSL_CERTFILE` | Y | -- | -- | 2 |
| `FL_SSL_KEYFILE` | Y | -- | -- | 2 |
| `FL_GPU_ENABLED` | -- | Y | -- | 6 |
| `FL_CUDA_VISIBLE_DEVICES` | -- | Y | -- | 6 |
| `FL_GPU_MEMORY_FRACTION` | -- | Y | -- | 6 |
| `ML_FRAMEWORK` | -- | Y | -- | 3 |
| `FL_GRPC_KEEPALIVE_TIME` | Y | Y | -- | 7 |
| `FL_GRPC_KEEPALIVE_TIMEOUT` | Y | Y | -- | 7 |
| `FL_CERT_EXTRA_SAN` | Y | -- | -- | 7 |
| `FL_LOG_FORMAT` | Y | Y | Y (OneFlow) | 8 |
| `FL_METRICS_ENABLED` | Y | -- | -- | 8 |
| `FL_METRICS_PORT` | Y | -- | -- | 8 |
| `FL_DCGM_ENABLED` | -- | Y | -- | 8 |

**Legend:** Y = used by this appliance, -- = not applicable

---

*Specification for APPL-03: Contextualization Variable Reference*
*Phase: 01 - Base Appliance Architecture (updated Phase 8)*
*Version: 1.4*
