# 02 -- SuperNode Appliance

## SuperNode Appliance

### 1. Appliance Overview

The SuperNode appliance is the Flower federated learning client, packaged as an OpenNebula marketplace QCOW2 VM image. Each SuperNode instance trains a local model on its partition of data and communicates model updates (weights/gradients) to the SuperLink coordinator. Data never leaves the SuperNode VM.

**Architecture:** Docker-in-VM -- a single `flwr/supernode` container runs inside an Ubuntu 24.04 VM managed by OpenNebula. The VM provides tenant isolation; Docker provides reproducible Flower runtime; contextualization provides zero-config deployment.

**Key difference from SuperLink:** The SuperLink appliance (see `spec/01-superlink-appliance.md`) is self-contained -- it boots, starts listening, and publishes its endpoint. The SuperNode appliance has a **discovery phase**: before it can start the Flower container, it must determine the SuperLink's Fleet API address. This discovery adds complexity to the boot sequence and introduces a dual-mode resolution strategy (OneGate dynamic discovery or static IP override).

**Marketplace identifier:** `APPL-02`

---

### 2. Image Components

The QCOW2 image SHALL contain the following pre-installed components:

| Component | Version / Constraint | Purpose |
|-----------|---------------------|---------|
| Ubuntu 24.04 LTS (Noble Numbat) | 24.04 | Base OS. Matches the base OS used inside Flower Docker images, avoiding library mismatch. |
| Docker CE | 24+ (minimum, not pinned) | Container runtime for the Flower SuperNode container. |
| `flwr/supernode:1.25.0` | 1.25.0 (pre-pulled) | Flower federated learning client. Default tag resolves to `1.25.0-py3.13-ubuntu24.04`. |
| OpenNebula one-apps contextualization | latest | Guest agent providing networking, SSH key injection, CONTEXT variable export, `REPORT_READY` signaling. |
| jq | any | JSON parsing for OneGate API response processing during SuperLink discovery. |
| curl | any | HTTP client for OneGate API calls during discovery and status publication. |
| netcat (nc) | any | TCP connectivity checks used by health-check and OneGate pre-check scripts. |
| Custom scripts | -- | `/opt/flower/scripts/` -- configure.sh, bootstrap.sh, discover.sh, health-check.sh, common.sh |

**ML framework dependencies:** The base SuperNode image does NOT include ML framework libraries (PyTorch, TensorFlow, etc.). Those are bundled inside the Flower Docker image or provided via framework-specific appliance variants (see Phase 3). The base `flwr/supernode:1.25.0` image includes only the Flower client runtime and Python 3.13.

---

### 3. File Layout Inside the VM

```
/etc/one-appliance/
    service                           # Main lifecycle dispatcher (from one-apps)

/opt/flower/
    scripts/
        configure.sh                  # Stage 1: Read context vars, resolve SuperLink, write config
        bootstrap.sh                  # Stage 2: Start Docker container
        discover.sh                   # SuperLink discovery logic (OneGate + static)
        health-check.sh               # Container readiness probe
        common.sh                     # Shared functions (logging, OneGate helpers)
    config/
        supernode.env                 # Generated at boot: Docker environment variables
    certs/                            # TLS certificates (placeholder for Phase 2)
    data/                             # Local training data mount point

/var/log/one-appliance/
    flower-configure.log              # Configure stage output
    flower-bootstrap.log              # Bootstrap stage output
    flower-discover.log               # Discovery stage output
```

**Ownership:** The `/opt/flower/certs/` and `/opt/flower/data/` directories SHALL be owned by UID 49999 (the `app` user inside the Flower container). The build process SHALL run:

```bash
mkdir -p /opt/flower/{certs,data}
chown -R 49999:49999 /opt/flower/certs /opt/flower/data
```

---

### 4. Pre-baked Image Strategy

The QCOW2 image ships with Docker CE installed and `flwr/supernode:1.25.0` pre-pulled into the local Docker image cache. This is the same strategy used by the SuperLink appliance.

**Rationale:**
- Edge AI environments have unreliable or bandwidth-constrained networks. A pull failure at boot renders the appliance non-functional.
- Pre-baking adds approximately 190 MB to the QCOW2 image (Flower image compressed size) but eliminates any boot-time network dependency for the container image.
- The appliance is self-contained and can operate in air-gapped environments.

**Version override mechanism:** The `FLOWER_VERSION` contextualization variable allows deploying a different Flower version at boot. If `FLOWER_VERSION` differs from the pre-baked version, the bootstrap script SHALL attempt to pull the requested version and fall back to the pre-baked version on failure.

```
REQUESTED_VERSION = FLOWER_VERSION context variable (default: "1.25.0")
PREBAKED_VERSION  = "1.25.0" (hardcoded during image build)

IF REQUESTED_VERSION != PREBAKED_VERSION:
    Attempt: docker pull flwr/supernode:${REQUESTED_VERSION}
    On success: use REQUESTED_VERSION
    On failure: log WARNING, use PREBAKED_VERSION
```

**Version matching:** The SuperNode and SuperLink appliances MUST run the same Flower version. Version mismatch between SuperLink and SuperNode causes gRPC protocol errors (UNIMPLEMENTED or INTERNAL status codes). In OneFlow deployments, the `FLOWER_VERSION` variable SHOULD be set at the service level to ensure both roles use the same version.

**Estimated image size:** ~2-3 GB (Ubuntu 24.04 base + Docker CE + pre-pulled Flower image).

---

### 5. Recommended VM Resources

| Resource | Minimum | Recommended | Notes |
|----------|---------|-------------|-------|
| vCPU | 2 | 4 | Training is CPU-intensive; more cores reduce round time. |
| RAM | 4096 MB | 8192 MB | Model size determines memory. Large models (LLMs) require 16+ GB. |
| Disk | 20 GB | 40 GB | Base image ~2-3 GB; training data and model checkpoints consume additional space. |
| GPU | None (CPU-only default) | 1x NVIDIA GPU (Phase 6) | GPU passthrough is specified in Phase 6. The base appliance operates CPU-only. |

**Sizing guidance:** Resource requirements scale with model complexity and dataset size. The recommended values support typical image classification and tabular data workloads. For LLM fine-tuning or large vision models, increase RAM to 16-32 GB and allocate GPU resources per Phase 6.

---

### 6. SuperLink Discovery Model

This is the critical differentiator between the SuperNode and SuperLink appliances. Before the Flower SuperNode container can start, the bootstrap process must resolve the SuperLink's Fleet API address (`host:port`). The SuperNode supports two discovery modes and a deterministic decision logic to choose between them.

#### 6a. Decision Logic

The discovery resolution follows a strict priority order:

```
1. IF FL_SUPERLINK_ADDRESS is set and non-empty:
     USE static discovery mode
     SKIP OneGate entirely

2. ELSE IF OneGate token exists (/run/one-context/token.txt):
     USE dynamic discovery mode (OneGate)
     Execute discovery retry loop

3. ELSE:
     FAIL with error: "No SuperLink address provided and OneGate not available"
     Do NOT report ready
     Exit configure stage with non-zero status
```

**Rationale for priority order:** Static configuration takes precedence because it represents an explicit operator decision. This enables cross-site deployments, debugging (point a SuperNode at a specific SuperLink), and environments where OneGate is unavailable. OneGate discovery is the default for OneFlow-managed deployments where no static address is needed.

#### 6b. Static Discovery Mode

When `FL_SUPERLINK_ADDRESS` is set in the VM's CONTEXT variables, the SuperNode uses it directly as the SuperLink Fleet API address.

**Behavior:**
- The value SHALL be in `host:port` format (e.g., `192.168.1.100:9092` or `superlink.example.com:9092`).
- No validation of connectivity is performed during discovery; connection failures are handled by Flower's built-in reconnection logic.
- No OneGate queries are made.
- The discovery phase completes immediately.

**Use cases:**
- Manual deployments without OneFlow (standalone VMs).
- Cross-site federation where the SuperLink is in a different OpenNebula zone (Phase 7).
- Development and debugging (pointing to a specific SuperLink instance).
- Environments where OneGate is disabled or unreachable.

#### 6c. Dynamic Discovery Mode (OneGate)

When no static address is provided and a OneGate token is available, the SuperNode queries the OneGate service API to discover the SuperLink's published endpoint.

**Protocol:**

1. The SuperNode issues a GET request to the OneGate service endpoint.
2. The response contains the full OneFlow service definition with all roles and their VMs.
3. The SuperNode parses the response to find the `superlink` role's first VM.
4. It extracts the `FL_ENDPOINT` attribute from that VM's USER_TEMPLATE.
5. `FL_ENDPOINT` contains the SuperLink's Fleet API address in `host:port` format.

**OneGate query:**

```bash
SERVICE_JSON=$(curl -s "${ONEGATE_ENDPOINT}/service" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}")
```

**Response parsing:**

```bash
FL_ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
')
```

**Prerequisites:**
- `TOKEN=YES` in CONTEXT (provides `/run/one-context/token.txt`).
- The VM is part of a OneFlow service deployment.
- The SuperLink role VM has published `FL_ENDPOINT` to its USER_TEMPLATE via OneGate PUT.
- Network connectivity to the OneGate endpoint (typically `http://169.254.16.9:5030`).

**Dependency on SuperLink publication:** The SuperLink appliance publishes `FL_ENDPOINT` to OneGate only after its Flower container passes the health check (see `spec/01-superlink-appliance.md`, Section 10: OneGate Publication Contract). This means the SuperNode's discovery query may return empty results if the SuperLink has not finished booting. The retry loop (Section 6d) handles this timing gap.

#### 6d. Discovery Retry Loop

When using dynamic discovery mode, the SuperNode SHALL implement a retry loop to handle the timing gap between SuperNode boot and SuperLink readiness.

**Parameters:**

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Maximum retries | 30 | Provides sufficient time for SuperLink to boot and publish. |
| Retry interval | 10 seconds | Balances discovery latency against OneGate load. |
| Total timeout | 5 minutes (300 seconds) | 30 retries x 10 seconds. Covers worst-case SuperLink boot (Docker pull + container startup). |

**Retry loop behavior:**

```
FOR attempt = 1 TO 30:
    Query OneGate GET /service
    Parse response for FL_ENDPOINT from superlink role

    IF FL_ENDPOINT is non-empty:
        LOG "Discovered SuperLink at ${FL_ENDPOINT} (attempt ${attempt})"
        RETURN FL_ENDPOINT (success)

    IF response indicates OneGate error (HTTP 4xx/5xx):
        LOG "OneGate error on attempt ${attempt}: ${HTTP_STATUS}"
        (continue retrying -- transient OneGate errors are possible)

    IF response is valid but FL_ENDPOINT is empty:
        LOG "SuperLink not ready, waiting... (attempt ${attempt}/30)"

    SLEEP 10 seconds

LOG "ERROR: SuperLink discovery timed out after 30 attempts (5 minutes)"
EXIT with non-zero status
Do NOT report ready
```

**Timeout behavior:** If the retry loop exhausts all 30 attempts without discovering the SuperLink endpoint, the configure stage SHALL exit with a non-zero status code. The VM SHALL NOT report ready via `REPORT_READY`. The OneGate VM status will reflect the boot failure. An operator can inspect `/var/log/one-appliance/flower-discover.log` for diagnostics.

**Why not exponential backoff:** A fixed 10-second interval is used instead of exponential backoff because:
- The total window (5 minutes) is bounded and short enough that backoff provides minimal benefit.
- A fixed interval makes log analysis straightforward (each attempt is exactly 10 seconds apart).
- OneGate is a lightweight API; 1 request every 10 seconds is negligible load.

#### 6e. OneGate Connectivity Pre-check

Before entering the discovery retry loop, the SuperNode SHALL perform a connectivity pre-check to the OneGate endpoint.

**Pre-check procedure:**

```
1. Read ONEGATE_ENDPOINT from /run/one-context/one_env
2. IF ONEGATE_ENDPOINT is empty or unset:
     LOG "WARNING: ONEGATE_ENDPOINT not configured"
     FAIL discovery (same as case 3 in decision logic)

3. Attempt: curl -s -o /dev/null -w "%{http_code}" "${ONEGATE_ENDPOINT}/vm" \
     -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
     -H "X-ONEGATE-VMID: ${VMID}"

4. IF HTTP status is 2xx:
     LOG "OneGate connectivity verified"
     PROCEED to discovery retry loop

5. IF HTTP status is 4xx/5xx or connection refused/timeout:
     LOG "ERROR: OneGate unreachable at ${ONEGATE_ENDPOINT} (HTTP ${STATUS})"
     LOG "ERROR: Dynamic discovery requires OneGate. Set FL_SUPERLINK_ADDRESS for static mode."
     FAIL discovery
```

**Rationale:** Failing fast on OneGate connectivity issues prevents the SuperNode from spending 5 minutes in a retry loop that will never succeed. The pre-check distinguishes between "OneGate is up but SuperLink hasn't published yet" (enter retry loop) and "OneGate is unreachable" (fail immediately with actionable error message).

---

### 7. Linear Boot Sequence

The SuperNode boot follows a strict linear sequence. Each step validates its preconditions before proceeding. The sequence has 13 steps organized into three stages: OS initialization, configuration with discovery, and container startup.

| Step | Stage | Action | Why | Failure |
|------|-------|--------|-----|---------|
| 1 | OS Init | OS boots; one-apps contextualization packages execute | Configures networking, injects SSH keys, exports CONTEXT variables to `/run/one-context/one_env` | VM fails to reach RUNNING state; operator checks OpenNebula VM log |
| 2 | Configure | `configure.sh` sources `/run/one-context/one_env` | Loads all CONTEXT variables (FL_SUPERLINK_ADDRESS, FLOWER_VERSION, FL_NODE_CONFIG, etc.) into the script environment | Missing one_env file indicates broken contextualization; script exits with error |
| 3 | Configure | Validate required variables; set defaults for optional ones | Fail-fast on invalid configuration. Ensures all downstream scripts have valid inputs. | Validation errors logged to `flower-configure.log`; script exits non-zero; VM does not report ready |
| 4 | Configure | Create mount-target directories; set ownership to UID 49999 | Flower containers run as `app` (UID 49999). Directories created as root would cause "Permission denied" on container start. | Permission errors visible in `docker logs flower-supernode` |
| 5 | Configure | Generate `supernode.env` file and Docker run configuration | Translates CONTEXT variables into Docker environment variables and CLI flags | Malformed env file causes container startup failure |
| 6 | Configure | Write systemd unit file `flower-supernode.service` | Systemd manages container lifecycle, restart-on-failure, and dependency ordering with Docker daemon | Unit file write failure prevents service start |
| 7 | Discover | Execute SuperLink discovery (static or OneGate) | The SuperNode cannot start without knowing the SuperLink Fleet API address | Static: immediate (no failure path here; connectivity checked by Flower). OneGate: may retry for up to 5 minutes. On timeout, script exits non-zero. See Section 6. |
| 8 | Bootstrap | Wait for Docker daemon readiness | Docker may take 5-10 seconds to initialize after boot. Running `docker run` before daemon is ready causes "Cannot connect to the Docker daemon" errors. | Loop: `until docker info >/dev/null 2>&1; do sleep 1; done` with 60-second timeout |
| 9 | Bootstrap | Handle version override | If `FLOWER_VERSION` differs from pre-baked version, pull the requested image. Fall back to pre-baked on failure. | Pull failure: WARNING logged, pre-baked version used. Network-free environments always use pre-baked. |
| 10 | Bootstrap | Create and start Flower SuperNode container via systemd | Launches the `flwr/supernode` container with the discovered SuperLink address, node config, and all CLI flags | Container creation failure: check `docker logs flower-supernode`. Common cause: UID permission errors on mounted directories. |
| 11 | Bootstrap | Wait for SuperNode container to reach running state | Confirms the container process started successfully (not that it connected to SuperLink -- connection is Flower's responsibility) | Health check loop: `docker inspect --format='{{.State.Running}}' flower-supernode` with 60-second timeout |
| 12 | Bootstrap | Publish status to OneGate: `FL_NODE_READY=YES`, `FL_NODE_ID`, `FL_VERSION` | Signals to the OneFlow service that this SuperNode is operational. Enables monitoring and service-level readiness tracking. | OneGate PUT failure: WARNING logged but does NOT block readiness. SuperNode can function without OneGate publication. |
| 13 | Report | `REPORT_READY` contextualization reports VM as READY | OpenNebula marks the VM as READY. In OneFlow deployments, this signals role completion. | If any prior step failed, REPORT_READY is never reached; VM stays in boot state. |

**Total boot time estimate:**
- Steps 1-6: ~10-15 seconds (OS boot + configuration)
- Step 7: 0 seconds (static mode) or 10-300 seconds (OneGate discovery, depending on SuperLink readiness)
- Steps 8-13: ~10-20 seconds (Docker + container startup)
- **Typical total:** 20-35 seconds (static mode) or 30-335 seconds (OneGate mode)

---

### 8. Docker Container Configuration

The SuperNode container runs in subprocess isolation mode with no TLS (Phase 1 default).

**Reference Docker run command:**

```bash
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  -v /opt/flower/data:/app/data:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES:-0} \
  --max-wait-time ${FL_MAX_WAIT_TIME:-0}
```

**Parameter breakdown:**

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--name` | `flower-supernode` | Fixed container name for systemd management and log access. |
| `--restart` | `unless-stopped` | Docker restarts the container on crash. Does not restart if explicitly stopped. |
| `-v /opt/flower/data:/app/data:ro` | Read-only data mount | Local training data accessible to the ClientApp inside the container. Read-only prevents accidental data modification. |
| `-e FLWR_LOG_LEVEL` | From `FL_LOG_LEVEL` context var | Controls Flower's internal log verbosity (DEBUG, INFO, WARNING, ERROR). |
| `--insecure` | Flag | Disables TLS verification. Phase 1 only; Phase 2 replaces with `--root-certificates`. |
| `--superlink` | `${SUPERLINK_ADDRESS}:9092` | Fleet API address of the SuperLink, resolved during discovery (Section 6). |
| `--isolation subprocess` | Flag | ClientApp runs as a subprocess within the SuperNode container. Simplest mode; no additional containers needed. |
| `--node-config` | From `FL_NODE_CONFIG` context var | Space-separated key=value pairs passed to the ClientApp (e.g., `"partition-id=0 num-partitions=2"`). |
| `--max-retries` | From `FL_MAX_RETRIES` (default: 0) | Maximum reconnection attempts to SuperLink. `0` means unlimited. |
| `--max-wait-time` | From `FL_MAX_WAIT_TIME` (default: 0) | Maximum wait time in seconds for connection. `0` means unlimited. |

**No port mappings:** Unlike the SuperLink, the SuperNode does NOT expose any ports. The SuperNode initiates outbound gRPC connections to the SuperLink's Fleet API (port 9092). There is no inbound traffic to the SuperNode container.

**No persistent state volume:** The SuperNode does not maintain persistent state across restarts. Training state is ephemeral -- if the SuperNode container restarts, it re-registers with the SuperLink and waits for the next training round assignment.

**Phase 2 upgrade path:** When TLS is enabled (Phase 2), the Docker run command changes:
- Remove `--insecure`
- Add `-v /opt/flower/certs/ca.crt:/app/ca.crt:ro`
- Add `--root-certificates ca.crt`

---

### 9. Systemd Integration

The Flower SuperNode container SHALL be managed by a systemd service unit.

**Unit name:** `flower-supernode.service`

**Unit file specification:**

```ini
[Unit]
Description=Flower SuperNode (Federated Learning Client)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStartPre=-/usr/bin/docker rm -f flower-supernode
ExecStart=/usr/bin/docker start -a flower-supernode
ExecStop=/usr/bin/docker stop -t 30 flower-supernode

[Install]
WantedBy=multi-user.target
```

**Design notes:**
- `ExecStartPre=-` removes any leftover container from a previous failed run. The `-` prefix means failure is non-fatal (if no container exists to remove).
- `ExecStart` uses `docker start -a` (attach) rather than `docker run` because the container is created during the bootstrap stage. This separates container creation (with all CLI flags) from container lifecycle management.
- `ExecStop` sends SIGTERM with a 30-second grace period before SIGKILL. Flower handles SIGTERM for graceful shutdown.
- `Restart=on-failure` with `RestartSec=5s` provides automatic recovery from container crashes without tight restart loops.
- The systemd unit does NOT handle initial container creation or SuperLink discovery. Those are handled by `configure.sh` and `bootstrap.sh` during the one-time boot sequence.

---

### 10. Health Check and Readiness

The SuperNode health check differs from the SuperLink's port-based check. The SuperNode does not listen on any port; it makes outbound connections to the SuperLink. Therefore, health is determined by container process status, not network reachability.

**Primary health check: Container running state**

```bash
#!/bin/bash
# /opt/flower/scripts/health-check.sh
# Returns 0 if the Flower SuperNode container is running.
RUNNING=$(docker inspect --format='{{.State.Running}}' flower-supernode 2>/dev/null)
[ "$RUNNING" = "true" ]
```

**What this checks:**
- The Docker container process is alive and running.
- The Flower SuperNode process inside the container has not exited.

**What this does NOT check:**
- Whether the SuperNode has successfully connected to the SuperLink. Connection establishment is handled by Flower's built-in reconnection logic and is not a boot-time gate.
- Whether a training round is actively executing.

**Readiness gating:** The `REPORT_READY` mechanism uses this health check script as `READY_SCRIPT`. The VM reports READY once the container is confirmed running. The rationale for not gating on SuperLink connectivity: the SuperNode's reconnection logic (`--max-retries 0` = unlimited) means it will eventually connect when the SuperLink becomes available. Blocking READY on connectivity would create a circular dependency in OneFlow deployments where readiness reporting is needed for service progress tracking.

**Health check timeout:** The bootstrap script SHALL wait up to 60 seconds for the container to reach running state. If the container is not running after 60 seconds, the bootstrap script exits with non-zero status and the VM does not report ready.

---

### 11. Connection Lifecycle

After the SuperNode container starts, the Flower client runtime manages the connection to the SuperLink. The boot scripts are NOT responsible for connection maintenance.

**Connection establishment:**
- The SuperNode connects to the SuperLink's Fleet API at the address provided via `--superlink`.
- The connection uses gRPC (HTTP/2).
- In Phase 1 (`--insecure`), the connection is unencrypted. Phase 2 adds TLS.

**Reconnection behavior (Flower-native):**

| Parameter | CLI Flag | Default | Behavior |
|-----------|----------|---------|----------|
| Max retries | `--max-retries` | `0` (unlimited) | Number of reconnection attempts. `0` means retry indefinitely. |
| Max wait time | `--max-wait-time` | `0` (unlimited) | Total time in seconds to keep retrying. `0` means no timeout. |

With the default configuration (`--max-retries 0 --max-wait-time 0`), the SuperNode will attempt to reconnect to the SuperLink indefinitely. This is the correct behavior for production deployments where transient network issues or SuperLink restarts should not permanently disconnect SuperNodes.

**Connection lifecycle phases:**

```
1. CONNECTING    -- SuperNode initiates gRPC connection to SuperLink Fleet API
2. REGISTERED    -- SuperLink acknowledges the SuperNode; node receives a node ID
3. IDLE          -- Waiting for training round assignment from SuperLink
4. TRAINING      -- Executing a ClientApp task (training or evaluation)
5. REPORTING     -- Sending results (model weights/metrics) back to SuperLink
6. IDLE          -- Returns to waiting state for next round
   ...
7. DISCONNECTED  -- Connection lost (network issue, SuperLink restart)
8. RECONNECTING  -- Flower's built-in retry logic attempts reconnection
   (returns to step 1)
```

**What the appliance boot scripts handle:** Steps 1-2 (initial connection attempt via the `--superlink` flag). The discovery phase (Section 6) resolves the address; Flower handles everything after container start.

**What Flower handles natively:** Steps 3-8, including all reconnection logic. No custom wrapper scripts are needed.

**SuperLink restart scenario:** If the SuperLink restarts (e.g., VM reboot, container crash), all connected SuperNodes will detect the disconnection and enter the RECONNECTING state. With default settings, they will retry indefinitely until the SuperLink is available again. No operator intervention is required.

---

### 12. Local Data Mount Point

The SuperNode appliance provides a bind-mount point for local training data.

**Host path:** `/opt/flower/data`
**Container path:** `/app/data`
**Mount mode:** Read-only (`:ro`)

**Purpose:** The ClientApp running inside the SuperNode container accesses training data from this directory. In federated learning, each SuperNode trains on its local data partition. The data never leaves the VM.

**Data provisioning:** The spec does not prescribe how data is placed in `/opt/flower/data`. Common approaches include:
- Pre-loaded in the QCOW2 image (for demo/PoC scenarios).
- Mounted from a Longhorn persistent volume or NFS share.
- Downloaded at boot via a custom `START_SCRIPT` contextualization command.
- Pushed via SSH before starting a training run.

**Ownership:** The directory SHALL be owned by UID 49999 (the Flower container's `app` user). The QCOW2 image build process creates this directory with correct ownership. If data is provisioned at boot, the provisioning script must preserve or re-set ownership:

```bash
chown -R 49999:49999 /opt/flower/data
```

**ClientApp access:** The ClientApp code references the data path as `/app/data` (the container-internal path). The `--node-config` parameter can pass partition information (e.g., `partition-id=0 num-partitions=4`) to the ClientApp so it knows which subset of the data to use.

---

### 13. SuperNode Contextualization Parameters

The following contextualization variables configure the SuperNode appliance at boot. All variables are optional; deploying with no parameters changed produces a working SuperNode that discovers its SuperLink via OneGate and connects with default settings.

#### Flower Configuration Variables

| Context Variable | Type | Default | Flower Mapping | Description |
|-----------------|------|---------|----------------|-------------|
| `FLOWER_VERSION` | `O\|text` | `1.25.0` | Docker image tag | Flower Docker image version. Must match SuperLink version. |
| `FL_SUPERLINK_ADDRESS` | `O\|text` | (empty) | `--superlink` | Static SuperLink Fleet API address (`host:port`). Leave empty for OneGate discovery. |
| `FL_NODE_CONFIG` | `O\|text` | (empty) | `--node-config` | Space-separated key=value pairs for ClientApp (e.g., `"partition-id=0 num-partitions=2"`). |
| `FL_MAX_RETRIES` | `O\|number` | `0` | `--max-retries` | Max reconnection attempts. `0` = unlimited. |
| `FL_MAX_WAIT_TIME` | `O\|number` | `0` | `--max-wait-time` | Max wait time for connection in seconds. `0` = unlimited. |
| `FL_ISOLATION` | `O\|list` | `subprocess` | `--isolation` | App execution isolation mode. Options: `subprocess`, `process`. |
| `FL_LOG_LEVEL` | `O\|list` | `INFO` | `FLWR_LOG_LEVEL` env var | Log verbosity. Options: `DEBUG`, `INFO`, `WARNING`, `ERROR`. |

#### Infrastructure Variables

| Context Variable | Type | Default | Purpose |
|-----------------|------|---------|---------|
| `TOKEN` | (not user-facing) | `YES` | Provides OneGate authentication token for dynamic discovery. |
| `NETWORK` | (not user-facing) | `YES` | Enables network configuration by contextualization agent. |
| `REPORT_READY` | (not user-facing) | `YES` | Reports VM readiness after SuperNode container starts. |
| `READY_SCRIPT_PATH` | (not user-facing) | `/opt/flower/scripts/health-check.sh` | Script that validates SuperNode is healthy before reporting ready. |
| `SSH_PUBLIC_KEY` | (from user) | `$USER[SSH_PUBLIC_KEY]` | SSH key injection for operator access. |

#### Phase 2+ Placeholder Variables (Not Functional in Phase 1)

| Context Variable | Type | Phase | Description |
|-----------------|------|-------|-------------|
| `FL_TLS_ENABLED` | `O\|boolean` | Phase 2 | Master switch for TLS. Default: `NO`. |
| `FL_SSL_CA_CERTFILE` | `O\|text64` | Phase 2 | CA certificate (base64 PEM) for TLS verification. |
| `FL_GPU_ENABLED` | `O\|boolean` | Phase 6 | Enable NVIDIA GPU passthrough to container. Default: `NO`. |
| `ML_FRAMEWORK` | `O\|list` | Phase 3 | ML framework variant selection (pytorch, tensorflow, sklearn). |

**Zero-config behavior:** A SuperNode deployed within a OneFlow service with no contextualization variables set will:
1. Discover the SuperLink automatically via OneGate.
2. Connect using Flower 1.25.0 in insecure mode with subprocess isolation.
3. Retry connection indefinitely if the SuperLink is not yet available.
4. Wait for training round assignments from the SuperLink.

---

### 14. Failure Modes and Error Handling

| Failure | Detection | Impact | Recovery |
|---------|-----------|--------|----------|
| Docker daemon fails to start | `docker info` returns non-zero after 60-second timeout | Container cannot be created. VM does not report ready. | Operator SSH into VM; check `systemctl status docker` and `journalctl -u docker`. |
| Flower container exits immediately | `docker inspect` shows `Running=false` within health check window | VM does not report ready. | Check `docker logs flower-supernode`. Most common cause: UID 49999 permission errors on mounted directories. |
| OneGate connectivity failure | Pre-check curl returns non-2xx or connection refused | Dynamic discovery cannot proceed. | Set `FL_SUPERLINK_ADDRESS` for static discovery. Check network routing to OneGate endpoint. |
| SuperLink not discovered (timeout) | Discovery retry loop exhausts 30 attempts | Configure stage exits non-zero. VM does not report ready. | Verify SuperLink VM is running and has published FL_ENDPOINT. Check `/var/log/one-appliance/flower-discover.log`. |
| SuperLink connection refused after discovery | Flower logs show "Connection refused" to discovered endpoint | Container is running but cannot train. Flower retries indefinitely. | SuperLink may still be starting. Wait for Flower's reconnection. Check SuperLink health. |
| Version override pull failure | `docker pull` returns non-zero | WARNING logged. Pre-baked version used instead. | Verify network connectivity and image tag existence. |
| Invalid FL_NODE_CONFIG format | Flower container exits with config parse error | VM does not report ready (container exits = health check fails). | Check `docker logs flower-supernode` for config parsing errors. Fix FL_NODE_CONFIG format. |
| OneGate publication failure | OneGate PUT returns non-2xx | WARNING logged. SuperNode still functions. Monitoring/service tracking may be incomplete. | Check OneGate connectivity. Non-blocking failure; SuperNode operates normally. |
| Disk full | Docker commands fail with "no space left on device" | Container cannot start or write training artifacts. | Increase disk allocation. Clean unused Docker images with `docker system prune`. |

**Error logging:** All errors are written to the stage-specific log files under `/var/log/one-appliance/` and to the systemd journal. The Flower container's internal logs are accessible via `docker logs flower-supernode`.

**Non-blocking vs. blocking failures:**
- **Blocking:** Docker daemon failure, container exit, discovery timeout, validation errors. These prevent the VM from reporting ready.
- **Non-blocking:** OneGate publication failure, version override pull failure. These are logged as warnings but do not prevent the SuperNode from operating.

---

### 15. Immutability Model

The SuperNode appliance follows the same immutability model as the SuperLink (see `spec/01-superlink-appliance.md`).

**Principles:**
- The appliance is immutable after initial boot. There is no reconfiguration mechanism.
- Contextualization variables are read once during the configure stage and are not re-read.
- If parameters need to change, the VM SHALL be terminated and a new one deployed with updated parameters.
- Redeployment via OneFlow (scaling the role down then up, or re-instantiating the service) is the standard operational pattern.

**Rationale:**
- Flower containers are long-running daemons. Changing configuration mid-run would require container restart, which interrupts any active training round.
- OpenNebula contextualization runs `START_SCRIPT` once at boot. There is no built-in mechanism to re-trigger on parameter changes.
- Immutability eliminates state drift. Every running SuperNode's configuration matches its CONTEXT variables exactly.
- For federated learning workloads, it is preferable to add new SuperNodes (scale out) rather than reconfigure existing ones.

---

### 16. Relationship to SuperLink Spec

The SuperNode appliance specification depends on and complements the SuperLink appliance specification (`spec/01-superlink-appliance.md`).

**Cross-references:**

| SuperNode Concept | SuperLink Reference | Dependency |
|-------------------|--------------------|----|
| Discovery: `FL_ENDPOINT` attribute | SuperLink Section 10: OneGate Publication Contract | SuperNode reads what SuperLink publishes. The attribute name `FL_ENDPOINT` and format `host:port` MUST match. |
| Discovery: `superlink` role name | SuperLink OneGate PUT: `FL_ROLE=superlink` | The jq filter in discover.sh selects `.roles[] \| select(.name == "superlink")`. Role name MUST match. |
| Fleet API port 9092 | SuperLink Section 7: Docker Configuration (port mappings) | SuperNode connects to port 9092 via `--superlink host:9092`. SuperLink MUST expose this port. |
| `FLOWER_VERSION` matching | SuperLink Section 4: Pre-baked Image Strategy | Both appliances MUST run the same Flower version. Mismatch causes gRPC protocol errors. |
| `--insecure` flag | SuperLink `--insecure` flag | Both sides MUST agree on TLS mode. Phase 1: both use `--insecure`. Phase 2: both use certificates. |
| Immutability model | SuperLink Section 13: Immutability Model | Same pattern: no reconfiguration, redeploy to change parameters. |
| Pre-baked image strategy | SuperLink Section 4 | Same strategy: Docker image pre-pulled, version override with fallback. |

**Shared components:** Both appliances share the same QCOW2 base (Ubuntu 24.04 + Docker CE + one-apps contextualization) and the same script structure (`/opt/flower/scripts/`). The differences are in the Flower container image (`flwr/superlink` vs `flwr/supernode`), the boot sequence (SuperNode has a discovery phase), and the network role (SuperLink listens; SuperNode connects).

---

*Document: spec/02-supernode-appliance.md*
*Phase: 01-base-appliance-architecture*
*Requirement: APPL-02*
*Status: Complete*
