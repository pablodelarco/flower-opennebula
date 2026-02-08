# Contextualization Variable Reference

**Requirement:** APPL-03
**Phase:** 01 - Base Appliance Architecture
**Status:** Specification

---

## 1. Purpose and Scope

This document is the single authoritative reference for every OpenNebula contextualization variable used by the Flower SuperLink and SuperNode marketplace appliances. It serves as an implementation checklist: an engineer building either appliance can print this document and check off each variable as it is implemented in the contextualization scripts.

**Scope:** All variables defined in Phase 1 (base appliance architecture), Phase 5 (training configuration), plus placeholder variables for Phase 2 (TLS), Phase 3 (ML frameworks), and Phase 6 (GPU). Placeholder variables are documented here for completeness but are not functional in Phase 1. Phase 5 variables are functional and documented in Section 3.

**Source of truth hierarchy:**
1. This document is the authoritative reference for variable names, types, defaults, and validation rules.
2. `spec/01-superlink-appliance.md` and `spec/02-supernode-appliance.md` define the appliance behavior that each variable controls.
3. If there is a conflict between this document and an appliance spec, this document takes precedence for variable definitions.

**Variable count summary:**

| Category | Count | Appliance |
|----------|-------|-----------|
| SuperLink parameters | 19 | SuperLink only |
| SuperNode parameters | 8 | SuperNode only |
| Shared infrastructure | 5 | Both |
| Phase 5 strategy/checkpointing | 8 | SuperLink |
| Phase 2+ placeholders | 6 | Both (not functional in Phase 1) |
| **Total** | **38** | |

*Note:* The Phase 5 count (8) is included in the SuperLink parameters count (19 = 11 original + 8 Phase 5). The separate Phase 5 row is for traceability. SuperNode count includes FL_USE_CASE added in Phase 3.

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

These 19 variables configure the Flower SuperLink appliance. All are optional. Zero-config deployment works with all defaults (see Section 9). Variables #1-11 are Phase 1 (base architecture). Variables #12-19 are Phase 5 (training configuration: strategy parameters and checkpointing).

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
  FL_CHECKPOINT_PATH = "O|text|Checkpoint directory (container path)||/app/checkpoints"
]
```

---

## 4. SuperNode Parameters

These 7 variables configure the Flower SuperNode appliance. All are optional. Zero-config deployment discovers the SuperLink via OneGate and connects with default settings (see Section 9).

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

### SuperNode USER_INPUT Block (Copy-Paste Ready)

```
USER_INPUTS = [
  FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0",
  FL_SUPERLINK_ADDRESS = "O|text|SuperLink Fleet API address (host:port)||",
  FL_NODE_CONFIG = "O|text|Space-separated key=value node config||",
  FL_MAX_RETRIES = "O|number|Max reconnection attempts (0=unlimited)||0",
  FL_MAX_WAIT_TIME = "O|number|Max wait time for connection in seconds (0=unlimited)||0",
  FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess",
  FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
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

## 6. Phase 2+ Placeholder Parameters

These 6 variables are documented for forward compatibility. They appear in the USER_INPUTS definitions but have no effect in Phase 1. The contextualization scripts SHALL recognize these variables but skip their processing with a log message: "Variable X is a Phase N feature; ignoring in current appliance version."

**Status:** Placeholder -- not functional in Phase 1.

| # | Context Variable | USER_INPUT Definition | Phase | Default | Appliance | Purpose |
|---|------------------|----------------------|-------|---------|-----------|---------|
| 1 | `FL_TLS_ENABLED` | `O\|boolean\|Enable TLS encryption\|\|NO` | Phase 2 | `NO` | Both | Master switch for TLS. When `YES`, the appliance uses certificates instead of `--insecure`. |
| 2 | `FL_SSL_CA_CERTFILE` | `O\|text64\|CA certificate (base64 PEM)` | Phase 2 | (empty) | Both | Base64-encoded CA certificate for TLS trust chain. SuperLink uses for server cert verification; SuperNode uses for `--root-certificates`. |
| 3 | `FL_SSL_CERTFILE` | `O\|text64\|Server certificate (base64 PEM)` | Phase 2 | (empty) | SuperLink | Base64-encoded server certificate. Used with `--ssl-certfile`. |
| 4 | `FL_SSL_KEYFILE` | `O\|text64\|Server private key (base64 PEM)` | Phase 2 | (empty) | SuperLink | Base64-encoded server private key. Used with `--ssl-keyfile`. |
| 5 | `FL_GPU_ENABLED` | `O\|boolean\|Enable NVIDIA GPU support\|\|NO` | Phase 6 | `NO` | SuperNode | Adds `--gpus all` and NVIDIA Container Toolkit configuration to the Docker run command. |
| 6 | `ML_FRAMEWORK` | `O\|list\|ML framework\|pytorch,tensorflow,sklearn\|pytorch` | Phase 3 | `pytorch` | SuperNode | Selects the ML framework variant image. Affects which `flwr/supernode` image tag is used. |

### Placeholder USER_INPUT Block (For Reference)

```
# Phase 2: TLS (not functional in Phase 1)
FL_TLS_ENABLED = "O|boolean|Enable TLS encryption||NO"
FL_SSL_CA_CERTFILE = "O|text64|CA certificate (base64 PEM)"
FL_SSL_CERTFILE = "O|text64|Server certificate (base64 PEM)"
FL_SSL_KEYFILE = "O|text64|Server private key (base64 PEM)"

# Phase 6: GPU (not functional in Phase 1)
FL_GPU_ENABLED = "O|boolean|Enable NVIDIA GPU support||NO"

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
| `ML_FRAMEWORK` | -- | Y | -- | 3 |

**Legend:** Y = used by this appliance, -- = not applicable

---

*Specification for APPL-03: Contextualization Variable Reference*
*Phase: 01 - Base Appliance Architecture (updated Phase 5)*
*Version: 1.1*
