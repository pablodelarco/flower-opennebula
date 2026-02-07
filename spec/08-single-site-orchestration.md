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
