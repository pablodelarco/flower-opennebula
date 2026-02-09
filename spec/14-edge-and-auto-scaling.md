# Edge and Auto-Scaling

**Requirement:** ORCH-03, EDGE-01
**Phase:** 09 - Edge and Auto-Scaling
**Status:** Specification

---

## 1. Purpose and Scope

This section defines the edge-optimized SuperNode appliance variant and OneFlow auto-scaling (elasticity policies) for the Flower-OpenNebula integration. It addresses two requirements: EDGE-01 (edge SuperNode appliance for constrained environments) and ORCH-03 (dynamic SuperNode scaling during active training via OneFlow elasticity rules).

**What this section covers:**
- Edge SuperNode appliance variant: reduced QCOW2 image targeting under 2 GB, Ubuntu 24.04 Minimal base, base Flower image only (no ML framework pre-baked).
- Intermittent connectivity handling: three-layer resilience model with configurable backoff for edge discovery retry.
- Edge deployment considerations: data provisioning, partition-ID stability, bandwidth constraints.
- OneFlow elasticity policies: expression-based auto-scaling triggers on the SuperNode role.
- Custom FL metrics published via OneGate for FL-aware scaling decisions.
- Client join/leave semantics during auto-scaling and edge disconnect events.
- Anti-patterns for edge and auto-scaling deployments.
- Two new contextualization variables for edge backoff configuration.

**What this section does NOT cover:**
- Standard SuperNode appliance design (see [`spec/02-supernode-appliance.md`](02-supernode-appliance.md) -- Phase 1).
- Single-site OneFlow service template and deployment sequencing (see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md) -- Phase 4).
- Multi-site federation networking and TLS trust distribution (see [`spec/12-multi-site-federation.md`](12-multi-site-federation.md) -- Phase 7).
- Monitoring and observability stack (see [`spec/13-monitoring-observability.md`](13-monitoring-observability.md) -- Phase 8).

**Cross-references:**
- SuperNode appliance: [`spec/02-supernode-appliance.md`](02-supernode-appliance.md) -- standard SuperNode design, boot sequence, image components, discovery model.
- Single-site orchestration: [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md) -- OneFlow service template, cardinality config, elasticity policies preview, scaling operations.
- Multi-site federation: [`spec/12-multi-site-federation.md`](12-multi-site-federation.md) -- cross-zone deployment topology, training site template variant (edge as remote training site).
- Contextualization reference: [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) -- complete variable definitions including new Phase 9 variables.
- Monitoring and observability: [`spec/13-monitoring-observability.md`](13-monitoring-observability.md) -- JSON logging, metrics exporter, DCGM sidecar.

---

## 2. Edge SuperNode Appliance Variant

The edge SuperNode is a stripped-down variant of the standard SuperNode appliance, targeting deployment in bandwidth-constrained, resource-limited, and intermittently connected edge environments. It shares the same architecture (Docker-in-VM, contextualization-driven, immutable appliance model) but reduces the QCOW2 image footprint to under 2 GB by using Ubuntu Minimal and the base Flower Docker image without any pre-baked ML framework.

**Marketplace identifier:** `Flower SuperNode - Edge` (separate QCOW2 alongside the framework-specific variants: PyTorch, TensorFlow, scikit-learn).

### 2.1 Differences: Standard SuperNode vs Edge SuperNode

| Aspect | Standard SuperNode | Edge SuperNode |
|--------|-------------------|----------------|
| Base OS | Ubuntu 24.04 LTS (full server, ~800 MB) | Ubuntu 24.04 Minimal Cloud Image (~300-400 MB) |
| Pre-baked Docker image | Framework-specific: `flower-supernode-pytorch:1.25.0` (~1.2 GB), `flower-supernode-tensorflow:1.25.0` (~700 MB), `flower-supernode-sklearn:1.25.0` (~400 MB) | Base only: `flwr/supernode:1.25.0` (~190 MB) |
| ML framework | Pre-installed in Docker image (PyTorch, TensorFlow, or scikit-learn) | None pre-installed. User provides via custom Docker image or `FL_ISOLATION=process` |
| Target QCOW2 size | 2.5-5 GB (depending on framework variant) | Under 2 GB (estimated 1.0-1.5 GB) |
| Recommended VM resources | 4 vCPU, 8 GB RAM, 40 GB disk | 2 vCPU, 2-4 GB RAM, 10-20 GB disk |
| Network dependency at boot | Pre-baked (network-free boot) | Pre-baked (network-free boot -- even more critical at edge) |
| Connectivity model | Persistent LAN/WAN | Intermittent, bandwidth-constrained |
| Discovery retry configuration | Default: 30 retries, 10s fixed interval, 5 min timeout | Enhanced: configurable backoff strategy (exponential or fixed), configurable max backoff interval |
| GPU support | Full GPU passthrough when `FL_GPU_ENABLED=YES` | Not recommended (resource-constrained); `FL_GPU_ENABLED` defaults to `NO` |
| DCGM metrics sidecar | Optional (`FL_DCGM_ENABLED=YES`) | Not applicable (no GPU) |

### 2.2 Image Components

The edge SuperNode QCOW2 image SHALL contain the following pre-installed components:

| Component | Version / Constraint | Purpose |
|-----------|---------------------|---------|
| Ubuntu 24.04 Minimal Cloud Image | 24.04 | Reduced-footprint base OS. Official Ubuntu minimal images strip server packages, desktop tools, and documentation. |
| Docker CE | 24+ (minimum, not pinned) | Container runtime for the Flower SuperNode container. |
| `flwr/supernode:1.25.0` | 1.25.0 (pre-pulled) | Flower federated learning client. Base image with Python 3.13 and Flower runtime only -- NO ML framework libraries. |
| OpenNebula one-apps contextualization | latest | Guest agent providing networking, SSH key injection, CONTEXT variable export, `REPORT_READY` signaling. |
| jq | any | JSON parsing for OneGate API response processing during SuperLink discovery. |
| curl | any | HTTP client for OneGate API calls during discovery and status publication. |
| netcat (nc) | any | TCP connectivity checks used by health-check and OneGate pre-check scripts. |
| Custom scripts | -- | `/opt/flower/scripts/` -- configure.sh, bootstrap.sh, discover.sh, health-check.sh, common.sh |

**What is NOT included (compared to standard SuperNode):**
- No ML framework Docker images (PyTorch, TensorFlow, scikit-learn).
- No DCGM Exporter image (no GPU support expected at edge).
- No framework-specific Python packages in the base image.

### 2.3 Image Size Breakdown

| Component | Standard (PyTorch variant) | Edge |
|-----------|---------------------------|------|
| Ubuntu base OS | ~800 MB (full server) | ~300-400 MB (minimal) |
| Docker CE + runtime | ~400 MB | ~400 MB |
| Flower base image | ~190 MB | ~190 MB |
| Framework Docker image layers | ~800 MB - 1.2 GB (PyTorch + LLM deps) | 0 (not pre-baked) |
| Utilities (jq, curl, nc) | ~5 MB | ~5 MB |
| one-apps contextualization | ~10 MB | ~10 MB |
| **Total QCOW2 (estimated)** | **~2.5 - 5 GB** | **~1.0 - 1.5 GB** |

**Size target:** Under 2 GB. The estimated 1.0-1.5 GB provides a comfortable margin. If the actual built image exceeds 2 GB, optimization strategies include: aggressive `apt-get clean && rm -rf /var/lib/apt/lists/*`, `docker system prune -a`, zeroing free blocks before QCOW2 compression (`dd if=/dev/zero of=/zero.fill; rm /zero.fill`), and reviewing Ubuntu Minimal package set for unnecessary components.

### 2.4 Build Optimization

The edge QCOW2 build process follows the same pipeline as the standard SuperNode but with additional size reduction steps:

1. Start from Ubuntu 24.04 Minimal Cloud Image (NOT standard server).
2. Install Docker CE from official Docker repository.
3. Install one-apps contextualization packages.
4. Install utilities: `apt-get install -y --no-install-recommends jq curl netcat-openbsd`.
5. Pre-pull base Flower image: `docker pull flwr/supernode:1.25.0`.
6. Install custom scripts to `/opt/flower/scripts/`.
7. Clean up: `apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*`.
8. Docker cleanup: `docker system prune -a -f` (remove build cache, dangling layers).
9. Zero free blocks: `dd if=/dev/zero of=/zero.fill bs=1M; rm /zero.fill`.
10. Export as compressed QCOW2: `qemu-img convert -c -O qcow2`.

### 2.5 Pre-baked Image Strategy

The edge SuperNode follows the same pre-baked image strategy as the standard SuperNode (see [`spec/02-supernode-appliance.md`](02-supernode-appliance.md), Section 4): the Docker image is pre-pulled during image build so the appliance can boot without network access. This is even more critical at edge, where network connectivity may be unreliable or bandwidth-constrained.

**Version override mechanism:** Same as standard SuperNode. If `FLOWER_VERSION` differs from the pre-baked `1.25.0`, the bootstrap script attempts to pull the requested version and falls back to the pre-baked version on failure.

### 2.6 Framework Provisioning at Edge

Without a pre-baked ML framework, the edge SuperNode supports two framework provisioning approaches:

1. **Custom Docker image via `FL_ISOLATION=process`:** The operator provides a custom Docker image containing the ML framework and ClientApp code. The SuperNode runs the base `flwr/supernode` container which spawns the ClientApp in a separate container from the custom image. This is the recommended approach for edge deployments with specific framework requirements.

2. **Runtime pull (if network available):** If the edge environment has network connectivity (even intermittent), the operator can configure a `START_SCRIPT` that pulls a framework-specific image at boot. This approach depends on network availability and is not recommended for air-gapped edge sites.

### 2.7 Ubuntu Minimal Compatibility Note

**Implementation validation item:** The Ubuntu 24.04 Minimal Cloud Image may lack packages that one-apps contextualization assumes are present. The one-apps contextualization packages target Ubuntu 24.04 LTS (standard server). Minimal images strip many server packages (e.g., `systemd-networkd` may replace `netplan`, some `util-linux` tools may be absent).

If one-apps contextualization does not install cleanly on Ubuntu Minimal, the fallback approach is to use the standard Ubuntu 24.04 server image with aggressive package removal to approach the under-2 GB target. In this fallback scenario, the QCOW2 size may be 1.5-2.0 GB (still within target) rather than the optimistic 1.0-1.5 GB estimate.

---

## 3. Intermittent Connectivity Handling

Edge environments face unreliable network connectivity: links may drop for minutes or hours, bandwidth may be constrained (metered cellular, satellite), and latency may be high. The Flower-OpenNebula integration handles intermittent connectivity through a three-layer resilience model.

### 3.1 Three-Layer Resilience Model

| Layer | Mechanism | Scope | Phase |
|-------|-----------|-------|-------|
| 1. Flower-native reconnection | `--max-retries 0` (unlimited), `--max-wait-time 0` (unlimited) | gRPC connection between SuperNode and SuperLink | Phase 1 (already specified) |
| 2. OneGate discovery retry | 30 retries, 10s interval, 5 min timeout | Discovery of SuperLink address during boot | Phase 1 (already specified) |
| 3. Edge-specific enhancements | Configurable backoff strategy, bounded retry windows | Discovery retry loop for edge environments | Phase 9 (NEW) |

**Layer 1: Flower-native reconnection** (already specified in Phase 1)

Once the SuperNode container is running and connected to the SuperLink, all reconnection is delegated to Flower's built-in gRPC reconnection logic. With `--max-retries 0` (unlimited) and `--max-wait-time 0` (unlimited), the SuperNode retries indefinitely with gRPC's internal exponential backoff. This handles:
- SuperLink restarts.
- Transient network failures during training.
- WAN link interruptions between training rounds.

No additional edge-specific configuration is needed for Layer 1. Flower's native reconnection is the primary resilience mechanism.

**Layer 2: OneGate discovery retry** (already specified in Phase 1)

During boot, the SuperNode discovers the SuperLink address via OneGate. The retry loop (30 retries, 10s fixed interval, 5 min timeout) handles the timing gap between SuperNode boot and SuperLink readiness. In standard deployments with `ready_status_gate: true`, discovery typically succeeds on the first attempt.

**Layer 3: Edge-specific enhancements** (NEW in Phase 9)

For edge deployments where the SuperNode may boot before network connectivity is established, or where OneGate may be intermittently reachable, the discovery retry loop is enhanced with configurable backoff.

**Important distinction:** The edge backoff configuration (Layer 3) applies ONLY to the discovery retry loop (OneGate layer, during boot). It does NOT affect Flower's native reconnection (Layer 1). Once the SuperNode connects to the SuperLink, all subsequent disconnects and reconnections are handled by Flower's gRPC layer with its own internal backoff.

### 3.2 Edge Backoff Configuration

Two new contextualization variables control the edge discovery retry behavior:

| Variable | USER_INPUT Definition | Default | Description |
|----------|----------------------|---------|-------------|
| `FL_EDGE_BACKOFF` | `O\|list\|Edge discovery retry backoff strategy\|exponential,fixed\|exponential` | `exponential` | Strategy for spacing discovery retry attempts. `exponential`: starts at 10s, doubles each attempt, caps at `FL_EDGE_MAX_BACKOFF`. `fixed`: uses the standard 10s interval (Phase 1 behavior). |
| `FL_EDGE_MAX_BACKOFF` | `O\|number\|Maximum backoff interval in seconds for edge discovery\|\|300` | `300` | Upper bound on the backoff interval in seconds. Only effective when `FL_EDGE_BACKOFF=exponential`. |

### 3.3 Backoff Behavior Specification

**Exponential backoff** (default for edge):

```
Attempt 1:  wait 10s    (base interval)
Attempt 2:  wait 20s    (10 * 2^1)
Attempt 3:  wait 40s    (10 * 2^2)
Attempt 4:  wait 80s    (10 * 2^3)
Attempt 5:  wait 160s   (10 * 2^4)
Attempt 6:  wait 300s   (capped at FL_EDGE_MAX_BACKOFF=300)
Attempt 7:  wait 300s   (capped)
Attempt 8:  wait 300s   (capped)
...
```

The exponential backoff starts at 10 seconds (the same base interval as the fixed strategy), doubles each attempt, and caps at `FL_EDGE_MAX_BACKOFF` (default: 300 seconds = 5 minutes). There is no maximum retry count in exponential mode -- the SuperNode retries indefinitely until it discovers the SuperLink or the VM is shut down.

**Rationale for unlimited retries in exponential mode:** In edge environments, the SuperLink may be minutes or hours away from becoming reachable (WAN link restoration, VPN tunnel re-establishment). Capping retries would cause the SuperNode to give up and require manual intervention. With exponential backoff capped at 5 minutes, the SuperNode makes at most 12 attempts per hour -- negligible load on OneGate.

**Fixed backoff** (Phase 1 behavior):

```
Attempt 1-30: wait 10s each (300s total, then fail)
```

Fixed backoff preserves the Phase 1 behavior exactly: 30 retries at 10-second intervals, 5-minute total timeout, then boot failure. This is appropriate for standard (non-edge) deployments where discovery should succeed quickly or not at all.

### 3.4 Discovery Retry Pseudocode (Edge-Enhanced)

```bash
# Edge-enhanced discovery retry loop
# Replaces Phase 1 fixed-interval loop when FL_EDGE_BACKOFF=exponential

BACKOFF_STRATEGY="${FL_EDGE_BACKOFF:-exponential}"
MAX_BACKOFF="${FL_EDGE_MAX_BACKOFF:-300}"
BASE_INTERVAL=10
attempt=0

while true; do
    attempt=$((attempt + 1))

    # Query OneGate
    FL_ENDPOINT=$(query_onegate_for_superlink)

    if [ -n "$FL_ENDPOINT" ]; then
        log "INFO" "Discovered SuperLink at ${FL_ENDPOINT} (attempt ${attempt})"
        break  # Success
    fi

    if [ "$BACKOFF_STRATEGY" = "fixed" ]; then
        if [ "$attempt" -ge 30 ]; then
            log "ERROR" "SuperLink discovery timed out after 30 attempts (5 minutes)"
            exit 1
        fi
        SLEEP_TIME=$BASE_INTERVAL
    else
        # Exponential backoff: 10, 20, 40, 80, 160, 300, 300, ...
        SLEEP_TIME=$((BASE_INTERVAL * (2 ** (attempt - 1))))
        if [ "$SLEEP_TIME" -gt "$MAX_BACKOFF" ]; then
            SLEEP_TIME=$MAX_BACKOFF
        fi
    fi

    log "INFO" "SuperLink not found, retrying in ${SLEEP_TIME}s (attempt ${attempt}, strategy=${BACKOFF_STRATEGY})"
    sleep "$SLEEP_TIME"
done
```

### 3.5 Client Disconnect Mid-Round Behavior

The following table documents what happens when a SuperNode disconnects during various phases of a training round. These behaviors are Flower-native and apply to both standard and edge SuperNodes.

| # | Event | Flower Server Behavior | Impact on Training |
|---|-------|----------------------|-------------------|
| 1 | Client disconnects during `fit()` execution | Server records the failure in the `failures` list returned by `aggregate_fit()` | Round proceeds if `accept_failures=True` (default) and enough results are returned. Failed client's data is not represented in this round's aggregation. |
| 2 | Client disconnects before `fit()` is assigned | Client is not sampled for this round; server selects different available clients | No impact on current round. Client is simply not selected. |
| 3 | All sampled clients disconnect during a round | `aggregate_fit()` receives zero results; returns `None` | Global model remains unchanged. Round is effectively skipped. Next round is attempted with whatever clients are available. |
| 4 | Client reconnects between rounds | Client re-registers with SuperLink and becomes available for next round's sampling | Transparent to training. The reconnected client participates in the next round as if it had always been available. |
| 5 | Available clients drop below `min_available_clients` | SuperLink waits before starting the next round | Training pauses until enough clients reconnect or new clients join. No data loss. |
| 6 | Available clients drop below `min_fit_clients` during active round | Round proceeds with available results if `accept_failures=True` | Reduced data diversity for this round. If zero results, round is skipped (same as scenario 3). |

### 3.6 Partial Participation Tolerance

For edge deployments where client dropout is expected, the aggregation strategy should tolerate partial participation:

- **`accept_failures=True`** (FedAvg default): The server proceeds with aggregation even when some clients fail to report results. This is the default for all strategies and is sufficient for most edge deployments.

- **`FaultTolerantFedAvg`** (recommended for edge): A strategy variant that explicitly defines minimum completion rates. Recommended configuration for edge:
  - `min_completion_rate_fit=0.5` -- training round proceeds if at least 50% of sampled clients report.
  - `min_completion_rate_evaluate=0.5` -- evaluation round proceeds with 50% completion.

- **`min_available_clients` interaction:** Set `FL_MIN_AVAILABLE_CLIENTS` below the expected node count in edge deployments. If all N edge nodes must be available for training to start, any single node failure blocks the entire training pipeline. Setting `FL_MIN_AVAILABLE_CLIENTS` to `ceil(N * 0.5)` allows training to proceed with 50% availability.

### 3.7 Reconnection Between Rounds

When a disconnected edge SuperNode reconnects between training rounds, the process is transparent to training:

1. The SuperNode's Flower client runtime re-establishes the gRPC connection to the SuperLink (via `--max-retries 0`).
2. The SuperLink re-registers the SuperNode as an available client.
3. On the next training round, the SuperLink samples from all currently available clients, including the reconnected one.
4. The reconnected client trains on its local data with the current global model (which may have advanced several rounds during the disconnection).
5. No special handling is needed -- Flower treats reconnection as a normal client join event.

---

## 4. Edge Deployment Considerations

### 4.1 Data Provisioning at Edge

Edge environments typically cannot rely on runtime data downloads (bandwidth constraints, intermittent connectivity). Data provisioning strategies for edge SuperNodes:

| Strategy | When to Use | Configuration |
|----------|-------------|---------------|
| **Pre-loaded in QCOW2** | Demo, PoC, static datasets | Include training data in `/opt/flower/data` during image build. Increases QCOW2 size. |
| **Provisioned via `START_SCRIPT`** | Datasets available on local storage (NFS, USB, SAN) | Set `START_SCRIPT` CONTEXT variable to a script that copies/mounts data to `/opt/flower/data`. |
| **Pre-provisioned via SSH** | One-time data setup before training | SSH into the edge VM and place data in `/opt/flower/data` with correct ownership (`chown -R 49999:49999`). |
| **Runtime download** | NOT recommended for edge | Avoid relying on `flwr-datasets` or HTTP downloads at edge. Network may not be available when the ClientApp needs data. |

**Key constraint:** Data must be available at `/opt/flower/data` (host path, mounted as `/app/data:ro` in the container) BEFORE the first training round begins. If data is not present, the ClientApp will fail when attempting to load the dataset.

### 4.2 Partition-ID Stability Warning

**Pitfall:** In edge deployments with expected node churn, the auto-computed `partition-id` (from OneGate VM index, see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 5) may become unreliable.

**Why:** The auto-computed `partition-id` is a boot-time value derived from the VM's index in the OneGate `nodes` array. If VMs are added or removed while an edge node is disconnected, the array indices shift. When the edge node reconnects, its original `partition-id` may now correspond to a different data shard, or another VM may have been assigned the same `partition-id`.

**Recommendation:** For edge deployments with expected churn, use explicit `FL_NODE_CONFIG` with operator-managed partition assignments rather than auto-computed values:

```
FL_NODE_CONFIG = "partition-id=3 num-partitions=8"
```

Alternatively, implement ClientApps that handle data sharding internally (e.g., by VMID hash or a deterministic function of the node's unique identity) rather than relying on sequential `partition-id` values.

### 4.3 Edge VM Template (Conceptual)

A reduced-resource VM template for edge SuperNode deployment:

```
# Edge SuperNode VM Template
CPU = "2"
VCPU = "2"
MEMORY = "2048"

DISK = [
  IMAGE = "Flower SuperNode - Edge",
  SIZE = "10240"
]

NIC = [
  NETWORK = "<edge-network>",
  MODEL = "virtio"
]

CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  READY_SCRIPT_PATH = "/opt/flower/scripts/health-check.sh",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
  FL_SUPERLINK_ADDRESS = "10.10.9.0:9092",
  FL_MAX_RETRIES = "0",
  FL_EDGE_BACKOFF = "exponential",
  FL_EDGE_MAX_BACKOFF = "300",
  FL_NODE_CONFIG = "partition-id=0 num-partitions=4"
]
```

**Notes:**
- `FL_SUPERLINK_ADDRESS` is mandatory for edge deployments (edge nodes are typically in remote locations without local OneGate access to the coordinator zone).
- `FL_NODE_CONFIG` is explicitly set (not auto-computed) to ensure partition stability across disconnections.
- `FL_EDGE_BACKOFF=exponential` enables unlimited retries with exponential backoff for intermittent connectivity.
- 2 vCPU and 2 GB RAM is the minimum recommended for the base Flower image. Increase for heavier ClientApp workloads.
- 10 GB disk is sufficient for the under-2 GB QCOW2 plus training data and container runtime.

### 4.4 Network Requirements

The edge SuperNode has the same network requirements as the standard SuperNode, with emphasis on firewall and bandwidth considerations:

| Requirement | Detail |
|-------------|--------|
| Outbound TCP to SuperLink | Port 9092 (Fleet API). This is the ONLY required network path. |
| OneGate connectivity | Optional. Required only if using dynamic discovery (not recommended for edge). |
| Inbound ports | None. The SuperNode makes outbound-only connections. |
| TLS | Recommended for WAN/public network paths. Set `FL_TLS_ENABLED=YES` and provide `FL_SSL_CA_CERTFILE`. |
| gRPC keepalive | Recommended: `FL_GRPC_KEEPALIVE_TIME=60` for connections through firewalls with idle timeouts. |

### 4.5 Bandwidth Considerations

Flower federated learning transmits model updates (weights/gradients) between SuperNodes and SuperLink. The bandwidth impact depends on model size:

| Model Type | Approximate Update Size | Per-Round Transfer (bidirectional) |
|-----------|------------------------|-----------------------------------|
| Small CNN (CIFAR-10) | ~1-5 MB | ~2-10 MB |
| ResNet-50 | ~100 MB | ~200 MB |
| BERT-base | ~440 MB | ~880 MB |
| LLM (7B params, LoRA adapters) | ~10-50 MB (adapter weights only) | ~20-100 MB |

**Mitigation for metered connections:**
- Use smaller models or parameter-efficient fine-tuning (LoRA/QLoRA) to reduce update sizes.
- Increase `FL_NUM_ROUNDS` with fewer clients per round (more rounds, less data per round).
- gRPC uses HTTP/2 which includes header compression. Flower does not currently support model compression (quantization, sparsification) at the framework level -- this would be a custom ClientApp optimization.

---

## 5. Decision Records

### DR-01: Ubuntu Minimal Over Alpine for Edge Base OS

**Decision:** Use Ubuntu 24.04 Minimal Cloud Image as the edge SuperNode base OS instead of Alpine Linux.

**Context:** Alpine Linux produces significantly smaller images (50-200 MB for a QCOW2) compared to Ubuntu Minimal (300-400 MB). However, the entire Flower-OpenNebula appliance stack is built on Ubuntu 24.04.

**Rationale:**
- **one-apps compatibility:** OpenNebula's one-apps contextualization packages target Ubuntu LTS. Alpine compatibility is unverified and would require additional validation.
- **Docker ecosystem:** The Flower Docker images use Ubuntu-based base images (`python:3.13-ubuntu24.04`). Running Alpine host + Ubuntu containers works but eliminates any shared-library benefit.
- **Consistency:** All other appliance variants (SuperLink, framework-specific SuperNodes) use Ubuntu 24.04. A different base OS for edge creates an additional maintenance burden and divergent behavior patterns.
- **Size difference is manageable:** Ubuntu Minimal at ~300-400 MB vs Alpine at ~50-200 MB saves 100-350 MB. The edge QCOW2 target (under 2 GB) is achievable with Ubuntu Minimal.

**Alternatives considered:** Alpine Linux (~50-200 MB QCOW2), Debian Minimal (~250-350 MB). Both rejected for consistency and compatibility reasons.

### DR-02: Base Flower Image Only, No Framework Pre-baked

**Decision:** The edge SuperNode QCOW2 ships with only the base `flwr/supernode:1.25.0` Docker image. No ML framework (PyTorch, TensorFlow, scikit-learn) is pre-installed.

**Context:** The standard SuperNode variants pre-bake framework-specific Docker images (PyTorch variant is ~4-5 GB total QCOW2). The edge target is under 2 GB.

**Rationale:**
- **Size target:** Including any framework image pushes the QCOW2 well above 2 GB. Even scikit-learn (~400 MB image) would make the target marginal.
- **Framework flexibility:** Edge deployments may use diverse ML frameworks or custom-built ClientApps. Not pre-baking a framework allows operators to bring their own via `FL_ISOLATION=process`.
- **Network-free boot preserved:** The base `flwr/supernode:1.25.0` image (~190 MB) is pre-baked, ensuring the SuperNode container can start without network access. Only the ClientApp framework needs provisioning.

**Trade-off:** Operators must provide their own ML framework either through a custom Docker image or a `START_SCRIPT` that installs it at boot. This is additional configuration compared to the standard variants.

### DR-03: Exponential Backoff as Default Over Fixed

**Decision:** The edge SuperNode uses exponential backoff (starting at 10s, doubling, capped at 300s) as the default discovery retry strategy, rather than the fixed 10s interval used in standard deployments.

**Context:** Standard SuperNodes use a fixed 10s interval for 30 retries (5-minute window). Edge environments may need to wait much longer for network connectivity.

**Rationale:**
- **WAN friendliness:** Exponential backoff reduces OneGate query frequency as the wait time increases, from one query every 10s to one every 5 minutes at cap. This is important for metered or bandwidth-constrained edge links.
- **Unlimited retries:** Unlike the fixed strategy (which fails after 30 attempts), exponential mode retries indefinitely. Edge nodes should not give up on discovery because network restoration may take hours.
- **Fast initial discovery:** The exponential strategy starts at 10s (same as fixed), so discovery in a healthy environment is equally fast. The backoff only activates when repeated attempts fail.

**Alternative:** Fixed interval with an increased retry count (e.g., 360 retries for 1 hour). Rejected because it generates excessive OneGate traffic during extended outages.

### DR-04: FaultTolerantFedAvg Recommended for Edge Deployments

**Decision:** Recommend `FaultTolerantFedAvg` with `min_completion_rate_fit=0.5` as the aggregation strategy for edge deployments, rather than default `FedAvg`.

**Context:** Edge environments have higher client dropout rates than LAN-connected deployments. Default `FedAvg` with `accept_failures=True` tolerates failures but has no explicit minimum completion rate.

**Rationale:**
- **Explicit tolerance:** `FaultTolerantFedAvg` provides configurable completion rate thresholds. With `min_completion_rate_fit=0.5`, training rounds proceed as long as at least 50% of sampled clients report results.
- **Predictable behavior:** The 50% threshold provides a clear contract: the operator knows that rounds will succeed with at least half the clients reporting. With default `FedAvg`, the behavior depends on the number of successful results vs `min_fit_clients`.
- **No FL framework change required:** `FaultTolerantFedAvg` is a built-in Flower strategy (not a custom implementation). It can be selected via `FL_STRATEGY` contextualization variable.

**Note:** `FaultTolerantFedAvg` is a recommendation, not a requirement. Operators can use any supported strategy. The edge appliance does not enforce a specific strategy.

---

## 6. OneFlow Auto-Scaling Architecture

### 6.1 Overview

OneFlow's elasticity engine provides automatic scaling of role cardinality based on expression-based triggers. Auto-scaling applies ONLY to the SuperNode role. The SuperLink role is a hard singleton (`min_vms=1, max_vms=1`) and MUST NOT have elasticity policies (see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 4).

Auto-scaling dynamically adjusts the number of SuperNode VMs during training in response to load conditions or FL-specific metrics. This enables:
- Scaling up when training rounds are CPU-bound (adding more clients for data parallelism).
- Scaling down during idle periods to release resources.
- Scheduled scaling for predictable workload patterns (e.g., business-hours training).

### 6.2 How OneFlow Evaluates Expressions

OneFlow evaluates elasticity policy expressions periodically according to the following process:

1. **Evaluation interval:** OneFlow evaluates each expression every `period` seconds (configurable per policy).
2. **Attribute averaging:** For each attribute referenced in the expression, OneFlow calculates the **average value across all running VMs** in the role. This is not per-VM evaluation -- it is a role-wide aggregate.
3. **Attribute lookup order:** OneFlow looks up each attribute in this priority order:
   - `/VM/USER_TEMPLATE` -- user-defined attributes (including custom metrics published via OneGate PUT)
   - `/VM/MONITORING` -- hypervisor-reported monitoring data (CPU, MEMORY, NETTX, NETRX, etc.)
   - `/VM/TEMPLATE` -- VM template attributes
   - `/VM` -- top-level VM attributes (ID, STATE, etc.)
4. **Consecutive true evaluations:** The expression must evaluate to `true` for `period_number` consecutive evaluation periods before the scaling action triggers. This prevents scaling on transient spikes.
5. **Cooldown:** After a scaling action triggers, the service enters COOLDOWN state for `cooldown` seconds. During cooldown, ALL elasticity policies for ALL roles are suspended -- no scaling actions can trigger.

### 6.3 Adjustment Types

| Type | Description | Example |
|------|-------------|---------|
| `CHANGE` | Add or subtract N VMs from current cardinality | `"adjust": 1` adds 1 VM; `"adjust": -1` removes 1 VM |
| `CARDINALITY` | Set cardinality to an absolute value | `"adjust": 4` sets cardinality to exactly 4 VMs |
| `PERCENTAGE_CHANGE` | Add or subtract N% of current cardinality | `"adjust": 50` adds 50% more VMs (rounded) |

All adjustment types respect `min_vms` and `max_vms` bounds. If the resulting cardinality would exceed `max_vms`, it is clamped to `max_vms`. If it would go below `min_vms`, it is clamped to `min_vms`.

### 6.4 Period and Cooldown Parameters

| Parameter | Type | Description | Recommendation |
|-----------|------|-------------|----------------|
| `period` | integer (seconds) | Evaluation interval -- how often OneFlow checks the expression | 60-120s for reactive scaling; longer for conservative scaling |
| `period_number` | integer | Number of consecutive true evaluations required before triggering | 3-5 for scale-up; 5-10 for scale-down (conservative) |
| `cooldown` | integer (seconds) | Post-scaling lockout duration -- no policies trigger during cooldown | 300s (scale-up), 600s (scale-down); must be >= typical round duration |

---

## 7. Custom FL Metrics via OneGate

### 7.1 Overview

SuperNode VMs can publish custom metrics to OneGate at runtime using the PUT API. These metrics appear in the VM's `USER_TEMPLATE` and are readable by OneFlow's elasticity expression evaluator. This enables FL-aware auto-scaling decisions based on training status rather than raw infrastructure metrics.

**Important distinction:** These are runtime metrics published via OneGate PUT, NOT CONTEXT variables set at boot. CONTEXT variables are read once at boot and are immutable. OneGate PUT updates the VM's `USER_TEMPLATE` dynamically and can be called multiple times during the VM's lifetime.

### 7.2 Defined Custom Metrics

| Metric | Value | Published When | Elasticity Use |
|--------|-------|----------------|----------------|
| `FL_TRAINING_ACTIVE` | `YES` / `NO` | Training round starts (YES) or ends (NO) | Scale-down protection during active training |
| `FL_CLIENT_STATUS` | `1` (IDLE), `2` (TRAINING), `3` (DISCONNECTED) | On status changes | Detect unhealthy nodes; FL-aware scaling triggers |
| `FL_ROUND_NUMBER` | Integer (e.g., `5`) | Each round completion | Track training progress; scheduled cardinality adjustments |

**Numeric encoding for FL_CLIENT_STATUS:** OneFlow elasticity expressions evaluate numerical comparisons. String values like `IDLE` or `TRAINING` cannot be compared with `>`, `<`, or `==` operators in OneFlow expressions. Therefore, `FL_CLIENT_STATUS` uses numeric encoding: 1 = IDLE, 2 = TRAINING, 3 = DISCONNECTED. This allows expressions like `FL_CLIENT_STATUS > 2` (detect disconnected nodes).

### 7.3 Publication Mechanism

Custom metrics are published from the SuperNode VM using the OneGate PUT API. The publication can be implemented as:

- **Hook in `bootstrap.sh`:** Publish initial status (`FL_CLIENT_STATUS=1`, `FL_TRAINING_ACTIVE=NO`) after the SuperNode container starts.
- **Periodic cron job:** A lightweight script that queries the SuperNode container status and publishes updates every 30-60 seconds.
- **ClientApp callback:** A custom ClientApp can call a local endpoint or script to trigger metric publication at round boundaries.

**OneGate PUT example:**

```bash
# Publish FL client status to OneGate USER_TEMPLATE
# Called from SuperNode VM (not from inside the container)

ONEGATE_TOKEN=$(cat /run/one-context/token.txt)

# Set initial status after boot
curl -X "PUT" "${ONEGATE_ENDPOINT}/vm" \
  --header "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  --header "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_CLIENT_STATUS = 1"

# Update when training starts
curl -X "PUT" "${ONEGATE_ENDPOINT}/vm" \
  --header "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  --header "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_TRAINING_ACTIVE = YES"

# Update round number
curl -X "PUT" "${ONEGATE_ENDPOINT}/vm" \
  --header "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  --header "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_ROUND_NUMBER = 5"
```

### 7.4 How Metrics Appear in USER_TEMPLATE

After the PUT call, the metrics are stored in the VM's `USER_TEMPLATE` and are visible to OneFlow's expression evaluator. When OneFlow evaluates an elasticity expression referencing `FL_CLIENT_STATUS`, it looks up `/VM/USER_TEMPLATE/FL_CLIENT_STATUS` for each running VM in the role, averages the values, and evaluates the expression.

**Example:** If 3 SuperNode VMs have `FL_CLIENT_STATUS` values of `2`, `2`, and `1`, the average is `(2+2+1)/3 = 1.67`. An expression `FL_CLIENT_STATUS > 1.5` would evaluate to `true`.

---

## 8. Elasticity Policy Definitions

### 8.1 Complete SuperNode Role with Elasticity Policies

The following JSON defines the SuperNode role with both elasticity and scheduled policies. This extends the SuperNode role from [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 3 by adding the `elasticity_policies` and `scheduled_policies` arrays.

```json
{
  "name": "supernode",
  "type": "vm",
  "template_id": 0,
  "cardinality": 2,
  "min_vms": 2,
  "max_vms": 10,
  "parents": ["superlink"],
  "shutdown_action": "shutdown",

  "user_inputs": {
    "ML_FRAMEWORK": "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch",
    "FL_USE_CASE": "O|list|Pre-built use case|none,image-classification,anomaly-detection,llm-fine-tuning|none",
    "FL_NODE_CONFIG": "O|text|Space-separated key=value node config||"
  },

  "template_contents": {
    "CONTEXT": {
      "TOKEN": "YES",
      "REPORT_READY": "YES",
      "READY_SCRIPT_PATH": "/opt/flower/scripts/health-check.sh",
      "NETWORK": "YES"
    }
  },

  "elasticity_policies": [
    {
      "type": "CHANGE",
      "adjust": 1,
      "expression": "CPU > 80",
      "period_number": 3,
      "period": 60,
      "cooldown": 300
    },
    {
      "type": "CHANGE",
      "adjust": -1,
      "expression": "CPU < 20",
      "period_number": 5,
      "period": 120,
      "cooldown": 600
    }
  ],

  "scheduled_policies": [
    {
      "type": "CARDINALITY",
      "adjust": 4,
      "recurrence": "0 9 * * mon,tue,wed,thu,fri"
    },
    {
      "type": "CARDINALITY",
      "adjust": 2,
      "recurrence": "0 18 * * mon,tue,wed,thu,fri"
    }
  ]
}
```

### 8.2 Policy Explanation

**Scale-up policy:**
- **Expression:** `CPU > 80` -- average CPU utilization across all SuperNode VMs exceeds 80%.
- **Trigger:** Must be true for 3 consecutive periods of 60 seconds (3 minutes sustained high CPU).
- **Action:** Add 1 SuperNode VM (`CHANGE` +1).
- **Cooldown:** 300 seconds (5 minutes) after scaling before any policy can trigger again.

**Scale-down policy:**
- **Expression:** `CPU < 20` -- average CPU utilization drops below 20%.
- **Trigger:** Must be true for 5 consecutive periods of 120 seconds (10 minutes sustained low CPU).
- **Action:** Remove 1 SuperNode VM (`CHANGE` -1).
- **Cooldown:** 600 seconds (10 minutes) after scaling.
- **Conservative design:** Scale-down uses a longer evaluation window (10 min vs 3 min) and longer cooldown (10 min vs 5 min) to avoid premature scale-down during idle periods between training rounds.

**Scheduled policies:**
- **Business hours scale-up:** At 9:00 AM Monday-Friday, set cardinality to 4 (scale up for daytime training).
- **Evening scale-down:** At 6:00 PM Monday-Friday, set cardinality to 2 (release resources overnight).
- **Cron format:** Standard 5-field cron (`minute hour day-of-month month day-of-week`).

### 8.3 FL-Aware Policy Examples

Alternative policies using custom FL metrics (published via OneGate, Section 7):

**Scale-up when all clients are busy training:**

```json
{
  "type": "CHANGE",
  "adjust": 1,
  "expression": "FL_CLIENT_STATUS > 1.5",
  "period_number": 3,
  "period": 60,
  "cooldown": 300
}
```

This triggers when the average `FL_CLIENT_STATUS` exceeds 1.5 (meaning most clients are in TRAINING state = 2 rather than IDLE = 1). Sustained high utilization suggests more clients could improve data parallelism.

**Scale-down protection during active training:**

The cooldown mechanism is the primary scale-down protection: after any scale-down, the 600-second cooldown prevents further scaling actions. For additional protection, operators can set the scale-down `period_number` high enough that the evaluation window exceeds typical round duration.

### 8.4 Interaction with min_vms and max_vms

| Bound | Purpose | Constraint |
|-------|---------|------------|
| `min_vms` | Floor for scale-down | MUST be >= `FL_MIN_FIT_CLIENTS` to prevent training deadlock |
| `max_vms` | Ceiling for scale-up | Prevents resource over-provisioning |

**Critical constraint:** `min_vms >= FL_MIN_FIT_CLIENTS`. If `min_vms` is 2 but `FL_MIN_FIT_CLIENTS` is 3, a scale-down to 2 VMs causes the SuperLink to wait indefinitely for a third client that will never arrive. The service template does not enforce this constraint automatically -- it is a configuration guideline that the operator must follow.

---

## 9. Client Join/Leave Semantics During Auto-Scaling

### 9.1 Scale-Up During Active Training

When OneFlow adds a new SuperNode VM via auto-scaling:

1. OneFlow creates the new VM from the `template_id` with the same CONTEXT variables.
2. The new VM boots, runs `configure.sh`, and executes SuperLink discovery.
3. Discovery succeeds immediately -- the SuperLink has been publishing since initial deployment.
4. The new SuperNode container starts, connects to the SuperLink's Fleet API via gRPC.
5. The SuperNode registers with the SuperLink and becomes available for the NEXT round.
6. **The current training round (if active) is unaffected.** The new client is not added to an in-progress round.
7. The SuperNode computes its `partition-id` from the updated OneGate `nodes` array (see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 5).

**Timing:** A new SuperNode takes approximately 30-60 seconds to boot and connect. If a training round completes in that window, the new client participates starting from the round after it connects.

### 9.2 Scale-Down During Active Training

When OneFlow removes a SuperNode VM via auto-scaling:

1. OneFlow sends a shutdown signal to the target VM (newest VMs removed first -- see Section 9.3).
2. The VM's systemd unit receives SIGTERM and forwards it to the Docker container.
3. The Flower SuperNode container shuts down gracefully.
4. The SuperLink detects the client disconnection.

**Impact on current training round:**

| Condition | Outcome |
|-----------|---------|
| `accept_failures=True` (default) AND enough results from other clients | Round proceeds normally. The removed client's contribution is missing but the round completes. |
| `accept_failures=True` AND remaining results below `min_fit_clients` | Round fails. The aggregation receives insufficient results. Next round retries with remaining clients. |
| `accept_failures=False` | Round fails if any client fails to report. Not recommended for auto-scaling deployments. |

### 9.3 VM Removal Order: Newest First

OneFlow removes the newest VMs first during scale-down. This is the default OneFlow behavior and is NOT configurable to be FL-aware (e.g., preferring to remove IDLE clients).

**Implications:**
- The newest VM may be actively training. Scale-down during active rounds risks round failure.
- There is no mechanism to tell OneFlow "remove the IDLE client" -- OneFlow does not inspect application-level state when selecting VMs for removal.
- **Workaround:** Use long cooldown periods (>= typical round duration) so scale-down events do not coincide with active training. The 600-second default cooldown in the scale-down policy provides protection for rounds up to 10 minutes long.

### 9.4 Cooldown as Scale-Down Protection

The `cooldown` parameter is the primary mechanism for protecting active training rounds from scale-down disruption.

**Recommended cooldown values:**

| Training Round Duration | Recommended Scale-Down Cooldown |
|------------------------|--------------------------------|
| Short rounds (< 2 min) | 300 seconds (5 minutes) |
| Medium rounds (2-10 min) | 600 seconds (10 minutes) -- default |
| Long rounds (10-30 min) | 1800 seconds (30 minutes) |
| Very long rounds (> 30 min) | Set cooldown >= round duration |

**Rule of thumb:** Set scale-down cooldown to at least 2x the expected training round duration. This ensures that a scale-down event followed by cooldown spans at least one full round, preventing consecutive scale-down events from disrupting back-to-back rounds.

### 9.5 Partition-ID for Scaled VMs

New SuperNode VMs added via auto-scaling compute their `partition-id` from the updated `nodes` array in the OneGate service response. This follows the existing auto-computation mechanism from [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 5:

- The new VM queries `GET /service` from OneGate.
- The `supernode` role's `nodes` array now includes the new VM.
- The new VM's 0-based index in the array determines its `partition-id`.
- Existing SuperNodes retain their original `partition-id` values (computed at their boot time; not recomputed).

**Limitation:** If VMs were previously removed (scale-down), the `partition-id` sequence may have gaps. The newly added VM fills one of these gaps (it receives the index of its position in the current array). This means data partitioning may not be perfectly balanced. For deployments requiring strict partition isolation, use explicit `FL_NODE_CONFIG` with externally managed assignments.

---

## 10. Anti-Patterns

Common misconfigurations for edge and auto-scaling deployments. Each entry describes what goes wrong and the correct approach.

| # | Anti-Pattern | What Goes Wrong | Correct Approach |
|---|-------------|----------------|-----------------|
| 1 | **Setting `min_available_clients` equal to SuperNode cardinality at edge** | If all N edge nodes must be available, any single node failure or disconnection blocks training entirely. Training never starts because edge nodes are intermittently connected. | Set `FL_MIN_AVAILABLE_CLIENTS` below the expected node count. For N edge nodes, use `ceil(N * 0.5)` to allow training with 50% availability. |
| 2 | **Aggressive scale-down cooldown (< round duration)** | Scale-down removes a client mid-round. Before the round completes, cooldown expires and another scale-down triggers, removing another client. Cascading client removal causes round failures. | Set scale-down cooldown >= 2x typical round duration. Default 600s is appropriate for rounds under 5 minutes. Increase for longer rounds. |
| 3 | **Elasticity policies on SuperLink role** | Auto-scaling the singleton coordinator triggers split-brain failure (multiple SuperLink instances with independent state). Even if `max_vms: 1` prevents actual scaling, the policy is a dangerous misconfiguration signal. | Never define `elasticity_policies` or `scheduled_policies` on the SuperLink role. Auto-scaling applies only to the SuperNode role. |
| 4 | **Scaling below `min_fit_clients`** | `min_vms` in the service template is set below `FL_MIN_FIT_CLIENTS`. A scale-down event reduces cardinality below the training threshold. The SuperLink waits indefinitely for clients that will never arrive. | Ensure `min_vms >= FL_MIN_FIT_CLIENTS`. If `FL_MIN_FIT_CLIENTS=3`, set `min_vms` to at least 3. |
| 5 | **Using framework-specific images for edge** | Framework-specific Docker images (PyTorch ~4-5 GB QCOW2, TensorFlow ~3 GB) defeat the under-2 GB edge target. The edge appliance becomes indistinguishable from a standard appliance. | Use the edge QCOW2 with base `flwr/supernode:1.25.0` only. Provide the ML framework via custom Docker image with `FL_ISOLATION=process`. |
| 6 | **Averaging masks individual VM issues** | OneFlow averages attribute values across all VMs in a role. If 9 VMs have CPU at 10% and 1 VM has CPU at 90%, the average is 19% -- below any typical scale-up threshold. The overloaded VM is masked. | Use custom FL-specific metrics (published via OneGate) rather than raw infrastructure metrics. Consider `FL_CLIENT_STATUS` numeric encoding for more precise scaling triggers. Monitor individual VM health via Phase 8 monitoring stack. |
| 7 | **Cooldown blocking emergency scale-up** | After a scale-down event, the service enters COOLDOWN. During cooldown, a sudden load spike requires more clients but scale-up is blocked until cooldown expires. | Keep scale-down cooldown reasonable (300-600s). Use `min_vms` as a hard floor to prevent over-aggressive scale-down. Avoid elasticity policies on SuperLink role (which would share cooldown state). |

---

## 11. New Contextualization Variables Summary

Phase 9 introduces two new contextualization variables, both applying to the SuperNode appliance (edge variant only). No new SuperLink variables are introduced. Auto-scaling configuration is defined in the OneFlow service template (`elasticity_policies` JSON), not through CONTEXT variables.

### 11.1 Variable Definitions

| # | Context Variable | USER_INPUT Definition | Type | Default | Appliance | Validation Rule | Purpose |
|---|------------------|----------------------|------|---------|-----------|-----------------|---------|
| 1 | `FL_EDGE_BACKOFF` | `O\|list\|Edge discovery retry backoff strategy\|exponential,fixed\|exponential` | list | `exponential` | SuperNode (edge variant) | Must be `exponential` or `fixed` | Controls the discovery retry backoff strategy. `exponential`: starts at 10s, doubles, caps at `FL_EDGE_MAX_BACKOFF`. `fixed`: 30 retries at 10s intervals (Phase 1 behavior). |
| 2 | `FL_EDGE_MAX_BACKOFF` | `O\|number\|Maximum backoff interval in seconds for edge discovery\|\|300` | number | `300` | SuperNode (edge variant) | Positive integer (>0). Only effective when `FL_EDGE_BACKOFF=exponential`. | Upper bound on the exponential backoff interval. Default 300s = 5 minutes between retries at cap. |

### 11.2 Updated Variable Count

With Phase 9 additions, the total contextualization variable count updates:

| Category | Count | Change |
|----------|-------|--------|
| SuperLink parameters | 24 | (unchanged) |
| SuperNode parameters | 15 | +2 (FL_EDGE_BACKOFF, FL_EDGE_MAX_BACKOFF) |
| Shared infrastructure | 5 | (unchanged) |
| Service-level (OneFlow) | 1 | (unchanged) |
| Phase 2+ placeholders | 5 | (unchanged) |
| **Total unique variables** | **48** | **+2 new (46 -> 48)** |

### 11.3 USER_INPUT Block for Edge SuperNode (Copy-Paste Ready)

```
USER_INPUTS = [
  # Phase 1: Base architecture
  FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0",
  FL_SUPERLINK_ADDRESS = "O|text|SuperLink Fleet API address (host:port)||",
  FL_NODE_CONFIG = "O|text|Space-separated key=value node config||",
  FL_MAX_RETRIES = "O|number|Max reconnection attempts (0=unlimited)||0",
  FL_MAX_WAIT_TIME = "O|number|Max wait time for connection in seconds (0=unlimited)||0",
  FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess",
  FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO",

  # Phase 7: Multi-site federation
  FL_GRPC_KEEPALIVE_TIME = "O|number|gRPC keepalive interval in seconds||60",
  FL_GRPC_KEEPALIVE_TIMEOUT = "O|number|gRPC keepalive ACK timeout in seconds||20",

  # Phase 9: Edge and auto-scaling
  FL_EDGE_BACKOFF = "O|list|Edge discovery retry backoff strategy|exponential,fixed|exponential",
  FL_EDGE_MAX_BACKOFF = "O|number|Maximum backoff interval in seconds for edge discovery||300"
]
```

**Notes:**
- GPU variables (`FL_GPU_ENABLED`, `FL_CUDA_VISIBLE_DEVICES`, `FL_GPU_MEMORY_FRACTION`) are omitted from the edge USER_INPUT block because GPU passthrough is not the expected use case for edge. They can be added if a specific edge deployment requires GPU support.
- DCGM variable (`FL_DCGM_ENABLED`) is similarly omitted.
- `FL_SUPERLINK_ADDRESS` remains `O|text` (optional) in the base definition. For multi-site edge deployments, operators should set it as mandatory in their template (change to `M|text`), as OneGate discovery is unavailable cross-zone.

---

*Specification for ORCH-03, EDGE-01: Edge and Auto-Scaling*
*Phase: 09 - Edge and Auto-Scaling*
*Version: 1.0*
