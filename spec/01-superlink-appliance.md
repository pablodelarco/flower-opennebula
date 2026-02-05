# SuperLink Appliance Specification

**Requirement:** APPL-01
**Phase:** 01 - Base Appliance Architecture
**Status:** Specification

---

## 1. Appliance Overview

The SuperLink appliance is the Flower federated learning coordinator packaged as an OpenNebula marketplace appliance. It runs the `flower-superlink` process inside a Docker container within a dedicated VM. The SuperLink orchestrates training rounds, aggregates model updates from SuperNode clients, and publishes its readiness state via OneGate for service discovery.

| Property              | Value                                                  |
|-----------------------|--------------------------------------------------------|
| Role                  | Flower SuperLink (FL coordinator / aggregation server) |
| Marketplace type      | QCOW2 VM image                                        |
| Architecture          | Docker-in-VM (single container per VM)                 |
| Isolation mode        | Subprocess (embedded SuperExec)                        |
| Default Flower version| 1.25.0                                                 |
| Supported platforms   | amd64, arm64                                           |

**Docker-in-VM rationale:** A single Docker container runs inside a dedicated VM. This provides version isolation (swap Flower versions via image tags), environment consistency (same runtime as upstream Flower CI), and operational simplicity (one container, one process tree, managed by systemd). The VM boundary provides tenant isolation; the Docker layer provides application packaging.

---

## 2. Image Components

The QCOW2 appliance image ships with all components pre-installed. No internet access is required at boot time for default operation.

| Component                          | Version / Constraint       | Purpose                                    |
|------------------------------------|----------------------------|--------------------------------------------|
| Ubuntu 24.04 LTS (Noble Numbat)   | 24.04                      | VM base OS                                 |
| Docker CE                          | 24+ (minimum, not pinned)  | Container runtime                          |
| Pre-pulled Docker image            | `flwr/superlink:1.25.0`   | Flower SuperLink container (default tag: `1.25.0-py3.13-ubuntu24.04`) |
| OpenNebula one-apps contextualization | latest at build time    | VM guest integration (networking, SSH, START_SCRIPT, REPORT_READY) |
| jq                                 | any                        | JSON parsing for OneGate API responses     |
| curl                               | any                        | HTTP client for OneGate API calls          |
| netcat (nmap variant)              | any                        | TCP port checking for health probes        |
| Custom scripts                     | (appliance-specific)       | `/opt/flower/scripts/` -- configure, bootstrap, health check |

**Base OS choice:** Ubuntu 24.04 LTS matches the base OS inside the official Flower Docker images (`flwr/superlink:1.25.0-py3.13-ubuntu24.04`). This eliminates library mismatch risks and provides LTS support through 2029. openSUSE was considered for EU-sovereignty alignment but has untested compatibility with Flower Docker images.

**Docker CE minimum version:** Docker CE 24+ is required. Do not pin a specific patch version. The image build process installs the latest Docker CE from the official Docker APT repository. The minimum constraint ensures BuildKit support, compose v2 plugin availability, and current container runtime features.

---

## 3. File Layout Inside the VM

```
/etc/one-appliance/
    service                           # Main lifecycle dispatcher (from one-apps)

/opt/flower/
    scripts/
        configure.sh                  # Stage 1: Read context vars, validate, write config
        bootstrap.sh                  # Stage 2: Start Docker, run Flower container
        health-check.sh               # Readiness probe (TCP check on port 9092)
        common.sh                     # Shared functions: logging, OneGate helpers
    config/
        superlink.env                 # Generated at boot: Docker env vars for SuperLink
    state/                            # Persistent state directory (mounted into container)
    certs/                            # TLS certificates (Phase 2, empty in Phase 1)

/var/log/one-appliance/
    flower-configure.log              # Configure stage stdout/stderr
    flower-bootstrap.log              # Bootstrap stage stdout/stderr

/etc/systemd/system/
    flower-superlink.service          # Generated at boot: systemd unit for container

/run/one-context/
    one_env                           # OpenNebula context variables (written by contextualization)
    token.txt                         # OneGate authentication token
```

**Ownership requirements:**

| Path                   | Owner     | Permissions | Reason                                          |
|------------------------|-----------|-------------|--------------------------------------------------|
| `/opt/flower/state/`   | 49999:49999 | 0755      | Flower container runs as UID 49999 (`app` user)  |
| `/opt/flower/certs/`   | 49999:49999 | 0700      | Certificate files must be readable by container   |
| `/opt/flower/config/`  | root:root   | 0750      | Boot scripts write config; container reads env    |
| `/opt/flower/scripts/` | root:root   | 0755      | Executable by root during contextualization       |

---

## 4. Pre-baked Image Strategy

The appliance uses a **pre-baked fat image** strategy: the Flower Docker image is pulled during QCOW2 build time and stored in the local Docker image cache. At boot, the container starts from the local cache with zero network dependency.

**Build-time behavior:**
1. Install Docker CE.
2. Enable and start Docker daemon.
3. Run `docker pull flwr/superlink:1.25.0`.
4. Record the pre-baked version in `/opt/flower/PREBAKED_VERSION` (plain text file containing `1.25.0`).
5. Stop Docker daemon. The pulled image layers persist in `/var/lib/docker/`.

**Boot-time version override mechanism:**

```bash
REQUESTED_VERSION="${FLOWER_VERSION:-1.25.0}"
PREBAKED_VERSION=$(cat /opt/flower/PREBAKED_VERSION)

if [ "$REQUESTED_VERSION" != "$PREBAKED_VERSION" ]; then
    log "INFO" "Requested version $REQUESTED_VERSION differs from pre-baked $PREBAKED_VERSION"
    log "INFO" "Pulling flwr/superlink:${REQUESTED_VERSION}..."
    if docker pull "flwr/superlink:${REQUESTED_VERSION}"; then
        log "INFO" "Successfully pulled version $REQUESTED_VERSION"
    else
        log "WARN" "Failed to pull version $REQUESTED_VERSION -- falling back to pre-baked $PREBAKED_VERSION"
        REQUESTED_VERSION="$PREBAKED_VERSION"
    fi
fi
```

**Fallback behavior:** If the user requests a non-default version and the pull fails (no network, tag does not exist), the appliance falls back to the pre-baked version and logs a warning. The appliance always starts -- it never fails due to a pull error when a valid pre-baked image exists.

**Image size budget:**

| Component                     | Approximate Size |
|-------------------------------|-----------------|
| Ubuntu 24.04 base             | ~800 MB         |
| Docker CE + dependencies      | ~400 MB         |
| flwr/superlink image layers   | ~190 MB         |
| Contextualization + tools     | ~50 MB          |
| **Total QCOW2 (compressed)**  | **~2 GB**       |

Soft target: keep the compressed QCOW2 under 3 GB. Measure during image build and optimize if exceeded.

---

## 5. Recommended VM Resources

| Resource | Minimum | Default | Notes |
|----------|---------|---------|-------|
| vCPU     | 2       | 4       | Aggregation is CPU-bound for large models |
| RAM      | 4096 MB | 8192 MB | Must hold all client model updates in memory during aggregation |
| Disk     | 10 GB   | 20 GB   | QCOW2 base + Docker layers + state database |
| Network  | 1 NIC   | 1 NIC   | Must reach SuperNodes on port 9092 and OneGate on 169.254.16.9:5030 |

**Sizing guidance:** The default resources support aggregation of models up to ~500 MB from 10 concurrent clients. For larger models or more clients, increase RAM proportionally. The SuperLink does not perform training -- it only receives, aggregates, and distributes model weights.

---

## 6. Linear Boot Sequence

The SuperLink boot follows a strict linear sequence. Each step validates its preconditions before proceeding. Failure at any step aborts the sequence and reports the error via OneGate (if available) and system logs.

### Step 1: OS Boot and Contextualization Agent Initialization

- **WHAT:** Ubuntu 24.04 boots, systemd starts services, the OpenNebula contextualization packages execute. Networking is configured, SSH keys are injected, and context variables are written to `/run/one-context/one_env`.
- **WHY:** The contextualization agent provides all runtime configuration. Without it, the appliance has no parameters to read.
- **FAILURE:** If contextualization fails, the VM boots into a bare OS with no Flower configuration. SSH access may still work if keys were injected. The VM will not report READY. Check `/var/log/one-context.log`.

### Step 2: Execute START_SCRIPT (Dispatches to configure.sh)

- **WHAT:** The contextualization `START_SCRIPT` triggers `/opt/flower/scripts/configure.sh`. This is the entry point for all Flower-specific initialization.
- **WHY:** OpenNebula's one-apps lifecycle uses START_SCRIPT as the hook for application-specific setup. Keeping Flower logic in separate scripts (not inline in START_SCRIPT) enables testing and maintenance.
- **FAILURE:** If configure.sh is missing or not executable, contextualization logs an error. The VM reports as RUNNING (OS-level) but never reports READY (application-level).

### Step 3: Source Context Variables

- **WHAT:** `configure.sh` sources `/run/one-context/one_env` to load all `FL_*` and `FLOWER_*` context variables into the shell environment. Variables not set by the user receive their defaults.
- **WHY:** All Flower configuration originates from OpenNebula context variables. Sourcing the env file is the standard one-apps pattern.
- **FAILURE:** If `/run/one-context/one_env` does not exist, the contextualization agent did not run. Abort with a fatal error.

### Step 4: Validate Configuration

- **WHAT:** `configure.sh` validates all context variables: checks that numeric values are integers, enum values are in allowed sets, and addresses match expected formats. Uses a fail-fast approach -- any validation error aborts boot.
- **WHY:** Catching configuration errors early produces clear error messages. A misconfigured SuperLink that partially starts is harder to debug than one that fails immediately with a specific validation error.
- **FAILURE:** Validation errors are logged to `/var/log/one-appliance/flower-configure.log` with the variable name, expected format, and actual value. The boot sequence aborts. The VM does not report READY.

### Step 5: Set Defaults for Optional Variables

- **WHAT:** Any optional variable not provided by the user is set to its default value: `FL_NUM_ROUNDS=3`, `FL_STRATEGY=FedAvg`, `FL_ISOLATION=subprocess`, `FL_LOG_LEVEL=INFO`, `FL_FLEET_API_ADDRESS=0.0.0.0:9092`, `FL_DATABASE=state/state.db`.
- **WHY:** Zero-config deployment must work. A user deploying the SuperLink appliance with no custom parameters should get a functional FL coordinator.
- **FAILURE:** No failure mode -- defaults are hardcoded in the script.

### Step 6: Generate Docker Environment File

- **WHAT:** `configure.sh` writes `/opt/flower/config/superlink.env` with the resolved configuration. This file maps context variables to Docker environment variables (e.g., `FLWR_LOG_LEVEL=${FL_LOG_LEVEL}`).
- **WHY:** Separating config generation from container startup enables inspection and debugging. An operator can `cat /opt/flower/config/superlink.env` to verify the resolved configuration before the container starts.
- **FAILURE:** Write failure (disk full, permissions) aborts boot. Check disk space and `/opt/flower/config/` permissions.

### Step 7: Create Mount Directories with Correct Ownership

- **WHAT:** `configure.sh` creates `/opt/flower/state/` and `/opt/flower/certs/` (if they don't exist) and sets ownership to `49999:49999`.
- **WHY:** Flower Docker images run as non-root user `app` (UID 49999). Docker bind mounts create directories as root by default. Without `chown`, the container gets "Permission denied" errors on state directory writes.
- **FAILURE:** If `chown` fails, the container will fail to write state. Check that the filesystem supports ownership changes.

### Step 8: Generate Systemd Unit File

- **WHAT:** `configure.sh` writes `/etc/systemd/system/flower-superlink.service` with the complete `docker run` command, environment file reference, restart policy, and dependency ordering (`After=docker.service`). Then runs `systemctl daemon-reload`.
- **WHY:** Systemd integration provides automatic restart on failure, clean shutdown handling, and standard log access via `journalctl -u flower-superlink`. It also ensures the container starts after Docker and stops before Docker during shutdown.
- **FAILURE:** If systemd unit creation fails, the container cannot be managed. Fall through to bootstrap.sh which will detect the missing unit.

### Step 9: Wait for Docker Daemon

- **WHAT:** `bootstrap.sh` waits for the Docker daemon to be ready by polling `docker info` in a loop (1-second interval, 60-second timeout).
- **WHY:** On first boot, Docker CE may take 5-10 seconds to initialize after system startup. The contextualization script may execute before Docker is fully ready.
- **FAILURE:** If Docker does not start within 60 seconds, abort with "Docker daemon not available." Check `systemctl status docker` and `journalctl -u docker`.

### Step 10: Handle Version Override and Start Container

- **WHAT:** `bootstrap.sh` checks if `FLOWER_VERSION` differs from the pre-baked version. If so, attempts a `docker pull` with fallback (see Section 4). Then starts the container via `systemctl start flower-superlink`.
- **WHY:** The pre-baked image strategy ensures the container always starts. The version override provides flexibility for users who need a specific Flower release.
- **FAILURE:** If `systemctl start` fails, check `docker logs flower-superlink` and `journalctl -u flower-superlink`. Common causes: port already in use, image not found (should not happen with fallback), permission errors on mount points.

### Step 11: Health Check Loop (Wait for SuperLink to Listen)

- **WHAT:** `bootstrap.sh` polls TCP port 9092 using `nc -z localhost 9092` in a loop (2-second interval, 120-second timeout). The loop waits for the SuperLink gRPC Fleet API to accept connections.
- **WHY:** The container may take 5-30 seconds to initialize (database creation, gRPC server startup). Publishing readiness before the SuperLink is actually listening causes SuperNodes to get "Connection refused" errors.
- **FAILURE:** If the health check times out after 120 seconds, the SuperLink failed to start. Publish `FL_READY=NO` and `FL_ERROR=health_check_timeout` to OneGate. Check `docker logs flower-superlink` for startup errors.

### Step 12: Publish Readiness to OneGate

- **WHAT:** `bootstrap.sh` publishes the SuperLink endpoint and readiness status to OneGate via HTTP PUT. Then the contextualization REPORT_READY mechanism reports the VM as ready.
- **WHY:** OneGate publication enables SuperNode dynamic discovery. REPORT_READY enables OneFlow to know when the SuperLink role is fully operational (not just VM-booted). Both are required for automated orchestration.
- **FAILURE:** If OneGate is unreachable (network issue, `TOKEN=YES` not set), the publication fails silently. The SuperLink still functions -- only dynamic discovery is affected. Log a warning: "OneGate publication failed; SuperNodes must use static FL_SUPERLINK_ADDRESS."

### Boot Sequence Summary

```
OS Boot ──> Contextualization ──> configure.sh ──> bootstrap.sh ──> READY
  [1]           [2]              [3,4,5,6,7,8]     [9,10,11,12]
```

**Nominal boot time:** 30-90 seconds from VM power-on to FL_READY=YES, depending on hardware and whether a version override triggers a Docker pull.

---

## 7. Docker Container Configuration

### Exact Docker Run Command (Phase 1 Default -- Insecure Mode)

```bash
docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --isolation subprocess \
  --fleet-api-address 0.0.0.0:9092 \
  --database state/state.db
```

### Port Mappings

| Host Port | Container Port | Protocol | API Name       | Purpose                                          |
|-----------|---------------|----------|----------------|--------------------------------------------------|
| 9091      | 9091          | gRPC     | ServerAppIo    | Internal API for subprocess-managed ServerApp     |
| 9092      | 9092          | gRPC     | Fleet API      | SuperNode connections (primary data plane)        |
| 9093      | 9093          | gRPC     | Control API    | CLI management, run submission                   |

**Port 9092 is the critical port.** SuperNodes connect to this port for all training communication. It must be reachable from all SuperNode VMs. Ports 9091 and 9093 are for management and internal use.

### Volume Mounts

| Host Path              | Container Path  | Mode | Purpose                             |
|------------------------|-----------------|------|-------------------------------------|
| `/opt/flower/state`   | `/app/state`    | rw   | SQLite state database, run history  |
| `/opt/flower/certs`   | `/app/certificates` | ro | TLS certificates (Phase 2)      |

**Phase 1 only mounts the state volume.** The certs volume is added in Phase 2 when TLS is enabled.

### Environment File Contents (`superlink.env`)

Generated by `configure.sh` at boot time:

```bash
FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO}
```

Additional environment variables may be added in future phases (TLS paths, metrics configuration).

### CLI Flags Explained

| Flag                       | Value                 | Purpose                                           |
|----------------------------|-----------------------|---------------------------------------------------|
| `--insecure`               | (flag)                | Disable TLS (Phase 1 default; removed in Phase 2) |
| `--isolation subprocess`   | `subprocess`          | SuperExec runs as subprocess within SuperLink; simplest mode, one container per VM |
| `--fleet-api-address`      | `0.0.0.0:9092`        | Listen on all interfaces for SuperNode connections |
| `--database`               | `state/state.db`      | Persist FL run state to SQLite; survives container restart |

### Restart Policy

`--restart unless-stopped` ensures:
- Container restarts automatically on crash.
- Container restarts on Docker daemon restart (reboot).
- Container does NOT restart if explicitly stopped by operator (`docker stop`).

---

## 8. Systemd Integration

The Flower SuperLink container is managed by a systemd unit for lifecycle control, dependency ordering, and log access.

### Unit File Template

Generated by `configure.sh` and written to `/etc/systemd/system/flower-superlink.service`:

```ini
[Unit]
Description=Flower SuperLink (Federated Learning Coordinator)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

ExecStartPre=-/usr/bin/docker rm -f flower-superlink
ExecStart=/usr/bin/docker run \
  --name flower-superlink \
  --rm \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  flwr/superlink:${FLOWER_VERSION} \
  --insecure \
  --isolation subprocess \
  --fleet-api-address ${FL_FLEET_API_ADDRESS} \
  --database ${FL_DATABASE}
ExecStop=/usr/bin/docker stop flower-superlink

[Install]
WantedBy=multi-user.target
```

**Design notes:**

- `Type=simple`: Docker runs in the foreground (no `-d` flag) so systemd tracks the process directly.
- `ExecStartPre=-docker rm -f`: Removes any stale container from a previous failed start. The `-` prefix means failure is not fatal (container may not exist).
- `--rm` on the container: Container is removed on stop, ensuring a clean state for the next start.
- `Restart=on-failure` with `RestartSec=10`: Automatic restart with a 10-second backoff to avoid tight crash loops.
- `TimeoutStartSec=120`: Matches the health check timeout. If the container does not start within 120 seconds, systemd marks it as failed.

**Note:** When managed by systemd, the `docker run` command does NOT use `-d` (detach). Systemd requires the foreground process. The `--restart` Docker policy is also omitted since systemd handles restarts.

### Operational Commands

```bash
# View container status
systemctl status flower-superlink

# View container logs (stdout/stderr from Flower)
journalctl -u flower-superlink -f

# Restart the container
systemctl restart flower-superlink

# Stop the container
systemctl stop flower-superlink
```

---

## 9. Health Check and Readiness

The health check determines when the SuperLink is fully operational and ready to accept SuperNode connections.

### Health Check Script

`/opt/flower/scripts/health-check.sh`:

```bash
#!/bin/bash
# Returns exit code 0 if SuperLink Fleet API is accepting TCP connections.
# Used by bootstrap.sh during startup and by READY_SCRIPT for OneGate reporting.
nc -z localhost 9092 2>/dev/null
```

**Why TCP check, not gRPC health probe:**
- The TCP check (`nc -z`) validates that the gRPC server is listening, which is sufficient for readiness.
- A full gRPC health probe would require installing `grpc-health-probe` in the VM and enabling `--health-server-address` on the SuperLink. This adds complexity for marginal benefit in Phase 1.
- The TCP check has zero additional dependencies (netcat is pre-installed).

### Health Check Loop in bootstrap.sh

```bash
HEALTH_TIMEOUT=120    # seconds
HEALTH_INTERVAL=2     # seconds
ELAPSED=0

log "INFO" "Waiting for SuperLink Fleet API on port 9092..."
while ! /opt/flower/scripts/health-check.sh; do
    ELAPSED=$((ELAPSED + HEALTH_INTERVAL))
    if [ "$ELAPSED" -ge "$HEALTH_TIMEOUT" ]; then
        log "ERROR" "SuperLink health check timed out after ${HEALTH_TIMEOUT}s"
        publish_onegate "FL_READY=NO" "FL_ERROR=health_check_timeout"
        exit 1
    fi
    sleep "$HEALTH_INTERVAL"
done
log "INFO" "SuperLink Fleet API is listening on port 9092"
```

### READY_SCRIPT Integration

The appliance sets `REPORT_READY=YES` and uses the health check as the gate:

```
CONTEXT = [
  ...
  REPORT_READY = "YES",
  READY_SCRIPT_PATH = "/opt/flower/scripts/health-check.sh"
]
```

When `health-check.sh` returns exit code 0, the contextualization agent reports the VM as READY to OneGate. This signals to OneFlow that the SuperLink role is fully operational.

**Note:** The interaction between `REPORT_READY` and OneFlow role dependency ordering is documented as an open question (see Research). The SuperNode retry loop provides defense-in-depth regardless of how OneFlow interprets REPORT_READY.

---

## 10. OneGate Publication Contract

After the health check passes, the SuperLink publishes its state to OneGate. This publication is the source of truth for dynamic SuperNode discovery.

### Published Attributes

| Attribute       | Value                    | Type   | Purpose                                      |
|-----------------|--------------------------|--------|----------------------------------------------|
| `FL_READY`      | `YES` or `NO`           | string | Readiness state. `YES` means SuperLink is accepting connections. |
| `FL_ENDPOINT`   | `{vm_ip}:9092`          | string | Fleet API address for SuperNode connections.  |
| `FL_VERSION`    | `1.25.0` (or overridden)| string | Running Flower version for compatibility checks. |
| `FL_ROLE`       | `superlink`             | string | Appliance role identifier.                    |
| `FL_ERROR`      | (error code or empty)   | string | Error code if `FL_READY=NO`. Values: `health_check_timeout`, `docker_start_failed`, `config_validation_failed`. |

### Publication Command

```bash
MY_IP=$(hostname -I | awk '{print $1}')
ONEGATE_TOKEN=$(cat /run/one-context/token.txt)
VMID=$(grep -oP 'VMID=\K[0-9]+' /run/one-context/one_env)

curl -s -X PUT "${ONEGATE_ENDPOINT}/vm" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_READY=YES" \
  -d "FL_ENDPOINT=${MY_IP}:9092" \
  -d "FL_VERSION=${FLOWER_VERSION}" \
  -d "FL_ROLE=superlink"
```

### Publication Timing

1. **On successful health check:** Publish `FL_READY=YES` with `FL_ENDPOINT`.
2. **On health check timeout:** Publish `FL_READY=NO` with `FL_ERROR=health_check_timeout`.
3. **On configuration validation failure:** Publish `FL_READY=NO` with `FL_ERROR=config_validation_failed` (if OneGate is reachable at that point in the boot sequence).

### OneGate Failure Handling

If the OneGate PUT fails (network unreachable, token not available, `TOKEN=YES` not in CONTEXT):
- Log a warning: "OneGate publication failed. SuperNodes must use static FL_SUPERLINK_ADDRESS."
- Do NOT abort the boot sequence. The SuperLink is still functional for SuperNodes that use static addressing.
- OneGate publication is best-effort, not a hard dependency.

---

## 11. Failure Modes and Error Handling

### Failure Classification

| Failure                        | Severity | Boot Continues? | OneGate Publication          | Recovery Action                          |
|--------------------------------|----------|-----------------|------------------------------|------------------------------------------|
| Contextualization not run      | Fatal    | No              | Not possible                 | Check VM template CONTEXT section        |
| Config validation error        | Fatal    | No              | `FL_READY=NO` if reachable   | Fix context variables, redeploy          |
| Docker daemon not starting     | Fatal    | No              | `FL_READY=NO` if reachable   | Check `systemctl status docker`          |
| Docker image pull failure      | Degraded | Yes (fallback)  | n/a (continues with pre-baked)| Logs warning, uses pre-baked version     |
| Container start failure        | Fatal    | No              | `FL_READY=NO`                | Check `docker logs flower-superlink`     |
| Health check timeout           | Fatal    | No              | `FL_READY=NO`                | Check `docker logs flower-superlink`     |
| OneGate publication failure    | Degraded | Yes             | n/a (OneGate unreachable)    | Log warning, static discovery still works|
| Container crash after startup  | Transient| n/a (runtime)   | FL_READY stays YES           | Systemd restarts container automatically |
| Disk full (state dir)          | Runtime  | n/a (runtime)   | n/a                          | Expand disk, clear old state             |

### Error Reporting Strategy

**Principle:** Every failure produces exactly one clear error message with three parts: what failed, why it likely failed, and what to check.

**Log format:**
```
[YYYY-MM-DD HH:MM:SS] [LEVEL] [flower-configure|flower-bootstrap] MESSAGE
```

**Log destinations:**
- Boot-time errors: `/var/log/one-appliance/flower-configure.log` and `flower-bootstrap.log`
- Container runtime errors: `docker logs flower-superlink` or `journalctl -u flower-superlink`
- Contextualization errors: `/var/log/one-context.log`

### Container Crash Recovery

When the Flower container crashes during operation:

1. Systemd detects the process exit (non-zero code).
2. Systemd waits `RestartSec=10` seconds.
3. Systemd removes the old container (`ExecStartPre`), creates a new one.
4. The new container reads the same state database (`/opt/flower/state/state.db`), resuming from the last committed round.
5. Connected SuperNodes detect the disconnection and reconnect via Flower's built-in retry mechanism (`--max-retries`).

**No manual intervention required** for transient crashes. If the crash repeats (persistent bug or resource exhaustion), systemd's restart rate limiting (`StartLimitBurst=5`, `StartLimitIntervalSec=60`) will stop the restart loop and mark the service as failed.

---

## 12. SuperLink Contextualization Parameters

### Parameter Table

All parameters are optional. Zero-config deployment works with all defaults.

| Context Variable          | Type     | Default            | Validation                         | Flower Mapping                    | Description |
|---------------------------|----------|--------------------|------------------------------------|-----------------------------------|-------------|
| `FLOWER_VERSION`          | text     | `1.25.0`           | Non-empty string                   | Docker image tag                  | Flower Docker image version. Triggers pull if different from pre-baked. |
| `FL_NUM_ROUNDS`           | number   | `3`                | Positive integer                   | ServerApp `num_server_rounds`     | Number of federated learning rounds to execute. |
| `FL_STRATEGY`             | list     | `FedAvg`           | One of: FedAvg, FedProx, FedAdam   | ServerApp `strategy`              | Aggregation strategy for combining client updates. |
| `FL_MIN_FIT_CLIENTS`      | number   | `2`                | Positive integer                   | Strategy `min_fit_clients`        | Minimum clients required to start a training round. |
| `FL_MIN_EVALUATE_CLIENTS` | number   | `2`                | Positive integer                   | Strategy `min_evaluate_clients`   | Minimum clients required for evaluation. |
| `FL_MIN_AVAILABLE_CLIENTS`| number   | `2`                | Positive integer                   | Strategy `min_available_clients`  | Minimum connected clients before starting any round. |
| `FL_FLEET_API_ADDRESS`    | text     | `0.0.0.0:9092`     | `host:port` format                 | `--fleet-api-address`             | Listen address for SuperNode connections. |
| `FL_CONTROL_API_ADDRESS`  | text     | `0.0.0.0:9093`     | `host:port` format                 | (implied by port mapping)         | Listen address for CLI management API. |
| `FL_ISOLATION`            | list     | `subprocess`       | One of: subprocess, process        | `--isolation`                     | App execution isolation mode. Subprocess is recommended. |
| `FL_DATABASE`             | text     | `state/state.db`   | Non-empty string                   | `--database`                      | Path (inside container) for SQLite state persistence. |
| `FL_LOG_LEVEL`            | list     | `INFO`             | One of: DEBUG, INFO, WARNING, ERROR| `FLWR_LOG_LEVEL` env var          | Flower logging verbosity. |

### USER_INPUT Definitions

For the OpenNebula VM template:

```
FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0"
FL_NUM_ROUNDS = "O|number|Number of federated learning rounds||3"
FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam|FedAvg"
FL_MIN_FIT_CLIENTS = "O|number|Minimum clients for training round||2"
FL_MIN_EVALUATE_CLIENTS = "O|number|Minimum clients for evaluation||2"
FL_MIN_AVAILABLE_CLIENTS = "O|number|Minimum available clients to start||2"
FL_FLEET_API_ADDRESS = "O|text|Fleet API listen address (host:port)||0.0.0.0:9092"
FL_CONTROL_API_ADDRESS = "O|text|Control API listen address (host:port)||0.0.0.0:9093"
FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess"
FL_DATABASE = "O|text|Database path for state persistence||state/state.db"
FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
```

### Infrastructure Variables (Non-User-Facing)

These are set in the VM template CONTEXT section, not exposed as USER_INPUTs:

| Variable            | Value                                    | Purpose                                 |
|---------------------|------------------------------------------|-----------------------------------------|
| `TOKEN`             | `YES`                                    | Enable OneGate authentication token     |
| `NETWORK`           | `YES`                                    | Enable network configuration            |
| `REPORT_READY`      | `YES`                                    | Report VM readiness after health check  |
| `READY_SCRIPT_PATH` | `/opt/flower/scripts/health-check.sh`    | Gate readiness on Flower being healthy  |
| `SSH_PUBLIC_KEY`     | `$USER[SSH_PUBLIC_KEY]`                  | Standard SSH key injection              |
| `START_SCRIPT_BASE64` | (base64-encoded launcher script)       | Triggers configure.sh and bootstrap.sh  |

### Naming Convention

- **`FLOWER_VERSION`**: Product-scoped, follows OpenNebula marketplace convention (e.g., `WORDPRESS_VERSION`).
- **`FL_*`**: Flower-specific configuration prefix. Short, distinctive, no collision with OpenNebula built-in variables.
- **Uppercase with underscores**: Standard OpenNebula CONTEXT variable style.

---

## 13. Immutability Model

The SuperLink appliance follows an **immutable appliance** pattern: all configuration is applied once at boot, and the appliance does not support runtime reconfiguration.

### Principles

1. **Configure once at boot.** All context variables are read during Step 3 of the boot sequence and never re-read.
2. **No reconfiguration daemon.** There is no process watching for variable changes or accepting runtime config updates.
3. **Redeploy to change configuration.** If parameters need to change (different number of rounds, different strategy), terminate the VM and deploy a new one with updated context variables.
4. **State survives within a deployment.** The SQLite state database (`state.db`) persists across container restarts within the same VM. It does not survive VM termination (unless the state volume is backed by persistent external storage).

### Rationale

- **Simplicity:** No need for a configuration management daemon, file watchers, or API for live changes.
- **Predictability:** The running state always matches the boot-time configuration. No drift.
- **OpenNebula alignment:** Contextualization runs once at boot (`START_SCRIPT`). There is no built-in mechanism for pushing config changes to a running VM.
- **Flower alignment:** Changing Flower server parameters (rounds, strategy, isolation mode) requires a process restart at minimum. There is no benefit to hot-reloading at the container level.

### Exception: Container Restart

Systemd may restart the container on crash (see Section 11). The restarted container reads the same generated configuration (`superlink.env`) and resumes from the same state database. This is recovery, not reconfiguration.

---

## Appendix A: Zero-Config Deployment Example

A SuperLink deployed with no USER_INPUT changes produces:

```
Flower SuperLink v1.25.0
  Mode:       insecure (no TLS)
  Isolation:  subprocess
  Fleet API:  0.0.0.0:9092
  Control API: 0.0.0.0:9093
  Strategy:   FedAvg
  Rounds:     3
  Min clients: 2 (fit), 2 (evaluate), 2 (available)
  Database:   /app/state/state.db
  Log level:  INFO
```

This is sufficient for a demo or development deployment. Connect 2+ SuperNodes and submit a Flower run to begin training.

---

## Appendix B: Relationship to Other Spec Sections

| Spec Section                      | Relationship to SuperLink                          |
|-----------------------------------|----------------------------------------------------|
| 02 - SuperNode Appliance          | SuperNodes connect to SuperLink on port 9092       |
| 03 - Contextualization Reference  | Consolidates all parameters from both appliances   |
| Phase 2 - TLS Security            | Replaces `--insecure` with certificate-based auth  |
| Phase 4 - OneFlow Orchestration   | Deploys SuperLink as the parent role               |
| Phase 5 - Training Configuration  | Extends strategy and checkpointing parameters      |

---

*Specification for APPL-01: SuperLink Appliance*
*Phase: 01 - Base Appliance Architecture*
*Version: 1.0*
