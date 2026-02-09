# Single-Site Orchestration

**Requirement:** ORCH-01
**Phase:** 04 - Single-Site Orchestration
**Status:** Specification

---

## 1. Purpose and Scope

This section defines the OneFlow service template that deploys a complete Flower federated learning cluster (1 SuperLink + N SuperNodes) as a single orchestrated service within a single OpenNebula zone. The service template is the artifact that an engineer registers in the OpenNebula marketplace; deployers instantiate it through Sunstone or the CLI to get a fully operational Flower federation with zero manual VM coordination.

**What this section covers:**
- OneFlow service template JSON with role definitions, deployment ordering, and ready status gating.
- Three-level user_inputs hierarchy: service-level shared variables, SuperLink role-level variables, and SuperNode role-level variables.
- Cardinality configuration for both roles (SuperLink singleton constraint, SuperNode elastic range).
- Per-SuperNode differentiation via auto-computed `partition-id` from the OneGate service response.

**What this section does NOT cover:**
- Deployment sequence walkthrough and OneGate coordination protocol (Phase 4, Plan 2).
- Scaling operations and service lifecycle management (Phase 4, Plan 2).
- Multi-site federation across OpenNebula zones -- see [`spec/12-multi-site-federation.md`](12-multi-site-federation.md) (Phase 7).
- Auto-scaling triggers and elasticity policies (Phase 9).
- Training configuration internals and checkpointing (see [`spec/09-training-configuration.md`](09-training-configuration.md)).

**Cross-references:**
- Training configuration: [`spec/09-training-configuration.md`](09-training-configuration.md) -- aggregation strategy selection, strategy-specific parameters, model checkpointing, failure recovery.
- SuperLink appliance: [`spec/01-superlink-appliance.md`](01-superlink-appliance.md) -- VM template, boot sequence, OneGate publication contract (Section 10), parameters (Section 12).
- SuperNode appliance: [`spec/02-supernode-appliance.md`](02-supernode-appliance.md) -- VM template, discovery model (Section 6), parameters (Section 13).
- Contextualization reference: [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) -- complete variable definitions, USER_INPUT format, validation rules.
- TLS certificate lifecycle: [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md) -- SuperLink TLS generation and OneGate CA cert publication.
- SuperNode TLS trust: [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md) -- CA cert retrieval and TLS mode detection.
- ML framework variants: [`spec/06-ml-framework-variants.md`](06-ml-framework-variants.md) -- `ML_FRAMEWORK` variable and framework-specific Docker images.
- Use case templates: [`spec/07-use-case-templates.md`](07-use-case-templates.md) -- `FL_USE_CASE` variable and pre-built Flower App Bundles.
- Multi-site federation: [`spec/12-multi-site-federation.md`](12-multi-site-federation.md) -- cross-zone deployment topology, per-zone OneFlow templates, WireGuard/direct IP networking, gRPC keepalive, TLS trust distribution.

---

## 2. Service Template Architecture

The OneFlow service template wraps two VM templates (SuperLink and SuperNode) into a single deployable service with automatic dependency ordering. The deployer instantiates one service template; OneFlow creates all VMs, gates child role deployment on parent readiness, and propagates shared configuration.

### Architecture Diagram

```
OneFlow Service Template: "Flower Federated Learning"
+------------------------------------------------------------------+
|                                                                    |
|  Service-Level user_inputs (shared across all roles)               |
|    FLOWER_VERSION   FL_TLS_ENABLED   FL_LOG_LEVEL                  |
|                                                                    |
|  +------------------------------+  +-----------------------------+ |
|  |  Role: superlink (parent)    |  |  Role: supernode (child)    | |
|  |                              |  |                             | |
|  |  cardinality: 1              |  |  cardinality: 2 (default)   | |
|  |  min_vms: 1  max_vms: 1      |  |  min_vms: 2  max_vms: 10   | |
|  |  template_id: <SuperLink VM> |  |  template_id: <SuperNode VM>| |
|  |  parents: (none -- root)     |  |  parents: ["superlink"]     | |
|  |                              |  |                             | |
|  |  Role-Level user_inputs:     |  |  Role-Level user_inputs:    | |
|  |    FL_NUM_ROUNDS             |  |    ML_FRAMEWORK             | |
|  |    FL_STRATEGY               |  |    FL_USE_CASE              | |
|  |    FL_MIN_FIT_CLIENTS        |  |    FL_NODE_CONFIG            | |
|  |    FL_MIN_EVALUATE_CLIENTS   |  |                             | |
|  |    FL_MIN_AVAILABLE_CLIENTS  |  |                             | |
|  +------------------------------+  +-----------------------------+ |
|                                                                    |
|  deployment: "straight"    ready_status_gate: true                 |
|  shutdown_action: "shutdown"                                       |
+------------------------------------------------------------------+
```

### Three-Level Configuration Hierarchy

The service template uses a three-level hierarchy that separates shared configuration from role-specific settings. This prevents accidental version drift and exposes only relevant parameters to each role.

**Level 1: Service-Level user_inputs (shared across all roles)**

| Variable | Why Service-Level |
|----------|-------------------|
| `FLOWER_VERSION` | SuperLink and SuperNode MUST run the same Flower version. Defining it once at the service level prevents version mismatch, which causes gRPC protocol errors (see `spec/03-contextualization-reference.md`, Section 10a). |
| `FL_TLS_ENABLED` | TLS mode must be consistent: both sides must agree on encrypted or insecure. A mismatch causes immediate connection failure. |
| `FL_LOG_LEVEL` | Log verbosity is typically set uniformly for a deployment. Operators debugging an issue want all VMs at the same level. |

OneFlow automatically propagates service-level user_inputs to all roles' VM CONTEXT. The user is prompted once at instantiation time (in Sunstone or via CLI), not per-role.

**Level 2: SuperLink Role-Level user_inputs**

| Variable | Why Role-Level |
|----------|---------------|
| `FL_NUM_ROUNDS` | Training round count is a server-side parameter. SuperNodes do not use it. |
| `FL_STRATEGY` | Aggregation strategy is configured on the SuperLink. SuperNodes train locally with whatever strategy the server dictates. |
| `FL_MIN_FIT_CLIENTS` | Minimum client thresholds are SuperLink configuration. They control when the server initiates training rounds. |
| `FL_MIN_EVALUATE_CLIENTS` | Same rationale as above -- evaluation gating is server-side. |
| `FL_MIN_AVAILABLE_CLIENTS` | Same rationale -- availability gating is server-side. |
| `FL_PROXIMAL_MU` | FedProx proximal term is a server-side strategy parameter. |
| `FL_SERVER_LR` | FedAdam server learning rate is a server-side parameter. |
| `FL_CLIENT_LR` | FedAdam client learning rate is configured at server level (forwarded to clients via strategy). |
| `FL_NUM_MALICIOUS` | Byzantine client count is a server-side aggregation parameter. |
| `FL_TRIM_BETA` | FedTrimmedAvg trim fraction is a server-side aggregation parameter. |
| `FL_CHECKPOINT_ENABLED` | Only the SuperLink saves checkpoints. |
| `FL_CHECKPOINT_INTERVAL` | Only the SuperLink saves checkpoints. |
| `FL_CHECKPOINT_PATH` | Only the SuperLink saves checkpoints. |

These variables appear only in the SuperLink role's user_inputs. SuperNode VMs do not receive them in their CONTEXT.

**Level 3: SuperNode Role-Level user_inputs**

| Variable | Why Role-Level |
|----------|---------------|
| `ML_FRAMEWORK` | Framework selection determines which Docker image the SuperNode runs. Irrelevant to the SuperLink. |
| `FL_USE_CASE` | Use case template activation is a SuperNode concern. The SuperLink does not need to know which ClientApp the SuperNodes are running. |
| `FL_NODE_CONFIG` | Node-specific configuration (partition-id, custom keys) applies per-SuperNode. See Section 5 for auto-computation. |

These variables appear only in the SuperNode role's user_inputs.

### Variable Placement Rule

**Service-level:** Variables that MUST be identical across both roles for correct operation.

**Role-level:** Variables that are meaningful to only one role or that intentionally differ per-role.

**Never duplicate a variable at both levels.** Role-level user_inputs override service-level when both define the same key. This creates a subtle precedence bug: if `FLOWER_VERSION` is defined at both service and role level, the role-level value wins silently. To avoid this, define each variable at exactly one level.

### Infrastructure CONTEXT Variables

The following variables are set in each VM template's CONTEXT section, NOT in user_inputs. They are infrastructure-level settings that deployers should not modify:

| Variable | Value | Purpose |
|----------|-------|---------|
| `TOKEN` | `YES` | Enables OneGate authentication token for inter-VM discovery and readiness reporting. |
| `REPORT_READY` | `YES` | Reports VM readiness to OneGate after the health check passes. Required for `ready_status_gate`. |
| `READY_SCRIPT_PATH` | `/opt/flower/scripts/health-check.sh` | Gates readiness on Flower application health (not just VM boot). |
| `NETWORK` | `YES` | Enables network configuration by the contextualization agent. |

These are placed in `template_contents` at the role level (see Section 3) to ensure they are always present regardless of user_inputs configuration.

---

## 3. Complete Service Template JSON

The following JSON defines the complete OneFlow service template for a Flower federated learning cluster. An engineer can use this directly by replacing the `template_id` placeholder values with actual VM template IDs from the OpenNebula environment.

```json
{
  "name": "Flower Federated Learning",
  "description": "Deploys a complete Flower federated learning cluster: 1 SuperLink coordinator + N SuperNode clients with automatic dependency ordering and service discovery via OneGate.",
  "deployment": "straight",
  "ready_status_gate": true,
  "shutdown_action": "shutdown",

  "user_inputs": {
    "FLOWER_VERSION": "O|text|Flower Docker image version tag||1.25.0",
    "FL_TLS_ENABLED": "O|boolean|Enable TLS encryption||NO",
    "FL_LOG_LEVEL": "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
  },

  "roles": [
    {
      "name": "superlink",
      "type": "vm",
      "template_id": 0,
      "cardinality": 1,
      "min_vms": 1,
      "max_vms": 1,
      "shutdown_action": "shutdown",

      "user_inputs": {
        "FL_NUM_ROUNDS": "O|number|Number of federated learning rounds||3",
        "FL_STRATEGY": "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg|FedAvg",
        "FL_MIN_FIT_CLIENTS": "O|number|Minimum clients for training round||2",
        "FL_MIN_EVALUATE_CLIENTS": "O|number|Minimum clients for evaluation||2",
        "FL_MIN_AVAILABLE_CLIENTS": "O|number|Minimum available clients to start||2",
        "FL_PROXIMAL_MU": "O|number-float|FedProx proximal term (mu)||1.0",
        "FL_SERVER_LR": "O|number-float|Server-side learning rate||0.1",
        "FL_CLIENT_LR": "O|number-float|Client-side learning rate||0.1",
        "FL_NUM_MALICIOUS": "O|number|Expected malicious clients (Krum/Bulyan)||0",
        "FL_TRIM_BETA": "O|number-float|Trim fraction per tail (FedTrimmedAvg)||0.2",
        "FL_CHECKPOINT_ENABLED": "O|boolean|Enable model checkpointing||NO",
        "FL_CHECKPOINT_INTERVAL": "O|number|Save checkpoint every N rounds||5",
        "FL_CHECKPOINT_PATH": "O|text|Checkpoint directory (container path)||/app/checkpoints"
      },

      "template_contents": {
        "CONTEXT": {
          "TOKEN": "YES",
          "REPORT_READY": "YES",
          "READY_SCRIPT_PATH": "/opt/flower/scripts/health-check.sh",
          "NETWORK": "YES"
        }
      }
    },
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
      }
    }
  ]
}
```

### Field-by-Field Annotations

**Service-level fields:**

| Field | Value | Purpose |
|-------|-------|---------|
| `name` | `"Flower Federated Learning"` | Display name in Sunstone and `oneflow-template list`. Identifies the service template in the marketplace. |
| `description` | (see JSON) | Human-readable description shown in Sunstone when browsing templates. |
| `deployment` | `"straight"` | Roles deploy sequentially in array order. SuperLink (index 0) deploys first; SuperNode (index 1) deploys after SuperLink is ready. The alternative `"none"` deploys all roles simultaneously, which causes race conditions. |
| `ready_status_gate` | `true` | **The single most important setting.** When `true`, OneFlow considers a VM "running" only when BOTH the hypervisor reports RUNNING AND the VM's user template contains `READY=YES`. Without this, OneFlow deploys SuperNode VMs as soon as the SuperLink VM's hypervisor boots -- before the OS loads, before Docker starts, before Flower listens. See `spec/01-superlink-appliance.md`, Section 9 for how `REPORT_READY` + `READY_SCRIPT_PATH` gate on application-level health. |
| `shutdown_action` | `"shutdown"` | When the service is deleted, VMs are shut down gracefully (ACPI shutdown signal). The alternative `"shutdown-hard"` sends an immediate power-off, which may corrupt the SuperLink state database. |
| `user_inputs` | (3 variables) | Service-level user_inputs are propagated to ALL roles. OneFlow automatically adds them to each role's `template_contents`. The user is prompted once at instantiation. |

**SuperLink role fields:**

| Field | Value | Purpose |
|-------|-------|---------|
| `name` | `"superlink"` | Role identifier. Referenced by SuperNode's `parents` array and by the OneGate jq discovery filter (`.roles[] \| select(.name == "superlink")`). Must match exactly. |
| `type` | `"vm"` | Role creates VMs (not containers or other resource types). |
| `template_id` | `0` | **Placeholder.** Replace with the actual SuperLink VM template ID assigned at marketplace registration time. The VM template defines the QCOW2 image, CPU/RAM, network, and the infrastructure CONTEXT variables. |
| `cardinality` | `1` | Deploy exactly 1 SuperLink VM. Flower's SuperLink is a singleton coordinator; see Section 4 for why this is hard-constrained. |
| `min_vms` | `1` | Prevents scaling below 1. Combined with `max_vms: 1`, this creates a hard singleton constraint. |
| `max_vms` | `1` | Prevents scaling above 1. OneFlow enforces this bound and rejects scale requests. |
| `shutdown_action` | `"shutdown"` | Graceful shutdown for this role's VMs specifically. Ensures the SuperLink's SQLite state database is written cleanly. |
| `user_inputs` | (13 variables) | SuperLink-specific parameters: training rounds, aggregation strategy, client thresholds, strategy-specific parameters (Phase 5), and checkpointing configuration (Phase 5). Not propagated to SuperNode VMs. |
| `template_contents` | (CONTEXT object) | Infrastructure variables injected into the VM's CONTEXT at instantiation. `TOKEN=YES` enables OneGate; `REPORT_READY=YES` with `READY_SCRIPT_PATH` gates readiness on Flower health. |

**SuperNode role fields:**

| Field | Value | Purpose |
|-------|-------|---------|
| `name` | `"supernode"` | Role identifier. Used in OneGate service response parsing and scaling commands. |
| `type` | `"vm"` | Same as SuperLink -- role creates VMs. |
| `template_id` | `0` | **Placeholder.** Replace with the actual SuperNode VM template ID. The VM template may be framework-specific (e.g., a PyTorch variant QCOW2). |
| `cardinality` | `2` | Default: deploy 2 SuperNode VMs. This is the minimum for meaningful federated learning (FedAvg requires at least 2 clients). Overridable at instantiation. |
| `min_vms` | `2` | Minimum SuperNode count. FL requires at least 2 clients for FedAvg aggregation. See Section 4 for cardinality constraints. |
| `max_vms` | `10` | Maximum SuperNode count. Reasonable default for single-site deployments. Operator can adjust in the template for larger clusters. |
| `parents` | `["superlink"]` | **Dependency ordering.** OneFlow will NOT create SuperNode VMs until the `superlink` role is fully running (all VMs have `READY=YES` when `ready_status_gate` is enabled). This is the mechanism that prevents SuperNodes from booting before the SuperLink is operational. |
| `shutdown_action` | `"shutdown"` | Graceful shutdown for SuperNode VMs. |
| `user_inputs` | (3 variables) | SuperNode-specific parameters: ML framework selection, use case template, and node configuration. |
| `template_contents` | (CONTEXT object) | Same infrastructure variables as SuperLink. Both roles need `TOKEN=YES` for OneGate access and `REPORT_READY=YES` for readiness reporting. |

### Notes

**On `template_id: 0`:** The placeholder value `0` must be replaced with actual VM template IDs when registering the service template. The registration workflow is:
1. Create the SuperLink VM template (from the SuperLink QCOW2 appliance) and note its ID.
2. Create the SuperNode VM template (from the appropriate framework variant QCOW2) and note its ID.
3. Update the service template JSON with both IDs.
4. Register via `oneflow-template create flower-service.json`.

**On backward compatibility (OpenNebula 6.x):** The JSON uses OpenNebula 7.0 field names. For OpenNebula 6.x environments, the following aliases apply:

| 7.0 Field Name | 6.x Alias | Notes |
|----------------|-----------|-------|
| `template_id` | `vm_template` | Same semantics: integer VM template ID. |
| `user_inputs` | `custom_attrs` | Same semantics: user-configurable variables. |
| `template_contents` | `vm_template_contents` | 6.x uses a string format (`"KEY=VALUE\nKEY2=VALUE2"`); 7.0 uses a JSON object. |

The spec targets OpenNebula 7.0+ as the primary platform. When deploying on 6.x, replace field names accordingly and convert `template_contents` from JSON object to string format.

---

## 4. Cardinality Configuration

Cardinality defines how many VMs each role deploys. The SuperLink and SuperNode roles have fundamentally different cardinality models: the SuperLink is a hard singleton, while SuperNode cardinality is elastic within a bounded range.

### SuperLink: Hard Singleton (cardinality = 1)

The SuperLink role MUST have exactly 1 VM. This is enforced by setting `min_vms: 1` and `max_vms: 1` in the service template.

**Why singleton:** Flower's SuperLink is a centralized coordinator. It maintains a single SQLite state database (`state.db`) tracking all connected SuperNodes, training round progress, and aggregated model weights. Running multiple SuperLink instances creates independent coordinators with no shared state -- each would track a different subset of SuperNodes, produce different aggregation results, and advance through training rounds independently. This is a split-brain failure mode with no recovery path.

**What happens if cardinality exceeds 1:** OneFlow enforces the `max_vms` bound and rejects any scaling request that would exceed it:

```bash
# This fails:
oneflow scale <service_id> superlink 2
# Error: cannot scale role "superlink" above max_vms (1)
```

The `--force` flag bypasses min/max bounds. Operators MUST NOT use `--force` to scale the SuperLink role. If they do, the jq discovery filter in SuperNode's `discover.sh` selects `.nodes[0]` -- the first SuperLink VM -- and ignores any additional instances. The result is that some SuperNodes connect to one SuperLink while new SuperNodes may discover a different one, causing a silent federation split.

**No elasticity policies:** The SuperLink role MUST NOT have `elasticity_policies` or `scheduled_policies` defined. Auto-scaling the singleton coordinator is a dangerous misconfiguration. The `min_vms: 1, max_vms: 1` constraint makes elasticity policies ineffective, but they should be omitted entirely for clarity.

### SuperNode: Elastic Range (cardinality = 2, range 2-10)

The SuperNode role has a configurable cardinality within a bounded range.

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `cardinality` | `2` | Default deployment size. The minimum for meaningful federated learning: FedAvg requires at least 2 clients to compute a weighted average. |
| `min_vms` | `2` | Floor for scale-down operations. Scaling below 2 SuperNodes makes FL non-functional (FedAvg with 1 client degenerates to local training). |
| `max_vms` | `10` | Reasonable ceiling for single-site deployments. Prevents accidental over-provisioning. Operators can increase this in their template for larger clusters. |

**Interaction with FL_MIN_AVAILABLE_CLIENTS:** The `FL_MIN_AVAILABLE_CLIENTS` SuperLink parameter (default: 2) controls when the SuperLink starts accepting training rounds. For the service to become fully operational:

```
SuperNode cardinality (min_vms) >= FL_MIN_AVAILABLE_CLIENTS
```

If `min_vms` is 2 and `FL_MIN_AVAILABLE_CLIENTS` is 2 (both defaults), the SuperLink begins training as soon as both SuperNodes connect. If an operator sets `FL_MIN_AVAILABLE_CLIENTS` to 5 but leaves `min_vms` at 2, the SuperLink will wait indefinitely for 3 more clients that will never arrive. The service template does not enforce this constraint -- it is documented as a configuration guideline.

### Cardinality Override at Instantiation

The deployer can override the default SuperNode cardinality when instantiating a service, without modifying the service template:

```bash
# Deploy with 5 SuperNodes instead of the default 2
oneflow-template instantiate <template_id> \
  --extra_template '{"roles": [{"name": "supernode", "cardinality": 5}]}'
```

In Sunstone, the cardinality can be adjusted in the service instantiation dialog. The override is bounded by `min_vms` and `max_vms` -- requesting a cardinality outside this range requires modifying the service template or using `--force`.

### Cardinality Summary Table

| Property | SuperLink | SuperNode |
|----------|-----------|-----------|
| Default cardinality | 1 | 2 |
| Minimum (`min_vms`) | 1 | 2 |
| Maximum (`max_vms`) | 1 | 10 |
| Scaling allowed | No (singleton) | Yes (within range) |
| Elasticity policies | Not applicable | Supported (Phase 9) |
| Override at instantiation | No (hard constraint) | Yes (within min/max) |
| Scale command | Rejected by OneFlow | `oneflow scale <id> supernode <N>` |

---

## 5. Per-SuperNode Differentiation (FL_NODE_CONFIG)

### Problem Statement

OneFlow's `user_inputs` mechanism applies the same value to all VMs in a role. When a deployer sets `FL_NODE_CONFIG` at the SuperNode role level, every SuperNode receives an identical copy. But federated learning data partitioning requires each SuperNode to train on a different subset of data -- each needs a unique `partition-id` value and all need to know the total `num-partitions`.

Setting `FL_NODE_CONFIG` manually per-SuperNode is not possible through the service template alone: OneFlow does not support per-VM variable overrides within a role.

### Solution: Auto-Computed Partition ID from OneGate

The SuperNode boot script automatically computes a unique `partition-id` from the VM's position in the OneFlow service. This computation happens during the discovery phase (Step 7 in the SuperNode boot sequence -- see `spec/02-supernode-appliance.md`, Section 7), which already queries the OneGate service API.

**Mechanism:**

1. During OneGate discovery, the SuperNode queries `GET /service` and receives the full service definition including the list of nodes in each role.
2. The response contains the `supernode` role's `nodes` array, where each entry has a `deploy_id` matching the VM's ID.
3. The boot script finds its own VMID in the `nodes` array and uses its 0-based index as `partition-id`.
4. The total number of entries in the `nodes` array provides `num-partitions`.
5. These values are injected into `FL_NODE_CONFIG` automatically -- but only if `FL_NODE_CONFIG` is empty or unset.
6. If `FL_NODE_CONFIG` is already set by the user (non-empty), the auto-computed values are NOT applied. User-provided configuration takes precedence.

### Auto-Partition Pseudocode

The following logic runs as part of the SuperNode's `discover.sh` script, after the SuperLink endpoint has been successfully resolved:

```bash
# Auto-compute partition-id from OneGate service response
# Prerequisite: SERVICE_JSON already populated from OneGate GET /service

if [ -z "${FL_NODE_CONFIG}" ]; then
    # Extract the supernode role's nodes array
    NODES=$(echo "$SERVICE_JSON" | jq '.SERVICE.roles[] | select(.name == "supernode") | .nodes')

    # Total number of SuperNode VMs in this service
    NUM_PARTITIONS=$(echo "$NODES" | jq 'length')

    # Find this VM's 0-based index in the nodes array
    MY_INDEX=$(echo "$NODES" | jq --arg vmid "$VMID" \
        '[.[].deploy_id | tostring] | to_entries[] | select(.value == $vmid) | .key')

    if [ -n "$MY_INDEX" ] && [ -n "$NUM_PARTITIONS" ]; then
        FL_NODE_CONFIG="partition-id=${MY_INDEX} num-partitions=${NUM_PARTITIONS}"
        log "INFO" "Auto-computed FL_NODE_CONFIG: ${FL_NODE_CONFIG}"
    else
        log "WARN" "Could not determine partition-id from OneGate service response"
        log "WARN" "FL_NODE_CONFIG left empty; ClientApp must handle partitioning internally"
    fi
else
    log "INFO" "FL_NODE_CONFIG provided by user: ${FL_NODE_CONFIG} (skipping auto-computation)"
fi
```

### Precedence Rule

| FL_NODE_CONFIG State | Behavior |
|---------------------|----------|
| Empty or unset (default) | Auto-computed from OneGate: `partition-id=<index> num-partitions=<total>` |
| Set by user (non-empty) | User value used as-is. Auto-computation skipped entirely. |

**Rationale:** User override takes precedence because the deployer may have a custom partitioning scheme that does not follow sequential 0-based indexing. For example, a deployer running multiple OneFlow services against the same dataset may assign partition ranges manually to avoid overlap.

### Edge Cases

**Standalone deployment (no OneFlow):** If the SuperNode is deployed as a standalone VM (not part of a OneFlow service), the OneGate `GET /service` call fails or returns no service context. In this case:
- Auto-computation is skipped.
- If `FL_NODE_CONFIG` is unset, it remains empty.
- The user MUST provide `FL_NODE_CONFIG` manually via the VM's CONTEXT variables.
- The boot script logs: "Not part of a OneFlow service; FL_NODE_CONFIG must be set manually if data partitioning is required."

**SuperNode added after initial deployment (scaling):** When a new SuperNode VM is added via `oneflow scale`, it queries the current service state from OneGate. The `nodes` array reflects the current set of VMs, including the newly added one. The new SuperNode receives a `partition-id` equal to its index in the updated array. Existing SuperNodes retain their original partition-id values (set at their boot time) and do NOT recompute.

**Node index stability:** The `deploy_id` ordering in the OneGate response is determined by VM creation order. For the initial deployment, this matches the cardinality sequence (0, 1, 2, ...). For scaled-in/scaled-out scenarios, indices may have gaps if VMs were removed. The auto-computation uses the current array index, not the deploy_id value, so the partition-id sequence is always contiguous (0 through N-1) at the time each SuperNode boots.

### Scope Limitation

Auto-computed `partition-id` is relevant only when using pre-built use case templates (`FL_USE_CASE != none`) that rely on `partition-id` and `num-partitions` in `--node-config` for data sharding. Custom ClientApps may implement their own partitioning logic (e.g., using VMID modulo, hostname hashing, or external coordination) and would set `FL_NODE_CONFIG` explicitly or ignore it entirely.

---

## 6. Deployment Sequence

This section traces the complete lifecycle of a Flower federated learning service from the moment a deployer clicks "Instantiate" to the moment the service reaches RUNNING state. The sequence demonstrates how `ready_status_gate: true` gates SuperNode deployment on SuperLink application-level readiness, ensuring that SuperNodes never boot before the SuperLink is healthy.

### End-to-End Walkthrough

**Step 1: User instantiates service template** (~0s)

The deployer instantiates the Flower Federated Learning service template via Sunstone UI or CLI. Sunstone presents the `user_inputs` form (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL at service level; FL_NUM_ROUNDS, FL_STRATEGY, etc. at SuperLink role level; ML_FRAMEWORK, FL_USE_CASE at SuperNode role level). The deployer accepts defaults or customizes values.

```bash
# CLI equivalent
oneflow-template instantiate <template_id>

# With custom values
oneflow-template instantiate <template_id> \
  --extra_template '{"custom_attrs_values": {"FLOWER_VERSION": "1.26.0", "FL_TLS_ENABLED": "YES"}}'
```

OneFlow creates a new service instance and sets its state to PENDING.

**Step 2: OneFlow creates SuperLink VM** (~5-15s)

OneFlow processes the `superlink` role first (array index 0 in `"deployment": "straight"`). It creates 1 VM from the SuperLink `template_id`, injecting the merged CONTEXT variables: service-level `user_inputs` (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL), role-level `user_inputs` (FL_NUM_ROUNDS, FL_STRATEGY, FL_MIN_FIT_CLIENTS, FL_MIN_EVALUATE_CLIENTS, FL_MIN_AVAILABLE_CLIENTS), and infrastructure `template_contents` (TOKEN=YES, REPORT_READY=YES, READY_SCRIPT_PATH, NETWORK=YES).

The service state transitions to DEPLOYING. The SuperLink VM enters PENDING, then RUNNING at the hypervisor level.

**Step 3: SuperLink boot sequence executes** (~30-90s)

The SuperLink VM runs its 12-step boot sequence (see [`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 6):

1. OS boots, contextualization agent initializes (Step 1).
2. `configure.sh` sources context variables, validates configuration, sets defaults (Steps 2-5).
3. Docker environment file and systemd unit are generated (Steps 6-8).
4. If `FL_TLS_ENABLED=YES`: TLS certificate setup executes (Step 7a, see [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md), Section 5).
5. Docker daemon readiness wait, version override handling (Steps 9-10).
6. Flower SuperLink container starts and begins listening on port 9092 (Step 10).
7. Health check loop polls TCP port 9092 until the Fleet API accepts connections (Step 11).

**Step 4: SuperLink publishes to OneGate** (~0s after health check)

Once the health check passes, `bootstrap.sh` publishes the SuperLink state to OneGate via HTTP PUT (see [`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 10):

| Attribute | Value | Source |
|-----------|-------|--------|
| `FL_READY` | `YES` | Health check passed |
| `FL_ENDPOINT` | `{vm_ip}:9092` | VM IP detection |
| `FL_VERSION` | `1.25.0` (or override) | FLOWER_VERSION variable |
| `FL_ROLE` | `superlink` | Fixed |
| `FL_TLS` | `YES` or `NO` | FL_TLS_ENABLED check (see [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md), Section 7) |
| `FL_CA_CERT` | base64 CA cert (if TLS) | `/opt/flower/certs/ca.crt` |

This publication makes the SuperLink endpoint and TLS state available to all VMs in the service via OneGate `GET /service`.

**Step 5: SuperLink VM reports READY** (~0s after publication)

The `REPORT_READY=YES` contextualization mechanism executes `READY_SCRIPT_PATH=/opt/flower/scripts/health-check.sh`. Since the health check already passed in Step 3, the script returns exit code 0. The contextualization agent calls OneGate to set `READY=YES` in the SuperLink VM's user template (see [`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 9).

**Step 6: ready_status_gate satisfied -- SuperLink role becomes RUNNING** (CRITICAL)

OneFlow detects `READY=YES` on the SuperLink VM. Because `ready_status_gate: true` is set at the service level, OneFlow's definition of "running" requires BOTH the hypervisor reporting the VM as running AND the VM's user template containing `READY=YES`. With both conditions met, OneFlow marks the `superlink` role as RUNNING.

**This is the critical gate.** Without `ready_status_gate: true`, OneFlow would consider the SuperLink VM "running" as soon as the hypervisor boots it -- before the OS loads, before Docker starts, before Flower listens on port 9092. The `supernode` role's `parents: ["superlink"]` dependency means SuperNode VMs are NOT created until the `superlink` role reaches RUNNING state. The `ready_status_gate` ensures this transition happens only after the SuperLink application is genuinely ready to accept connections.

**Step 7: OneFlow creates SuperNode VMs** (~5-15s)

With the `superlink` role RUNNING, OneFlow creates the `supernode` role's VMs. All SuperNode VMs (default: 2) are created in parallel from the SuperNode `template_id`, with the same CONTEXT injection pattern: service-level user_inputs, role-level user_inputs (ML_FRAMEWORK, FL_USE_CASE, FL_NODE_CONFIG), and infrastructure template_contents (TOKEN=YES, REPORT_READY=YES, READY_SCRIPT_PATH, NETWORK=YES).

SuperNode VMs enter PENDING, then RUNNING at the hypervisor level.

**Step 8: SuperNode boot sequence executes on each VM** (~20-35s per VM, in parallel)

Each SuperNode VM runs its 13-step boot sequence (see [`spec/02-supernode-appliance.md`](02-supernode-appliance.md), Section 7):

1. OS boots, contextualization agent initializes (Step 1).
2. `configure.sh` sources context variables, validates configuration (Steps 2-3).
3. Mount directories created, Docker configuration generated, systemd unit written (Steps 4-6).
4. If `FL_TLS_ENABLED=YES`: TLS mode detection and CA cert retrieval executes (Step 7b, see [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md)).
5. SuperLink discovery executes (Step 7) -- see Step 9 below.
6. Docker daemon wait, version override, container start (Steps 8-10).
7. Container health check (Step 11), OneGate publication (Step 12), REPORT_READY (Step 13).

**Step 9: SuperNode discovers SuperLink via OneGate** (~0s, first attempt)

During the discovery phase (Step 7 of the SuperNode boot sequence), each SuperNode queries `GET ${ONEGATE_ENDPOINT}/service` and parses the response to extract `FL_ENDPOINT` from the `superlink` role's nodes (see [`spec/02-supernode-appliance.md`](02-supernode-appliance.md), Section 6c-6d).

In a OneFlow deployment with `ready_status_gate: true`, discovery succeeds on the first attempt. The reason: SuperNode VMs were not created until the SuperLink role was RUNNING (Step 6), and the SuperLink published its `FL_ENDPOINT` to OneGate before reporting READY (Steps 4-5). By the time any SuperNode queries OneGate, the SuperLink's attributes are already available.

The discovery retry loop (30 attempts, 10-second interval, 5-minute timeout) remains in the SuperNode boot script as defense-in-depth for edge cases: OneGate caching delays, transient network issues, or non-OneFlow deployments where `ready_status_gate` is not applicable.

**Step 10: SuperNode containers start and connect** (~10-20s per VM)

Each SuperNode's Flower container starts with the discovered SuperLink address and connects to the Fleet API on port 9092 via gRPC. The connection is immediate because the SuperLink is already listening. If TLS is enabled, the SuperNode uses the CA certificate retrieved from OneGate (or provided statically) to verify the SuperLink's server certificate.

**Step 11: SuperNode VMs report READY** (~0s after container start)

Each SuperNode completes its boot sequence: the container health check passes (Docker running-state check), the SuperNode publishes its status to OneGate (FL_NODE_READY=YES, FL_NODE_ID, FL_VERSION), and `REPORT_READY` sets `READY=YES` on the VM's user template.

**Step 12: Service reaches RUNNING state** (~0s after all VMs ready)

Once all SuperNode VMs have `READY=YES` (satisfying the `ready_status_gate` for the `supernode` role), OneFlow marks the `supernode` role as RUNNING. With all roles RUNNING, the service state transitions from DEPLOYING to RUNNING. The Flower federated learning cluster is fully operational.

### Deployment Timeline

```
t=0s    User instantiates service template
        |
        +-- Service state: PENDING -> DEPLOYING
        |
t=5s    OneFlow creates SuperLink VM
        |
        +-- SuperLink boot: OS -> configure.sh -> bootstrap.sh
        |
t=35s   SuperLink health check passes (port 9092 listening)
t=35s   SuperLink publishes to OneGate (FL_READY=YES, FL_ENDPOINT)
t=35s   SuperLink reports READY=YES
        |
        +-- ready_status_gate SATISFIED
        +-- superlink role: RUNNING
        |
t=40s   OneFlow creates SuperNode VMs (all in parallel)
        |
        +-- SuperNode boot (parallel): OS -> configure.sh -> discover -> bootstrap.sh
        |
t=55s   SuperNode discovery: first attempt succeeds (SuperLink already published)
t=65s   SuperNode containers running, connected to SuperLink
t=70s   All SuperNode VMs report READY=YES
        |
        +-- supernode role: RUNNING
        +-- Service state: RUNNING
        |
t=70s   Flower cluster fully operational
```

**Nominal total time:** 60-90 seconds from instantiation to RUNNING. The dominant factor is SuperLink boot time (30-90 seconds depending on hardware and TLS generation). SuperNode boot adds ~30 seconds after the `ready_status_gate` is satisfied.

**Worst case (version override with Docker pull):** If `FLOWER_VERSION` differs from the pre-baked version, the SuperLink boot includes a Docker pull (Step 10 of its boot sequence). This can add 30-120 seconds depending on network speed, extending total deployment time to 120-210 seconds.

---

## 7. OneGate Coordination Protocol (Service Context)

This section describes how the existing OneGate publication and discovery contracts -- defined individually in Phase 1 and Phase 2 specs -- function together within the OneFlow service context. No new contracts are introduced; the orchestration spec ties together what is already specified.

### Data Flow Overview

```
SuperLink VM                       OneGate                        SuperNode VM(s)
     |                                |                                |
     | (1) Health check passes        |                                |
     |                                |                                |
     | (2) PUT /vm                    |                                |
     |   FL_READY=YES                 |                                |
     |   FL_ENDPOINT=ip:9092  ------->| Stores in                     |
     |   FL_TLS=YES|NO                | USER_TEMPLATE                 |
     |   FL_CA_CERT=<base64>          |                                |
     |                                |                                |
     | (3) REPORT_READY -> READY=YES  |                                |
     |                                |                                |
     |                                |   ready_status_gate satisfied  |
     |                                |   OneFlow creates SuperNodes   |
     |                                |                                |
     |                                |  (4) GET /service <------------|
     |                                |                                |
     |                                |  (5) Full service JSON ------->|
     |                                |                                |
     |                                |      Parse: extract            |
     |                                |      FL_ENDPOINT from          |
     |                                |      superlink role nodes      |
     |                                |                                |
     |<------ (6) gRPC connect to FL_ENDPOINT (port 9092) ------------|
     |                                                                 |
```

### SuperLink Publication (Phase 1 + Phase 2 Contracts)

The SuperLink publishes its state to OneGate as part of Step 12 of its boot sequence ([`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 10). When TLS is enabled, two additional attributes are published ([`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md), Section 7).

**Complete published attributes:**

| Attribute | Value | Defined In | Purpose |
|-----------|-------|------------|---------|
| `FL_READY` | `YES` | `spec/01`, Section 10 | Readiness flag -- used by defensive jq filter |
| `FL_ENDPOINT` | `{vm_ip}:9092` | `spec/01`, Section 10 | Fleet API address for SuperNode connections |
| `FL_VERSION` | `1.25.0` (or override) | `spec/01`, Section 10 | Running Flower version |
| `FL_ROLE` | `superlink` | `spec/01`, Section 10 | Appliance role identifier |
| `FL_TLS` | `YES` or `NO` | `spec/04`, Section 7 | TLS mode indicator |
| `FL_CA_CERT` | base64 CA cert | `spec/04`, Section 7 | CA certificate for TLS verification (only when FL_TLS=YES) |

**Publication timing relative to ready_status_gate:** OneGate publication happens BEFORE `REPORT_READY` marks the VM as `READY=YES`. The sequence is:

1. Health check passes (port 9092 listening).
2. `bootstrap.sh` publishes FL_READY, FL_ENDPOINT, FL_TLS, FL_CA_CERT to OneGate via PUT.
3. `REPORT_READY` mechanism executes `health-check.sh`, which returns 0 (already passing).
4. Contextualization agent sets `READY=YES` on the VM's user template.
5. OneFlow detects `READY=YES` and satisfies the `ready_status_gate`.

This ordering guarantees that by the time OneFlow creates SuperNode VMs, all SuperLink attributes are already available in OneGate. SuperNode discovery is not a race condition.

### SuperNode Discovery (Phase 1 Contract)

The SuperNode discovers the SuperLink via OneGate during Step 7 of its boot sequence ([`spec/02-supernode-appliance.md`](02-supernode-appliance.md), Section 6c-6d). In the OneFlow service context, discovery queries the service-scoped OneGate endpoint.

**OneGate query:**

```bash
SERVICE_JSON=$(curl -s "${ONEGATE_ENDPOINT}/service" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}")
```

**OneGate /service response structure:**

```json
{
  "SERVICE": {
    "id": "42",
    "name": "Flower Federated Learning",
    "roles": [
      {
        "name": "superlink",
        "cardinality": 1,
        "state": "2",
        "nodes": [
          {
            "deploy_id": 100,
            "running": true,
            "vm_info": {
              "VM": {
                "USER_TEMPLATE": {
                  "FL_READY": "YES",
                  "FL_ENDPOINT": "192.168.1.100:9092",
                  "FL_VERSION": "1.25.0",
                  "FL_ROLE": "superlink",
                  "FL_TLS": "YES",
                  "FL_CA_CERT": "<base64-encoded-ca-cert>"
                }
              }
            }
          }
        ]
      },
      {
        "name": "supernode",
        "cardinality": 2,
        "state": "1",
        "nodes": [
          {
            "deploy_id": 101,
            "running": true,
            "vm_info": { "VM": { "USER_TEMPLATE": {} } }
          },
          {
            "deploy_id": 102,
            "running": true,
            "vm_info": { "VM": { "USER_TEMPLATE": {} } }
          }
        ]
      }
    ]
  }
}
```

**Parsing -- standard jq filter:**

```bash
FL_ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
')
```

**Parsing -- defensive jq filter (recommended):**

For defense-in-depth, the discovery script should filter by `FL_READY=YES` rather than relying on `nodes[0]`. This handles the theoretical case where the SuperLink cardinality is incorrectly set above 1 and the first node is unhealthy:

```bash
FL_ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[]
  | select(.vm_info.VM.USER_TEMPLATE.FL_READY == "YES")
  | .vm_info.VM.USER_TEMPLATE.FL_ENDPOINT
' | head -1)
```

Similarly, TLS attributes are extracted from the same node:

```bash
FL_TLS=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[]
  | select(.vm_info.VM.USER_TEMPLATE.FL_READY == "YES")
  | .vm_info.VM.USER_TEMPLATE.FL_TLS // empty
')

FL_CA_CERT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[]
  | select(.vm_info.VM.USER_TEMPLATE.FL_READY == "YES")
  | .vm_info.VM.USER_TEMPLATE.FL_CA_CERT // empty
')
```

### Discovery Behavior in OneFlow vs Standalone

| Scenario | Discovery Behavior | Retry Expected |
|----------|-------------------|----------------|
| OneFlow with `ready_status_gate: true` | First attempt succeeds. SuperLink published before SuperNode was created. | No (defense-in-depth only) |
| OneFlow with `ready_status_gate: false` | SuperLink may not be ready. Retry loop executes until FL_ENDPOINT appears. | Yes (1-30 attempts typical) |
| OneFlow with `"deployment": "none"` | Race condition. SuperNodes and SuperLink boot simultaneously. Retry loop handles timing. | Yes (often full 30 attempts) |
| Standalone VM (no OneFlow) | OneGate unavailable (no service context). Static `FL_SUPERLINK_ADDRESS` required. | N/A (static mode) |

### OneGate Prerequisite: TOKEN=YES

Both SuperLink and SuperNode VM templates MUST have `TOKEN=YES` in their CONTEXT section. This variable instructs the contextualization agent to request an authentication token from OpenNebula and write it to `/run/one-context/token.txt`. Without this token:

- SuperLink cannot publish to OneGate (PUT fails with HTTP 401).
- SuperNode cannot query OneGate (GET fails with HTTP 401).
- `REPORT_READY` cannot set `READY=YES` on the VM (OneGate call fails).

`TOKEN=YES` is set in the `template_contents` of each role (see Section 3). It is an infrastructure-level variable, not a user_input, because deployers should never need to modify it.

---

## 8. Scaling Operations

The SuperNode role supports runtime scaling within the bounds defined by `min_vms` and `max_vms`. The SuperLink role is a hard singleton and cannot be scaled.

### Scale SuperNode Count Up

```bash
# Scale to 5 SuperNodes (from current count)
oneflow scale <service_id> supernode 5
```

New SuperNode VMs follow the same boot sequence as the initial deployment (Steps 8-13 from Section 6):

1. OneFlow creates the additional SuperNode VMs from the `template_id` with the same CONTEXT variables.
2. Each new VM boots, runs `configure.sh`, and executes OneGate discovery.
3. Discovery succeeds immediately -- the SuperLink has been publishing its endpoint since the initial deployment.
4. New containers start, connect to the SuperLink's Fleet API, and report READY.
5. The service may temporarily enter SCALING state while new VMs are deploying, then returns to RUNNING once all VMs report READY.

**Partition-id for scaled VMs:** New SuperNode VMs compute their `partition-id` from the updated `nodes` array in the OneGate service response (see Section 5). The new VM's index in the current array determines its `partition-id`. Existing SuperNodes retain their original values computed at their boot time.

**Limitation:** Partition-id values assigned during scale-up may conflict with the original partitioning scheme if VMs were previously removed (see Section 5, Edge Cases). For production deployments requiring strict data partition isolation, use `FL_NODE_CONFIG` override with externally managed partition assignments.

**Interaction with FL_MIN_FIT_CLIENTS:** Scaling up the SuperNode count is useful when the current count is below `FL_MIN_FIT_CLIENTS` or `FL_MIN_AVAILABLE_CLIENTS`. Adding SuperNodes to meet the threshold allows training rounds to begin. Conversely, scaling above the threshold provides more data diversity per round.

### Scale SuperNode Count Down

```bash
# Scale down to 3 SuperNodes (from current count)
oneflow scale <service_id> supernode 3
```

OneFlow removes VMs to reach the target cardinality (newest VMs removed first by default):

1. OneFlow sends shutdown to the excess SuperNode VMs.
2. Docker receives SIGTERM, the Flower SuperNode container shuts down gracefully.
3. The SuperLink detects client disconnection and removes the SuperNode from its active client list.
4. Active training rounds continue if the remaining connected clients meet the `FL_MIN_FIT_CLIENTS` threshold.
5. If the remaining client count drops below `FL_MIN_FIT_CLIENTS`, the current training round fails and the SuperLink waits for enough clients before starting the next round.

**Floor enforcement:** OneFlow rejects scale-down requests below `min_vms` (default: 2):

```bash
# This fails:
oneflow scale <service_id> supernode 1
# Error: cannot scale role "supernode" below min_vms (2)
```

### SuperLink Cannot Be Scaled

The SuperLink role has `min_vms: 1` and `max_vms: 1`. Any scaling request is rejected by OneFlow:

```bash
# This fails:
oneflow scale <service_id> superlink 2
# Error: cannot scale role "superlink" above max_vms (1)
```

The `--force` flag bypasses min/max bounds but MUST NOT be used on the SuperLink role. Multiple SuperLink instances create independent coordinators with no shared state, causing a split-brain federation failure (see Section 4).

### Service Status Inspection

```bash
# Show full service status including role states and VM details
oneflow show <service_id>

# JSON output for programmatic access
oneflow show <service_id> --json
```

The output includes each role's current state, cardinality, and per-VM details (ID, IP, READY status).

### Elasticity Policies

OneFlow supports automatic scaling of the SuperNode role via `elasticity_policies` that evaluate expression-based triggers at configurable intervals. The complete auto-scaling specification -- including expression syntax, FL-aware custom metrics, cooldown periods, and interaction with active training rounds -- is defined in [`spec/14-edge-and-auto-scaling.md`](14-edge-and-auto-scaling.md), Sections 6-9.

Key constraints (restated from Section 4): Elasticity policies MUST NOT be defined on the `superlink` role. `min_vms` must be >= `FL_MIN_FIT_CLIENTS` to prevent training deadlock.

---

## 9. Service Lifecycle Management

This section defines the operational lifecycle of a deployed Flower federated learning service: state transitions, management commands, failure handling, and shutdown behavior.

### Service State Machine

```
PENDING ──> DEPLOYING ──> RUNNING ──> UNDEPLOYING ──> DONE
                |             |
                |             +──> SCALING ──> RUNNING
                |             |
                |             +──> WARNING
                |
                +──> FAILED_DEPLOYING
```

| State | Meaning |
|-------|---------|
| PENDING | Service created, no VMs deployed yet. |
| DEPLOYING | Roles are being deployed sequentially (straight deployment). SuperLink role deploys first, then SuperNode role after `ready_status_gate` is satisfied. |
| RUNNING | All roles have reached RUNNING state. The Flower cluster is fully operational. |
| SCALING | A scale operation is in progress. New VMs are being created or excess VMs are being removed. |
| WARNING | One or more VMs are in an unexpected state (e.g., SuperLink VM rebooted). The service is partially operational. |
| UNDEPLOYING | VMs are being terminated in reverse dependency order. |
| DONE | All VMs terminated. Service is complete. |
| FAILED_DEPLOYING | A role failed to deploy (e.g., SuperLink health check timed out). Manual intervention required. |

### Deploy

**Via Sunstone UI:** Navigate to OneFlow Templates, select "Flower Federated Learning", click Instantiate. Fill in user_inputs when prompted. Click Deploy.

**Via CLI:**

```bash
# Default deployment
oneflow-template instantiate <template_id>

# With parameter overrides
oneflow-template instantiate <template_id> \
  --extra_template '{"custom_attrs_values": {
    "FLOWER_VERSION": "1.26.0",
    "FL_TLS_ENABLED": "YES",
    "FL_NUM_ROUNDS": "10",
    "FL_STRATEGY": "FedProx",
    "ML_FRAMEWORK": "tensorflow"
  }}'
```

### Show Status

```bash
oneflow show <service_id>
```

The output displays the service state, each role's state and cardinality, and per-VM details.

### Undeploy

```bash
oneflow delete <service_id>
```

OneFlow terminates VMs in reverse dependency order:

1. **SuperNode VMs terminated first.** Each SuperNode container receives SIGTERM (via the `"shutdown_action": "shutdown"` setting). Docker forwards SIGTERM to the Flower process, which disconnects from the SuperLink and exits cleanly.

2. **SuperLink VM terminated last.** After all SuperNode VMs are terminated, the SuperLink VM is shut down. The SuperLink's SQLite state database is written cleanly during the graceful shutdown.

**Why reverse order matters:** Terminating the SuperLink first would cause all SuperNode containers to lose their gRPC connection simultaneously, triggering reconnection loops that will never succeed. The reverse order ensures SuperNodes shut down gracefully while the SuperLink is still available.

### Shutdown Action

The service template specifies `"shutdown_action": "shutdown"` at both the service and role levels. This means:

- VMs receive an ACPI shutdown signal (equivalent to pressing the power button).
- The guest OS processes the signal, systemd stops services in order, and Docker sends SIGTERM to containers.
- Flower processes handle SIGTERM gracefully: in-progress operations complete, connections close, and the process exits with code 0.

The alternative `"shutdown-hard"` sends an immediate power-off (equivalent to pulling the power cord). This risks corrupting the SuperLink's SQLite state database and is NOT recommended.

### Failure Handling

**SuperLink fails to report READY during initial deployment:**

The service remains in DEPLOYING state. OneFlow waits for the `ready_status_gate` to be satisfied. If the SuperLink VM's health check times out (120 seconds), the VM publishes `FL_READY=NO` and does not report `READY=YES`. The service eventually transitions to FAILED_DEPLOYING after the OneFlow service timeout.

The operator should inspect SuperLink logs:
```bash
# SSH into the SuperLink VM
ssh root@<superlink_ip>

# Check boot logs
cat /var/log/one-appliance/flower-configure.log
cat /var/log/one-appliance/flower-bootstrap.log

# Check container logs
docker logs flower-superlink

# Check systemd service
journalctl -u flower-superlink
```

**A SuperNode fails to report READY:**

Other SuperNode VMs may still report READY independently. Whether the service transitions to RUNNING depends on whether the minimum VM threshold is met. If `min_vms: 2` and only 1 of 2 SuperNodes reports READY, the `supernode` role does not reach RUNNING and the service remains in DEPLOYING.

**SuperLink VM crashes after service is RUNNING:**

The SuperLink VM's systemd restart policy (`RestartPolicy: unless-stopped` on the Docker container) restarts the Flower container automatically. SuperNode containers, configured with `--max-retries 0` (unlimited reconnection), continuously attempt to reconnect to the SuperLink's Fleet API. Once the SuperLink container restarts and begins listening on port 9092, SuperNodes reconnect and training resumes.

During the outage, the service may transition to WARNING state in OneFlow. The `REPORT_READY` mechanism re-evaluates on container restart: when the health check passes again, `READY=YES` is restored.

When checkpointing is enabled (`FL_CHECKPOINT_ENABLED=YES`), the restarted container loads the latest checkpoint as the initial model weights, resuming training from the last saved state rather than starting from scratch. See [`spec/09-training-configuration.md`](09-training-configuration.md), Sections 7 and 9 for the complete failure recovery specification.

**A SuperNode VM crashes after service is RUNNING:**

The remaining SuperNodes continue training. The SuperLink detects the disconnection and adjusts the active client count. If the remaining count is still at or above `FL_MIN_FIT_CLIENTS`, training rounds continue normally. If below, the SuperLink waits for reconnection or new clients before starting the next round.

---

## 10. Anti-Patterns and Pitfalls

Common misconfigurations that cause deployment failures or degraded operation. Each entry describes what goes wrong and the correct approach.

| Anti-Pattern | What Goes Wrong | Correct Approach |
|-------------|----------------|-----------------|
| Setting `ready_status_gate: false` | SuperNode VMs deploy before the SuperLink application is ready. SuperNodes enter the discovery retry loop (30 attempts, 10-second interval) and waste up to 5 minutes waiting. In the worst case, the SuperLink is still pulling a Docker image and SuperNodes time out entirely. | Always set `ready_status_gate: true` at the service level. This gates SuperNode creation on SuperLink application-level health, ensuring first-attempt discovery success. |
| SuperLink cardinality > 1 | Multiple independent SuperLink instances create a split-brain federation. Each SuperLink maintains its own `state.db`, tracks a different subset of SuperNodes, and produces different aggregation results. SuperNode discovery selects one SuperLink (via `nodes[0]` or the first `FL_READY=YES` match), leaving the other SuperLink idle or partially connected. | Enforce `min_vms: 1, max_vms: 1` on the SuperLink role. Never use `--force` to scale above 1. See Section 4 for the singleton constraint rationale. |
| Duplicating `user_inputs` at both service and role level | Role-level `user_inputs` silently override service-level values for the same key. If `FLOWER_VERSION` is defined at both levels with different defaults, the role-level value wins. This creates version mismatch between SuperLink and SuperNode (e.g., SuperLink runs 1.25.0 while SuperNode runs 1.26.0), causing gRPC protocol errors. | Define each variable at exactly one level. Service-level for variables that must be identical across roles (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL). Role-level for variables specific to one role. See Section 2, Variable Placement Rule. |
| Missing `TOKEN=YES` in VM template CONTEXT | All OneGate API calls fail with HTTP 401 (Unauthorized). The SuperLink cannot publish `FL_ENDPOINT` or `FL_CA_CERT`. SuperNodes cannot discover the SuperLink. `REPORT_READY` cannot set `READY=YES`, so the `ready_status_gate` is never satisfied and the service hangs in DEPLOYING state indefinitely. | Always include `TOKEN=YES` in each role's `template_contents` CONTEXT section. This is an infrastructure variable, not a user_input. See Section 2, Infrastructure CONTEXT Variables. |
| Putting infrastructure vars (`TOKEN`, `REPORT_READY`) in `user_inputs` instead of `template_contents` | The variables appear in the Sunstone instantiation form, confusing deployers who may change or remove them. If a deployer sets `TOKEN=NO` or deletes the field, OneGate authentication breaks silently. | Place infrastructure variables in `template_contents` at the role level. They are injected unconditionally and do not appear in the user-facing instantiation form. See Section 3, template_contents. |
| Setting `FL_SUPERLINK_ADDRESS` in OneFlow deployment | Bypasses OneGate discovery entirely. The static address must match the SuperLink VM's actual IP, which is not known until the VM is created. If the operator guesses wrong or the IP changes on redeployment, all SuperNodes fail to connect. Defeats the purpose of OneFlow orchestration. | Leave `FL_SUPERLINK_ADDRESS` unset in OneFlow deployments. Let SuperNodes discover the SuperLink via OneGate automatically. Static addresses are intended for standalone VM deployments or cross-site federation (Phase 7, see [`spec/12-multi-site-federation.md`](12-multi-site-federation.md)), not single-site OneFlow services. |
| Elasticity policies on the `superlink` role | Auto-scaling the singleton coordinator triggers split-brain (same as cardinality > 1). Even if `max_vms: 1` prevents the scale-up, the policy evaluation adds unnecessary overhead and signals a misunderstanding of the architecture. | Never define `elasticity_policies` or `scheduled_policies` on the SuperLink role. Elasticity policies apply only to the `supernode` role. See Section 8, Elasticity Policies. See [`spec/14-edge-and-auto-scaling.md`](14-edge-and-auto-scaling.md), Section 10 for additional auto-scaling anti-patterns. |
| Using `deployment: "none"` instead of `"straight"` | All roles deploy simultaneously. SuperNode VMs boot before the SuperLink VM, enter the discovery retry loop, and spend up to 5 minutes in retries. With `ready_status_gate: true`, SuperNode creation is still gated, but with `ready_status_gate: false` (or if accidentally set), the race condition is fully exposed. Even with the gate, `"none"` loses the clear sequential semantics that make the deployment predictable. | Always use `deployment: "straight"`. Roles deploy in array order (SuperLink first, SuperNode second), and the `parents` dependency combined with `ready_status_gate` ensures correct ordering. |

---

*Specification for ORCH-01: Single-Site Orchestration*
*Phase: 04 - Single-Site Orchestration (updated Phase 9)*
*Version: 1.2*
