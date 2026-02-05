# Phase 1: Base Appliance Architecture - Research

**Researched:** 2026-02-05
**Domain:** Docker-in-VM marketplace appliances for Flower federated learning on OpenNebula
**Confidence:** HIGH (core technologies well-documented), MEDIUM (integration patterns are novel)

## Summary

This research covers the three pillars of Phase 1: (1) appliance packaging -- how to build Docker-in-VM QCOW2 images with Ubuntu 24.04 and Docker CE that run Flower containers, (2) boot sequences -- how contextualization scripts initialize the appliance and start Flower via Docker, and (3) contextualization parameter mapping -- the complete set of Flower CLI flags mapped to OpenNebula USER_INPUT variables.

The standard approach is clear: Ubuntu 24.04 LTS as the VM base OS running Docker CE 24+, which pulls and runs official `flwr/superlink` or `flwr/supernode` Docker images. Flower 1.25.0 is the latest stable release with official Ubuntu 24.04-based Docker images supporting both amd64 and arm64. The images run as non-root user `app` (UID 49999). Subprocess isolation mode is recommended for simplicity (each container self-manages its app processes). OneGate provides runtime service discovery: the SuperLink publishes its endpoint, SuperNodes poll to discover it. OpenNebula USER_INPUTS use a pipe-delimited format with 11 supported types.

**Primary recommendation:** Spec a pre-baked fat image strategy (Docker pre-installed, Flower image pre-pulled) with contextualization scripts that configure and start containers at boot. Use subprocess isolation mode. Default to zero-config operation with FedAvg, 3 rounds, and insecure mode for Phase 1 (TLS deferred to Phase 2).

## Standard Stack

The established technologies for this phase:

### Core

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| Ubuntu 24.04 LTS | 24.04 (Noble) | VM base OS | User decision. Matches Flower Docker image base OS. Long-term support until 2029. |
| Docker CE | 24+ (minimum) | Container runtime | Required for Docker-in-VM pattern. APT-installable on Ubuntu 24.04. |
| flwr/superlink | 1.25.0 | FL coordinator container | Latest stable release (Dec 2025). Official Docker image, Ubuntu 24.04 base, amd64+arm64. |
| flwr/supernode | 1.25.0 | FL client container | Same release, same base, same architectures. |
| OpenNebula | 7.0+ | Cloud platform | Target platform. Native OneFlow, contextualization, marketplace. |
| one-apps contextualization | latest | VM guest integration | Standard OpenNebula pattern: handles networking, SSH, START_SCRIPT, REPORT_READY. |

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| flwr/superexec | 1.25.0 | Process executor (optional) | Only needed for process isolation mode. In subprocess mode (recommended), SuperExec is embedded. |
| NVIDIA Container Toolkit | latest | GPU access from Docker | Phase 6 dependency. Pre-install in image for GPU-ready appliance. |
| Python | 3.13 (in Flower image) | Flower runtime | Bundled inside Flower Docker images. No separate install needed. |
| jq | any | JSON parsing | For OneGate API response parsing in boot scripts. |
| curl | any | HTTP client | For OneGate API calls from contextualization scripts. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Ubuntu 24.04 (VM) | openSUSE 15.6 (VM) | openSUSE is EU-sovereignty aligned but Docker image compatibility with Flower is untested. Ubuntu is the same OS inside the Flower containers, avoiding any library mismatch. |
| Pre-baked Flower image | Pull-at-boot | Pull-at-boot saves ~180MB image size but adds 30-60s boot time and requires network. Pre-baked is better for edge/air-gapped scenarios. |
| Subprocess isolation | Process isolation | Process isolation provides stronger container boundaries but requires running 3+ containers per VM instead of 1. Unnecessary complexity for appliance pattern. |
| Docker CE | Podman | Podman is daemonless but adds compatibility concerns with Flower's Docker Compose examples and nvidia-container-toolkit. |

### Image Tag Convention

Flower Docker images follow this tag pattern:
```
{version}-py{python_version}-{os}
```

Available stable tags for v1.25.0:
- `1.25.0` (default: py3.13-ubuntu24.04)
- `1.25.0-py3.13-ubuntu24.04`
- `1.25.0-py3.12-ubuntu24.04`
- `1.25.0-py3.11-ubuntu24.04`
- `1.25.0-py3.10-ubuntu24.04`
- Alpine variants also available (not recommended for GPU workloads)

**Confidence:** HIGH -- verified via Flower Docker documentation, Docker Hub, and prior roadmap research.

## Architecture Patterns

### Recommended Appliance File Layout (inside the VM)

```
/etc/one-appliance/
    service                       # Main lifecycle dispatcher (from one-apps)
/opt/flower/
    scripts/
        configure.sh              # Stage 1: Read context vars, write config
        bootstrap.sh              # Stage 2: Start Docker containers
        health-check.sh           # Readiness probe script
        common.sh                 # Shared functions (logging, OneGate helpers)
    config/
        superlink.env             # Generated: SuperLink env vars
        supernode.env             # Generated: SuperNode env vars
    certs/                        # TLS certificates (Phase 2)
    state/                        # SuperLink persistent state
/var/log/one-appliance/
    flower-configure.log          # Configure stage output
    flower-bootstrap.log          # Bootstrap stage output
```

### Pattern 1: Docker-in-VM with Pre-baked Image

**What:** The QCOW2 appliance image ships with Docker CE installed and the Flower Docker image pre-pulled. At boot, contextualization scripts configure and start the container.

**When to use:** Always (this is the decided pattern).

**Rationale for pre-baked over pull-at-boot:**
- Edge AI environments have unreliable networks -- a pull failure at boot means a non-functional appliance
- Pre-baked adds ~180MB to QCOW2 (Flower images are ~190MB compressed) but eliminates boot-time network dependency
- The `FLOWER_VERSION` context variable can still override and trigger a pull of a different version at boot
- Production appliances should be self-contained

**Boot-time override mechanism:**
```bash
# In bootstrap.sh:
REQUESTED_VERSION="${FLOWER_VERSION:-1.25.0}"
PREBAKED_VERSION="1.25.0"  # Hardcoded during image build

if [ "$REQUESTED_VERSION" != "$PREBAKED_VERSION" ]; then
    log "Pulling requested Flower version: $REQUESTED_VERSION"
    docker pull "flwr/superlink:${REQUESTED_VERSION}" || {
        log "ERROR: Failed to pull version $REQUESTED_VERSION, falling back to pre-baked $PREBAKED_VERSION"
        REQUESTED_VERSION="$PREBAKED_VERSION"
    }
fi
```

### Pattern 2: Linear Boot Sequence with Readiness Gates

**What:** Boot follows a strict linear sequence where each step validates its preconditions before proceeding. The sequence reports status to OneGate at each transition.

**Recommendation:** Use a linear sequence, not a state machine. The boot process is fundamentally sequential (network -> config -> docker -> flower), and state machines add complexity that is not justified for a one-shot initialization.

**SuperLink Boot Sequence:**
```
1. OS Boot + Contextualization packages run
2. [configure.sh] Read CONTEXT variables from /run/one-context/one_env
3. [configure.sh] Validate required variables, set defaults for optional ones
4. [configure.sh] Generate Docker run configuration (env file, volume mounts)
5. [configure.sh] Write systemd unit file for Flower container
6. [bootstrap.sh] Start Docker daemon (if not running)
7. [bootstrap.sh] Start Flower SuperLink container via systemd
8. [bootstrap.sh] Wait for SuperLink to listen on port 9092 (health check loop)
9. [bootstrap.sh] Publish endpoint to OneGate: FL_ENDPOINT=<ip>:9092, FL_READY=YES
10. [REPORT_READY] Contextualization reports VM as READY
```

**SuperNode Boot Sequence:**
```
1. OS Boot + Contextualization packages run
2. [configure.sh] Read CONTEXT variables from /run/one-context/one_env
3. [configure.sh] Validate required variables, set defaults for optional ones
4. [configure.sh] Determine SuperLink address:
   a. If FL_SUPERLINK_ADDRESS is set explicitly -> use it (static mode)
   b. Else -> query OneGate for SuperLink endpoint (dynamic discovery mode)
5. [configure.sh] Generate Docker run configuration (env file, volume mounts)
6. [configure.sh] Write systemd unit file for Flower container
7. [bootstrap.sh] Start Docker daemon (if not running)
8. [bootstrap.sh] Start Flower SuperNode container via systemd
9. [bootstrap.sh] Wait for SuperNode to establish connection (health check)
10. [bootstrap.sh] Publish status to OneGate: FL_NODE_READY=YES
11. [REPORT_READY] Contextualization reports VM as READY
```

### Pattern 3: OneGate Service Discovery Protocol

**What:** SuperLink publishes its endpoint via OneGate PUT. SuperNodes discover it via OneGate GET /service.

**The contract:**

SuperLink publishes (after container is healthy):
```bash
curl -X PUT "${ONEGATE_ENDPOINT}/vm" \
  -H "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
  -H "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_READY=YES" \
  -d "FL_ENDPOINT=${MY_IP}:9092" \
  -d "FL_VERSION=1.25.0" \
  -d "FL_ROLE=superlink"
```

SuperNode discovers (with retry loop):
```bash
MAX_RETRIES=30
RETRY_INTERVAL=10  # seconds
for i in $(seq 1 $MAX_RETRIES); do
    SERVICE_JSON=$(curl -s "${ONEGATE_ENDPOINT}/service" \
      -H "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
      -H "X-ONEGATE-VMID: ${VMID}")

    # Parse the superlink role's VM for FL_ENDPOINT
    ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
      .SERVICE.roles[]
      | select(.name == "superlink")
      | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
    ')

    if [ -n "$ENDPOINT" ]; then
        log "Discovered SuperLink at $ENDPOINT"
        break
    fi
    log "Waiting for SuperLink... attempt $i/$MAX_RETRIES"
    sleep $RETRY_INTERVAL
done
```

**Fallback to Flower-native reconnect:** Even after initial discovery, if the SuperLink becomes temporarily unavailable, the `flower-supernode` CLI has built-in reconnect logic via `--max-retries` (unlimited by default) and `--max-wait-time`. The discovery loop only handles the initial bootstrap; ongoing connectivity is Flower's responsibility.

### Pattern 4: Dual Discovery Mode

**What:** Support both OneGate dynamic discovery (default for OneFlow deployments) and static IP override (for manual/cross-site deployments).

**Decision logic in configure.sh:**
```bash
if [ -n "$FL_SUPERLINK_ADDRESS" ]; then
    # Static mode: user provided the address explicitly
    SUPERLINK_ADDRESS="$FL_SUPERLINK_ADDRESS"
    log "Using static SuperLink address: $SUPERLINK_ADDRESS"
elif [ -f /run/one-context/token.txt ]; then
    # Dynamic mode: discover via OneGate (OneFlow deployment)
    SUPERLINK_ADDRESS=$(discover_via_onegate)
    log "Discovered SuperLink via OneGate: $SUPERLINK_ADDRESS"
else
    log "ERROR: No SuperLink address provided and OneGate not available"
    exit 1
fi
```

### Pattern 5: Immutable Appliance with Runtime Configuration

**Recommendation:** Appliances should be immutable (no reconfiguration after initial boot). If parameters need to change, redeploy. This is simpler, more predictable, and avoids state drift.

**Rationale:**
- Flower containers are designed to be long-running daemons; changing config mid-run would require container restart anyway
- OpenNebula's contextualization runs once at boot (START_SCRIPT), not on parameter changes
- Redeployment via OneFlow is the standard operational pattern
- No need for a reconfiguration daemon watching for changes

### Anti-Patterns to Avoid

- **Running Flower directly on the VM (no Docker):** Loses version flexibility, environment isolation, and the ability to match upstream Flower exactly.
- **Using process isolation mode in appliances:** Requires 3+ containers (SuperLink + SuperExec + app containers), Docker networking between them, and complex orchestration. Subprocess mode keeps it to 1 container per VM.
- **Hardcoding Flower version in boot scripts:** Use a contextualization variable so users can override.
- **Skipping the health check loop:** Starting Flower and immediately reporting READY causes SuperNodes to attempt connection before SuperLink is listening.
- **Using cloud-init instead of one-apps contextualization:** OpenNebula's contextualization system is better integrated. cloud-init works but adds an unnecessary abstraction layer.
- **Polling OneGate without backoff or timeout:** An infinite tight loop hammering OneGate will be rate-limited and waste resources.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Flower process management | Custom PID management, restart logic | Systemd unit managing Docker container + Flower's built-in subprocess mode | Flower handles process lifecycle internally; Docker provides restart policies; systemd handles container crashes. |
| SuperNode reconnection to SuperLink | Custom reconnect loop in boot scripts | Flower's `--max-retries` and `--max-wait-time` CLI flags | Flower has built-in reconnection with unlimited retries by default. No custom logic needed after initial discovery. |
| Flower version management | Custom update scripts | Docker image tags via `FLOWER_VERSION` context variable | Docker's pull mechanism handles version selection. Pre-baked image provides fallback. |
| gRPC health checking | Custom TCP socket probe | Flower's `--health-server-address` flag (gRPC health check server) | Both SuperLink and SuperNode support a built-in gRPC health check endpoint. |
| Contextualization variable reading | Custom env parsing | Source `/run/one-context/one_env` | OpenNebula's contextualization packages export all CONTEXT variables to this file. Standard pattern used by all one-apps appliances. |
| VM readiness reporting | Custom OneGate calls | `REPORT_READY=YES` + `READY_SCRIPT` context attributes | Built into one-apps contextualization packages. READY_SCRIPT can gate readiness on Flower health check. |
| Log aggregation | Custom log shipping | Docker's built-in `json-file` log driver + `docker logs` | Sufficient for Phase 1. Structured logging with Promtail is Phase 8. |

**Key insight:** Between Flower's built-in reconnection/health-check features and OpenNebula's contextualization readiness reporting, the boot scripts only need to handle initial configuration and startup. Everything else is handled by existing mechanisms.

## Common Pitfalls

### Pitfall 1: Flower Container UID 49999 Permission Errors

**What goes wrong:** Flower Docker images run as non-root user `app` (UID 49999). Any directories or files mounted into the container (certificates, state directory, logs) must be owned by this UID. Default Docker bind mounts create directories as root, causing "Permission denied" errors.

**Why it happens:** Standard `docker run -v` creates mount targets as root. The Flower entrypoint does not attempt to fix permissions.

**How to avoid:** In the configure stage, create all mount-target directories and chown them:
```bash
mkdir -p /opt/flower/state /opt/flower/certs
chown -R 49999:49999 /opt/flower/state /opt/flower/certs
```

**Warning signs:** Container starts but immediately exits. `docker logs` shows "Permission denied" on `/app/` paths.

**Confidence:** HIGH -- documented in official Flower Docker TLS guide.

### Pitfall 2: OneGate Discovery Race Condition

**What goes wrong:** In OneFlow "straight" deployment, the SuperNode role starts deploying after SuperLink role VMs reach RUNNING state. But RUNNING means the VM's OS booted -- it does NOT mean the SuperLink container is up and listening. The SuperNode VM may boot faster than the SuperLink container starts (especially on first pull), causing connection failures.

**Why it happens:** OpenNebula's RUNNING state is a VM-level concept. Application readiness is a separate concern.

**How to avoid:**
1. Use `REPORT_READY=YES` with `READY_SCRIPT` on the SuperLink VM to gate readiness on the Flower container being healthy.
2. On the SuperNode side, implement a retry loop with exponential backoff when querying OneGate for the SuperLink endpoint.
3. Even if the SuperNode discovers the endpoint, Flower's `--max-retries` handles the case where the SuperLink is still starting up.

**Warning signs:** SuperNode VMs are RUNNING but Flower logs show "Connection refused" to SuperLink.

**Confidence:** MEDIUM -- based on OpenNebula OneFlow behavior and Flower networking docs. The exact interaction of REPORT_READY with OneFlow role dependencies needs validation.

### Pitfall 3: Docker Daemon Not Ready at Boot

**What goes wrong:** Contextualization scripts attempt to run `docker pull` or `docker run` before the Docker daemon has fully started. This happens on first boot when Docker is also being configured.

**Why it happens:** On Ubuntu 24.04, Docker CE starts via systemd but may take 5-10 seconds to become ready after system boot. Contextualization scripts run via `one-context` which may execute before Docker is fully initialized.

**How to avoid:** In the bootstrap script, wait for Docker:
```bash
until docker info >/dev/null 2>&1; do
    sleep 1
done
```
Or use systemd ordering: ensure the Flower service unit has `After=docker.service` and `Requires=docker.service`.

**Warning signs:** "Cannot connect to the Docker daemon" errors in boot logs.

**Confidence:** HIGH -- standard Docker operational pattern.

### Pitfall 4: Version Mismatch Between SuperLink and SuperNode

**What goes wrong:** If SuperLink runs Flower 1.25.0 and SuperNode runs 1.24.0 (or vice versa), gRPC protocol differences cause connection failures, serialization errors, or silent behavioral differences.

**Why it happens:** The `FLOWER_VERSION` context variable is per-VM. If set differently (or if one uses the default while the other overrides), versions diverge.

**How to avoid:**
1. Pre-bake the same version in both appliance images.
2. In OneFlow service templates, set `FLOWER_VERSION` at the service level, not per-role.
3. In the boot script, log the Flower version prominently for debugging.

**Warning signs:** gRPC UNIMPLEMENTED or INTERNAL status codes in connection logs.

**Confidence:** HIGH -- verified against Flower changelog documenting breaking changes between versions.

### Pitfall 5: Insufficient Default Resources

**What goes wrong:** SuperLink with default MEMORY=2048 runs out of memory when aggregating model weights from 10+ clients. SuperNode with default CPU=2 takes excessively long on training.

**Why it happens:** Marketplace appliances often use minimal resource defaults for broad compatibility. FL workloads are compute/memory-intensive.

**How to avoid:** Set realistic defaults in the VM template:
- SuperLink: 4 vCPU, 8192 MB RAM minimum
- SuperNode: 4 vCPU, 8192 MB RAM minimum (no GPU default; GPU config is Phase 6)

**Warning signs:** OOM kills visible in `dmesg`, slow training rounds.

**Confidence:** MEDIUM -- sizing depends on model size and client count.

### Pitfall 6: Missing Network Connectivity for OneGate

**What goes wrong:** The SuperNode VM cannot reach the OneGate endpoint (default: `http://169.254.16.9:5030`), so dynamic discovery fails silently.

**Why it happens:** OneGate requires `TOKEN=YES` in CONTEXT and proper network routing. If the VM is on a network segment that cannot reach the OneGate service, all OneGate calls fail.

**How to avoid:**
1. Always include `TOKEN=YES` and `NETWORK=YES` in CONTEXT.
2. In the discovery script, test OneGate connectivity before relying on it.
3. Fall back to static `FL_SUPERLINK_ADDRESS` if OneGate is unreachable.
4. Log a clear warning: "OneGate unreachable; dynamic discovery disabled."

**Warning signs:** `curl` to OneGate endpoint returns connection refused or timeout.

**Confidence:** HIGH -- documented OneGate prerequisite.

## Code Examples

Verified patterns from official sources:

### SuperLink Docker Run (Subprocess Mode, No TLS -- Phase 1 Default)

```bash
# Source: Flower Docker Quickstart + CLI reference
docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  -e FLWR_LOG_LEVEL=INFO \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --isolation subprocess \
  --database state/state.db
```

**Ports exposed:**
- 9091: ServerAppIo API (internal, subprocess mode = loopback only in practice)
- 9092: Fleet API (SuperNodes connect here)
- 9093: Control API (CLI management)

**Flags explained:**
- `--insecure`: No TLS (Phase 1 default; Phase 2 adds TLS)
- `--isolation subprocess`: SuperExec runs as subprocess within SuperLink (default, simplest)
- `--database state/state.db`: Persistent state for run history

### SuperNode Docker Run (Subprocess Mode, No TLS -- Phase 1 Default)

```bash
# Source: Flower Docker Quickstart + CLI reference
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  -e FLWR_LOG_LEVEL=INFO \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "partition-id=${PARTITION_ID:-0} num-partitions=${NUM_PARTITIONS:-1}" \
  --max-retries 0 \
  --max-wait-time 0
```

**Flags explained:**
- `--superlink`: Fleet API address of the SuperLink
- `--node-config`: Key-value pairs passed to the ClientApp (used for data partitioning)
- `--max-retries 0`: Unlimited retries (0 = infinite, default behavior)
- `--max-wait-time 0`: No timeout on connection attempts

### SuperLink Docker Run (With TLS -- Phase 2 Preview)

```bash
# Source: Flower Docker TLS documentation
docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/certs:/app/certificates:ro \
  -v /opt/flower/state:/app/state \
  -e FLWR_LOG_LEVEL=INFO \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --ssl-ca-certfile certificates/ca.crt \
  --ssl-certfile certificates/server.pem \
  --ssl-keyfile certificates/server.key \
  --isolation subprocess \
  --database state/state.db
```

**Certificate file ownership requirement:**
```bash
# CRITICAL: Flower containers run as UID 49999
sudo chown -R 49999:49999 /opt/flower/certs
```

### SuperNode Docker Run (With TLS -- Phase 2 Preview)

```bash
# Source: Flower Docker TLS documentation
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  -v /opt/flower/certs/ca.crt:/app/ca.crt:ro \
  -e FLWR_LOG_LEVEL=INFO \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --root-certificates ca.crt \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess
```

### OneGate Publish (SuperLink)

```bash
# Source: OpenNebula OneGate documentation (6.6+)
# Publishes SuperLink endpoint for SuperNode discovery
ONEGATE_TOKEN=$(cat /run/one-context/token.txt)
VMID=$(cat /run/one-context/one_env | grep -oP 'VMID=\K[0-9]+' || true)
MY_IP=$(hostname -I | awk '{print $1}')

curl -s -X PUT "${ONEGATE_ENDPOINT}/vm" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_READY=YES" \
  -d "FL_ENDPOINT=${MY_IP}:9092" \
  -d "FL_VERSION=${FLOWER_VERSION}" \
  -d "FL_ROLE=superlink"
```

### OneGate Discover (SuperNode)

```bash
# Source: OpenNebula OneGate documentation (6.6+)
# Discovers SuperLink endpoint from OneFlow service
ONEGATE_TOKEN=$(cat /run/one-context/token.txt)
VMID=$(cat /run/one-context/one_env | grep -oP 'VMID=\K[0-9]+' || true)

SERVICE_JSON=$(curl -s "${ONEGATE_ENDPOINT}/service" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}")

# Extract SuperLink endpoint from the superlink role's first node
FL_ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
')
```

### OneFlow Parent Attribute Reference

```json
{
  "name": "supernode",
  "parents": ["superlink"],
  "template_contents": "CONTEXT = [\n  FL_SUPERLINK_IP = \"${superlink.template.context.eth0_ip}\"\n]"
}
```

**Syntax:** `${<parent_role_name>.<xpath>}` -- only works with `"deployment": "straight"` and declared parent relationship.

**Confidence:** HIGH -- documented in OpenNebula 7.0 OneFlow CLI reference.

## Contextualization Parameter Reference

### USER_INPUTS Format

OpenNebula USER_INPUTS follow this pipe-delimited format:
```
VARIABLE_NAME="M|type|Description|options|default"
```

Where:
- First field: `M` (mandatory) or `O` (optional)
- Second field: type (see below)
- Third field: human-readable description
- Fourth field: type-specific options (comma-separated for lists, min..max for ranges)
- Fifth field: default value

### Supported USER_INPUT Types

| Type | Description | Options Field | Example |
|------|-------------|---------------|---------|
| `text` | Free-form text | (unused) | `"O\|text\|Server address\|\|0.0.0.0:9092"` |
| `text64` | Base64-encoded text | (unused) | `"O\|text64\|Custom script"` |
| `password` | Masked password | (unused) | `"O\|password\|Auth token"` |
| `number` | Integer | (unused) | `"O\|number\|Training rounds\|\|3"` |
| `number-float` | Float | (unused) | `"O\|number-float\|Learning rate\|\|0.01"` |
| `range` | Integer range slider | `min..max` | `"O\|range\|Memory (MB)\|2048..65536\|8192"` |
| `range-float` | Float range slider | `min..max` | `"O\|range-float\|CPU\|0.5..16.0\|4.0"` |
| `list` | Single-select dropdown | `opt1,opt2,...` | `"O\|list\|Strategy\|FedAvg,FedProx\|FedAvg"` |
| `list-multiple` | Multi-select | `opt1,opt2,...` | `"O\|list-multiple\|Features\|tls,gpu"` |
| `boolean` | Yes/No toggle | (unused) | `"O\|boolean\|Enable GPU\|\|NO"` |
| `fixed` | Non-editable value | (unused) | `"M\|fixed\|\| \|superlink"` |

**Confidence:** HIGH -- verified from OpenNebula 7.0 VM Template reference documentation.

### Complete Contextualization Variable Table (Phase 1 Scope)

This table maps every Flower CLI flag to an OpenNebula USER_INPUT for the Phase 1 spec. TLS parameters are included as placeholders for Phase 2 but are not functional in Phase 1.

#### SuperLink Variables

| Context Variable | USER_INPUT Def | Flower CLI Flag | Default | Description |
|-----------------|----------------|-----------------|---------|-------------|
| `FLOWER_VERSION` | `O\|text\|Flower Docker image version tag\|\|1.25.0` | Docker image tag | `1.25.0` | Version of flwr/superlink to run |
| `FL_NUM_ROUNDS` | `O\|number\|Number of federated learning rounds\|\|3` | ServerApp config | `3` | How many FL rounds to execute |
| `FL_STRATEGY` | `O\|list\|Aggregation strategy\|FedAvg,FedProx,FedAdam\|FedAvg` | ServerApp config | `FedAvg` | Strategy for aggregating model updates |
| `FL_MIN_FIT_CLIENTS` | `O\|number\|Minimum clients for training round\|\|2` | ServerApp config | `2` | Min clients before starting a round |
| `FL_MIN_EVALUATE_CLIENTS` | `O\|number\|Minimum clients for evaluation\|\|2` | ServerApp config | `2` | Min clients for evaluation rounds |
| `FL_MIN_AVAILABLE_CLIENTS` | `O\|number\|Minimum available clients to start\|\|2` | ServerApp config | `2` | Min connected clients before any round |
| `FL_FLEET_API_ADDRESS` | `O\|text\|Fleet API listen address\|\|0.0.0.0:9092` | `--fleet-api-address` | `0.0.0.0:9092` | Address SuperLink listens on for SuperNodes |
| `FL_CONTROL_API_ADDRESS` | `O\|text\|Control API listen address\|\|0.0.0.0:9093` | `--control-api-address` | `0.0.0.0:9093` | Address for CLI management |
| `FL_ISOLATION` | `O\|list\|App execution isolation mode\|subprocess,process\|subprocess` | `--isolation` | `subprocess` | How ServerApp/ClientApp processes are managed |
| `FL_DATABASE` | `O\|text\|Database path for state persistence\|\|state/state.db` | `--database` | `state/state.db` | SQLite database for run history |
| `FL_LOG_LEVEL` | `O\|list\|Log verbosity\|DEBUG,INFO,WARNING,ERROR\|INFO` | `FLWR_LOG_LEVEL` env var | `INFO` | Flower logging level |

#### SuperNode Variables

| Context Variable | USER_INPUT Def | Flower CLI Flag | Default | Description |
|-----------------|----------------|-----------------|---------|-------------|
| `FLOWER_VERSION` | `O\|text\|Flower Docker image version tag\|\|1.25.0` | Docker image tag | `1.25.0` | Version of flwr/supernode to run |
| `FL_SUPERLINK_ADDRESS` | `O\|text\|SuperLink Fleet API address (host:port)\|\|` | `--superlink` | (empty -- triggers OneGate discovery) | Static SuperLink address; leave empty for OneGate discovery |
| `FL_NODE_CONFIG` | `O\|text\|Space-separated key=value node config\|\|` | `--node-config` | (empty) | Passed to ClientApp as config (e.g., "partition-id=0 num-partitions=2") |
| `FL_MAX_RETRIES` | `O\|number\|Max reconnection attempts (0=unlimited)\|\|0` | `--max-retries` | `0` (unlimited) | How many times to retry connecting to SuperLink |
| `FL_MAX_WAIT_TIME` | `O\|number\|Max wait time for connection (0=unlimited)\|\|0` | `--max-wait-time` | `0` (unlimited) | Timeout in seconds for connection attempts |
| `FL_ISOLATION` | `O\|list\|App execution isolation mode\|subprocess,process\|subprocess` | `--isolation` | `subprocess` | How ClientApp processes are managed |
| `FL_LOG_LEVEL` | `O\|list\|Log verbosity\|DEBUG,INFO,WARNING,ERROR\|INFO` | `FLWR_LOG_LEVEL` env var | `INFO` | Flower logging level |

#### Shared Infrastructure Variables (Both Appliances)

| Context Variable | USER_INPUT Def | Purpose | Default | Description |
|-----------------|----------------|---------|---------|-------------|
| `TOKEN` | (not user-facing) | OneGate auth | `YES` | Required for OneGate service discovery |
| `NETWORK` | (not user-facing) | Network config | `YES` | Required for IP configuration |
| `REPORT_READY` | (not user-facing) | Readiness report | `YES` | Reports VM readiness after Flower starts |
| `READY_SCRIPT_PATH` | (not user-facing) | Readiness probe | `/opt/flower/scripts/health-check.sh` | Script that validates Flower is healthy before reporting ready |
| `SSH_PUBLIC_KEY` | (from user) | SSH access | `$USER[SSH_PUBLIC_KEY]` | Standard OpenNebula SSH key injection |

#### Phase 2+ Placeholder Variables (Not Functional in Phase 1)

| Context Variable | USER_INPUT Def | Phase | Default | Description |
|-----------------|----------------|-------|---------|-------------|
| `FL_TLS_ENABLED` | `O\|boolean\|Enable TLS encryption\|\|NO` | Phase 2 | `NO` | Master switch for TLS |
| `FL_SSL_CA_CERTFILE` | `O\|text64\|CA certificate (base64 PEM)` | Phase 2 | (empty) | CA cert for TLS verification |
| `FL_SSL_CERTFILE` | `O\|text64\|Server certificate (base64 PEM)` | Phase 2 | (empty) | SuperLink server certificate |
| `FL_SSL_KEYFILE` | `O\|text64\|Server private key (base64 PEM)` | Phase 2 | (empty) | SuperLink private key |
| `FL_GPU_ENABLED` | `O\|boolean\|Enable NVIDIA GPU support\|\|NO` | Phase 6 | `NO` | GPU passthrough to container |
| `ML_FRAMEWORK` | `O\|list\|ML framework\|pytorch,tensorflow,sklearn\|pytorch` | Phase 3 | `pytorch` | Framework for client-side training |

### Naming Convention Rationale

- **`FLOWER_VERSION`**: Follows OpenNebula marketplace convention (PRODUCT_FIELD)
- **`FL_*`**: Flower-specific configuration prefix. Short, distinctive, unlikely to collide.
- **`FL_SUPERLINK_ADDRESS`**: Descriptive, matches Flower terminology
- **No underscores in values**: Only in variable names (OpenNebula convention)
- **Uppercase with underscores**: Standard OpenNebula CONTEXT variable style

### Validation Strategy

**Recommendation: Fail-fast with clear error messages.**

```bash
# In configure.sh:
validate_config() {
    local errors=0

    # Required for SuperNode: either static address or OneGate must be available
    if [ "$FL_ROLE" = "supernode" ]; then
        if [ -z "$FL_SUPERLINK_ADDRESS" ] && [ ! -f /run/one-context/token.txt ]; then
            log "ERROR: FL_SUPERLINK_ADDRESS not set and OneGate token not available"
            log "ERROR: SuperNode needs either a static SuperLink address or OneGate"
            errors=$((errors + 1))
        fi
    fi

    # Validate numeric values
    if [ -n "$FL_NUM_ROUNDS" ] && ! [[ "$FL_NUM_ROUNDS" =~ ^[0-9]+$ ]]; then
        log "ERROR: FL_NUM_ROUNDS must be a positive integer, got: $FL_NUM_ROUNDS"
        errors=$((errors + 1))
    fi

    # Validate strategy enum
    case "${FL_STRATEGY:-FedAvg}" in
        FedAvg|FedProx|FedAdam) ;;
        *) log "ERROR: Unknown strategy: $FL_STRATEGY"; errors=$((errors + 1)) ;;
    esac

    if [ $errors -gt 0 ]; then
        log "FATAL: $errors configuration errors. Aborting."
        exit 1
    fi
}
```

## Health Check Design

### Recommendation: Use Flower's Built-in gRPC Health Server

Both `flower-superlink` and `flower-supernode` support `--health-server-address` which starts a gRPC health check endpoint compatible with the standard gRPC health checking protocol.

**READY_SCRIPT for SuperLink:**
```bash
#!/bin/bash
# /opt/flower/scripts/health-check.sh
# Returns 0 if Flower SuperLink is accepting connections on port 9092
nc -z localhost 9092 2>/dev/null
```

**Alternative using gRPC health check (if `--health-server-address` is used):**
```bash
#!/bin/bash
# Requires grpc-health-probe binary
grpc_health_probe -addr=localhost:${HEALTH_PORT:-9094} 2>/dev/null
```

**Recommendation for Phase 1:** Use the simple TCP port check (`nc -z localhost 9092`) as the READY_SCRIPT. This is sufficient for determining that SuperLink is listening. The gRPC health check is more thorough but requires installing `grpc-health-probe` in the VM.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| TaskIns/TaskRes message API | Message API | Flower 1.22+ | All strategies and examples migrated. New code should use Message API. |
| CSV-based SuperNode authentication | CLI-managed dynamic registration | Flower 1.23 | Old CSV auth removed. Use `flwr supernode register/list/unregister`. |
| Python 3.9 support | Python 3.10+ required | Flower 1.24 | Docker images with py3.9 tags discontinued. |
| protobuf 4.x | protobuf 5.x required | Flower 1.24 | TensorFlow < 2.18 incompatible. |
| Bundled `flwr new` templates | Platform-fetched templates | Flower 1.25 | `--framework` and `--username` flags deprecated. |
| gRPC metadata keys with underscores | Hyphens in metadata keys | Flower 1.23+ | Fixes load balancer header stripping. |
| Exec API | Control API (port 9093) | Flower 1.21 | API renamed. CLI uses Control API. |

**Deprecated/outdated:**
- `--insecure` flag: Still works but considered development-only. Phase 1 uses it; Phase 2 removes it.
- `flwr.server.utils.tensorboard`: Deprecated in 1.24 due to slow imports.
- Flower versions < 1.20: Missing SuperExec, message chunking, modern deployment patterns.

## Open Questions

Things that could not be fully resolved during research:

1. **REPORT_READY + OneFlow interaction**
   - What we know: `REPORT_READY=YES` reports VM readiness to OneGate. OneFlow "straight" deployment waits for parent roles to be RUNNING.
   - What is unclear: Does OneFlow wait for REPORT_READY to mark a role as "ready for children" or just the VM RUNNING state? If OneFlow only checks VM state (not REPORT_READY), the SuperNode role may start deploying before the SuperLink container is healthy.
   - Recommendation: Spec should document both behaviors and rely on the SuperNode's retry loop as defense-in-depth regardless.
   - **Confidence:** LOW -- this specific interaction needs testing.

2. **OneGate GET /service response format for USER_TEMPLATE attributes**
   - What we know: OneGate PUT adds attributes to VM USER_TEMPLATE. GET /service returns full service JSON with roles and nodes.
   - What is unclear: The exact JSON path to access a specific VM's USER_TEMPLATE attributes from the service response. The jq path `...vm_info.VM.USER_TEMPLATE.FL_ENDPOINT` is based on documentation examples but may differ in practice.
   - Recommendation: Validate the exact JSON structure during implementation. Spec should provide the expected structure and note it needs validation.
   - **Confidence:** MEDIUM -- based on OpenNebula 6.6-7.0 OneGate docs.

3. **Flower `--health-server-address` flag behavior**
   - What we know: Both SuperLink and SuperNode CLI accept `--health-server-address` flag.
   - What is unclear: What port it defaults to, what protocol it uses (gRPC health or HTTP), and whether it is stable or experimental.
   - Recommendation: For Phase 1, use simple TCP port check instead. Document the health server flag for future phases.
   - **Confidence:** LOW -- flag exists in CLI reference but documentation is sparse.

4. **Pre-baked Docker image size impact on QCOW2**
   - What we know: flwr/superlink compressed is ~190MB. Ubuntu 24.04 base + Docker CE is ~1.5GB. Total QCOW2 with pre-pulled image should be ~2GB.
   - What is unclear: Exact QCOW2 size after thin provisioning and compression. Whether marketplace delivery has practical size limits.
   - Recommendation: Set soft target of 3GB for Phase 1 appliance image. Measure during implementation.
   - **Confidence:** MEDIUM -- based on component sizes, not measured.

5. **OneFlow `${parent.template.context.eth0_ip}` availability timing**
   - What we know: OneFlow supports `${<PARENT_ROLE_NAME>.<XPATH>}` syntax for referencing parent role attributes.
   - What is unclear: Whether `eth0_ip` is available in the parent's template at service instantiation time, or only after the parent VM has booted and acquired its IP. If it is not available at instantiation, child roles would get empty values.
   - Recommendation: Use OneGate discovery as the primary mechanism. The OneFlow attribute reference is a useful shortcut but may not be reliable for dynamic values like IP addresses.
   - **Confidence:** LOW -- the docs say it works but the timing of IP assignment vs. template population is unclear.

## Sources

### Primary (HIGH confidence)
- Flower Docker Quickstart: https://flower.ai/docs/framework/docker/tutorial-quickstart-docker.html
- Flower Docker TLS: https://flower.ai/docs/framework/docker/enable-tls.html
- Flower Docker Subprocess Mode: https://flower.ai/docs/framework/docker/run-as-subprocess.html
- Flower CLI Reference: https://flower.ai/docs/framework/ref-api-cli.html
- Flower Docker Environment Variables: https://flower.ai/docs/framework/docker/set-environment-variables.html
- Flower Network Communication: https://flower.ai/docs/framework/ref-flower-network-communication.html
- Flower Changelog: https://flower.ai/docs/framework/ref-changelog.html
- OpenNebula 7.0 VM Template Reference (USER_INPUTS): https://docs.opennebula.io/7.0/product/operation_references/configuration_references/template/
- OpenNebula 7.0 OneFlow CLI: https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/
- OpenNebula 7.0 Contextualization: https://docs.opennebula.io/7.0/product/virtual_machines_operation/guest_operating_systems/kvm_contextualization/
- OpenNebula one-apps Linux Features: https://github.com/OpenNebula/one-apps/wiki/linux_feature
- OpenNebula OneGate API: https://docs.opennebula.io/6.10/integration_and_development/system_interfaces/onegate_api.html
- OpenNebula OneGate Usage: https://docs.opennebula.io/6.6/management_and_operations/multivm_service_management/onegate_usage.html

### Secondary (MEDIUM confidence)
- Flower Docker Compose reference: https://github.com/adap/flower/blob/main/framework/docker/complete/compose.yml
- Flower Docker Hub (flwr/superlink): https://hub.docker.com/r/flwr/superlink
- OpenNebula one-apps repository: https://github.com/OpenNebula/one-apps/
- Prior roadmap research: `.planning/research/STACK.md`, `.planning/research/ARCHITECTURE.md`, `.planning/research/PITFALLS.md`

### Tertiary (LOW confidence)
- OneFlow parent attribute reference timing behavior (documented but untested for dynamic IPs)
- REPORT_READY interaction with OneFlow role dependency ordering (needs validation)
- Flower `--health-server-address` behavior details (flag exists but docs are sparse)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- Flower Docker images and OpenNebula are well-documented
- Architecture patterns: MEDIUM -- Docker-in-VM and OneGate patterns are sound but the specific integration is novel
- Contextualization mapping: HIGH -- Flower CLI flags are fully documented, USER_INPUTS format is verified
- Boot sequence: MEDIUM -- individual steps are verified, end-to-end interaction needs validation
- Pitfalls: HIGH -- based on official docs and prior roadmap research

**Research date:** 2026-02-05
**Valid until:** 2026-03-07 (30 days -- Flower releases monthly, next release may change flags)
