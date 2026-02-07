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
- Multi-site federation across OpenNebula zones (Phase 7).
- Auto-scaling triggers and elasticity policies (Phase 9).
- Training configuration, aggregation strategy internals, and checkpointing (Phase 5).

**Cross-references:**
- SuperLink appliance: [`spec/01-superlink-appliance.md`](01-superlink-appliance.md) -- VM template, boot sequence, OneGate publication contract (Section 10), parameters (Section 12).
- SuperNode appliance: [`spec/02-supernode-appliance.md`](02-supernode-appliance.md) -- VM template, discovery model (Section 6), parameters (Section 13).
- Contextualization reference: [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) -- complete variable definitions, USER_INPUT format, validation rules.
- TLS certificate lifecycle: [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md) -- SuperLink TLS generation and OneGate CA cert publication.
- SuperNode TLS trust: [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md) -- CA cert retrieval and TLS mode detection.
- ML framework variants: [`spec/06-ml-framework-variants.md`](06-ml-framework-variants.md) -- `ML_FRAMEWORK` variable and framework-specific Docker images.
- Use case templates: [`spec/07-use-case-templates.md`](07-use-case-templates.md) -- `FL_USE_CASE` variable and pre-built Flower App Bundles.

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
        "FL_STRATEGY": "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam|FedAvg",
        "FL_MIN_FIT_CLIENTS": "O|number|Minimum clients for training round||2",
        "FL_MIN_EVALUATE_CLIENTS": "O|number|Minimum clients for evaluation||2",
        "FL_MIN_AVAILABLE_CLIENTS": "O|number|Minimum available clients to start||2"
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
| `user_inputs` | (5 variables) | SuperLink-specific parameters: training rounds, aggregation strategy, client thresholds. Not propagated to SuperNode VMs. |
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
