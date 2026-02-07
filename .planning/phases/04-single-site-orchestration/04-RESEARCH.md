# Phase 4: Single-Site Orchestration - Research

**Researched:** 2026-02-07
**Domain:** OpenNebula OneFlow service templates, OneGate service discovery, multi-role VM orchestration
**Confidence:** HIGH

## Summary

Phase 4 specifies the OneFlow service template that deploys a complete Flower federated learning cluster (1 SuperLink + N SuperNodes) as a single orchestrated service. The research investigated three primary domains: (1) OneFlow service template structure including deployment strategies, role dependencies, and cardinality configuration; (2) the OneGate coordination protocol for inter-VM service discovery within a OneFlow service; and (3) the critical `ready_status_gate` + `REPORT_READY` interaction that gates child role deployment on parent application-level readiness.

Key findings resolve the blocker noted in STATE.md: OpenNebula's `ready_status_gate` feature, when set to `true` at the service level, explicitly waits for VMs to have `READY=YES` in their user template before considering them running for role dependency purposes. Combined with the appliance's `REPORT_READY=YES` context variable and `READY_SCRIPT_PATH` pointing to the health check, this means OneFlow will NOT deploy SuperNode VMs until the SuperLink's Flower container is actually listening on port 9092. The SuperNode retry loop provides additional defense-in-depth.

The standard approach is a JSON service template with `"deployment": "straight"` and `"ready_status_gate": true`, defining two roles: a `superlink` parent role (cardinality 1) and a `supernode` child role (cardinality N, with `parents: ["superlink"]`). Service-level `user_inputs` propagate shared configuration (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL) to all roles, while role-level inputs handle role-specific parameters.

**Primary recommendation:** Define a complete OneFlow service template JSON with straight deployment, ready_status_gate enabled, and the OneGate coordination protocol leveraging the existing SuperLink publication contract and SuperNode discovery mechanism from Phases 1 and 2.

## Standard Stack

The established platform components for this domain:

### Core
| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| OpenNebula OneFlow | 7.0+ | Multi-VM service orchestration with role dependencies | Built-in OpenNebula component; the only supported way to deploy multi-role services |
| OpenNebula OneGate | 7.0+ | Inter-VM attribute publication and service discovery | Built-in OpenNebula component; provides the GET /service endpoint for cross-role data access |
| one-apps contextualization | latest | Guest agent providing REPORT_READY, READY_SCRIPT, TOKEN | Standard OpenNebula guest agent; handles READY=YES reporting to OneGate |

### Supporting
| Component | Version | Purpose | When to Use |
|-----------|---------|---------|-------------|
| `oneflow-template` CLI | 7.0+ | Service template registration and management | Template creation during marketplace publishing |
| `oneflow` CLI | 7.0+ | Service instantiation, scaling, lifecycle management | Operational management of deployed services |
| `onegate` CLI (in-VM) | latest | In-VM OneGate client for attribute push/pull | Alternative to curl for OneGate API calls in scripts |
| Sunstone UI | 7.0+ | Web-based service template instantiation with user inputs | Primary deployer interface for marketplace users |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| OneFlow service template | Manual VM deployment with static IPs | Loses automatic dependency ordering, scaling, service lifecycle management |
| OneGate dynamic discovery | Static FL_SUPERLINK_ADDRESS in all SuperNodes | Works but requires manual IP management; breaks zero-config deployment |
| `ready_status_gate: true` | `ready_status_gate: false` with only retry loop | Child roles deploy before SuperLink is ready; relies entirely on retry loop (defense-in-depth becomes primary mechanism) |

## Architecture Patterns

### Recommended Service Template Structure

```
OneFlow Service Template: "Flower Federated Learning"
|
+-- Service-level user_inputs (shared across all roles):
|     FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL
|
+-- Role: superlink (parent)
|     cardinality: 1
|     template_id: <SuperLink VM template ID>
|     role-level user_inputs: FL_NUM_ROUNDS, FL_STRATEGY, etc.
|     No parents (root role)
|
+-- Role: supernode (child)
      cardinality: 2 (default), min_vms: 2, max_vms: 10
      template_id: <SuperNode VM template ID>
      parents: ["superlink"]
      role-level user_inputs: ML_FRAMEWORK, FL_USE_CASE, etc.
```

### Pattern 1: Straight Deployment with Ready Status Gate

**What:** The service template uses `"deployment": "straight"` combined with `"ready_status_gate": true` to enforce strict ordering: SuperLink VMs must be fully operational (application-level ready, not just hypervisor-booted) before SuperNode VMs are created.

**When to use:** Always for Flower cluster deployment. The SuperLink must be listening on port 9092 before SuperNodes can meaningfully attempt connection.

**How it works:**

```
1. OneFlow creates SuperLink VM(s)
2. SuperLink boots -> contextualization runs -> configure.sh -> bootstrap.sh
3. SuperLink health check passes (port 9092 listening)
4. SuperLink publishes FL_READY=YES, FL_ENDPOINT, FL_TLS, FL_CA_CERT to OneGate
5. one-context REPORT_READY sets READY=YES in VM user template
6. OneFlow detects READY=YES on all SuperLink VMs (ready_status_gate satisfied)
7. OneFlow marks superlink role as RUNNING
8. OneFlow creates SuperNode VM(s) (child role deployment begins)
9. SuperNodes boot -> discover SuperLink via OneGate -> connect -> report ready
10. All roles RUNNING -> service state becomes RUNNING
```

**Critical detail (resolves STATE.md blocker):** When `ready_status_gate` is `true`, OneFlow's definition of "running" for a VM requires BOTH:
- OpenNebula's hypervisor reporting the VM is running (LCM_STATE==3, STATE>=3)
- The VM's user template containing `READY=YES`

The `REPORT_READY=YES` context variable triggers the one-context agent to call OneGate to set `READY=YES` on the VM's user template. When combined with `READY_SCRIPT_PATH=/opt/flower/scripts/health-check.sh`, this is gated on the Flower container actually being ready. This means child roles (SuperNode) are NOT deployed until the SuperLink application is healthy. The SuperNode retry loop remains valuable as defense-in-depth for edge cases (e.g., OneGate delays, race conditions).

**Confidence:** HIGH -- verified across OpenNebula 6.2 through 7.0 documentation. The `ready_status_gate` behavior is explicitly documented.

### Pattern 2: Service-Level User Inputs for Shared Configuration

**What:** Variables that must be identical across both roles (like FLOWER_VERSION and FL_TLS_ENABLED) are defined as service-level `user_inputs`. OneFlow automatically propagates these to all roles' VM CONTEXT.

**When to use:** For any configuration parameter that must be consistent across the SuperLink and all SuperNodes.

**How it works:**

Service-level user_inputs are defined in the service template JSON:
```json
{
  "user_inputs": {
    "FLOWER_VERSION": "O|text|Flower Docker image version tag||1.25.0",
    "FL_TLS_ENABLED": "O|boolean|Enable TLS encryption||NO",
    "FL_LOG_LEVEL": "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
  }
}
```

OneFlow automatically adds these to `template_contents` for all roles and they appear in each VM's CONTEXT. The user is prompted once at instantiation time (not per-role).

Role-level user_inputs override service-level ones when both define the same key. This allows role-specific defaults while maintaining service-level consistency for shared parameters.

**Confidence:** HIGH -- documented in OpenNebula 7.0 OneFlow documentation. "All User Inputs will be automatically added to template_contents by OneFlow... all values provided by the user will be accessible from within the Role's machines via OpenNebula's context packages."

### Pattern 3: OneGate Coordination Protocol (Inter-Role Discovery)

**What:** The SuperLink pushes its endpoint and TLS state to OneGate via PUT after becoming ready. SuperNodes retrieve this information via GET /service during their discovery phase.

**When to use:** Always in OneFlow deployments (this is the dynamic discovery path).

**Protocol flow:**

```
SuperLink (after health check passes):
  PUT ${ONEGATE_ENDPOINT}/vm
    FL_READY=YES
    FL_ENDPOINT=${MY_IP}:9092
    FL_VERSION=${FLOWER_VERSION}
    FL_ROLE=superlink
    FL_TLS=YES|NO
    FL_CA_CERT=<base64> (if TLS)

SuperNode (during discovery phase):
  GET ${ONEGATE_ENDPOINT}/service
  -> Parse response:
     .SERVICE.roles[] | select(.name == "superlink")
     | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT
  -> Extract FL_TLS, FL_CA_CERT similarly
```

**OneGate response structure (verified):**
```json
{
  "SERVICE": {
    "id": "...",
    "name": "...",
    "roles": [
      {
        "name": "superlink",
        "cardinality": 1,
        "state": "...",
        "nodes": [
          {
            "deploy_id": "...",
            "running": true,
            "vm_info": {
              "VM": {
                "USER_TEMPLATE": {
                  "FL_READY": "YES",
                  "FL_ENDPOINT": "192.168.1.100:9092",
                  "FL_VERSION": "1.25.0",
                  "FL_ROLE": "superlink",
                  "FL_TLS": "YES",
                  "FL_CA_CERT": "<base64>"
                }
              }
            }
          }
        ]
      },
      {
        "name": "supernode",
        "cardinality": 2,
        "state": "...",
        "nodes": [...]
      }
    ]
  }
}
```

**Confidence:** HIGH -- the OneGate `/service` response structure and PUT mechanism are documented consistently across all OpenNebula versions from 5.x through 7.0.

### Pattern 4: Parent Role Attribute References (Static IP Injection)

**What:** OneFlow supports `${ROLE_NAME.xpath.path}` syntax in child role `template_contents` to reference parent role template attributes at instantiation time.

**When to use:** Could be used as an alternative to OneGate discovery for injecting SuperLink IP into SuperNode CONTEXT. However, this has limitations.

**Syntax:** `${superlink.template.context.eth0_ip}` would reference the superlink role's ETH0_IP context variable.

**Limitations (MEDIUM confidence):**
- Only works with `"deployment": "straight"` and established parent-child relationships
- The referenced attribute must exist in the parent VM's template at deployment time
- ETH0_IP may or may not be reliably populated in the template CONTEXT at the time the child role resolves the reference
- The IP is resolved from the VM template, not from runtime monitoring data
- This approach is less documented and tested than OneGate-based discovery

**Recommendation:** Do NOT rely on `${superlink.template.context.eth0_ip}` for primary discovery. OneGate-based discovery (Pattern 3) is the proven, documented mechanism. The parent reference syntax is better suited for passing user-defined attributes (like database names), not dynamically assigned network addresses.

**Confidence:** MEDIUM -- syntax is documented but IP resolution reliability is unverified (matches open question #3 from spec/00-overview.md).

### Anti-Patterns to Avoid

- **Hardcoding SuperLink IP in service template:** Defeats the purpose of OneFlow orchestration. Each deployment gets different IPs.
- **Using `"deployment": "none"` for Flower clusters:** All VMs deploy simultaneously, creating a race condition where SuperNodes may start before SuperLink. The retry loop handles this, but it wastes 30-300 seconds and creates confusing log output.
- **Setting `ready_status_gate: false` with parent dependencies:** Child roles deploy the instant the parent VM's hypervisor reports RUNNING, which is before the OS even boots. SuperNodes would always hit the full retry loop.
- **Putting all variables in `template_contents` instead of `user_inputs`:** Users cannot customize the deployment via Sunstone. Variables must be in `user_inputs` to be prompted during instantiation.
- **SuperLink cardinality > 1:** Flower SuperLink is a singleton coordinator. Multiple SuperLink instances would create split-brain federation issues.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Deployment ordering | Custom wait scripts between VMs | OneFlow `straight` deployment + `ready_status_gate` | OneFlow handles ordering, retry, and failure recovery natively |
| Service discovery | DNS-based or config management tools | OneGate PUT/GET within the OneFlow service | OneGate is scoped to the service, requires no extra infrastructure |
| Variable propagation | Shell scripts copying vars between VMs | OneFlow `user_inputs` with automatic CONTEXT propagation | OneFlow handles this at instantiation time for all roles |
| Auto-scaling | Custom cron jobs or watchers | OneFlow elasticity policies | Built-in to OneFlow with cooldown, min/max bounds, expression evaluation |
| Service lifecycle | Manual VM management scripts | OneFlow service states (deploy, scale, undeploy, shutdown) | Handles reverse-order shutdown, failure detection, role state tracking |
| Ready gating | Custom scripts polling OneGate in a loop before deploying child VMs | `ready_status_gate: true` at service template level | OneFlow's built-in mechanism, tested across versions |

**Key insight:** OneFlow and OneGate together provide the complete orchestration stack needed for Flower cluster deployment. The existing SuperLink publication contract (FL_READY, FL_ENDPOINT, FL_TLS, FL_CA_CERT) and SuperNode discovery mechanism (OneGate GET /service with jq parsing) already implement the coordination protocol. Phase 4 wraps these in a service template definition.

## Common Pitfalls

### Pitfall 1: Forgetting `ready_status_gate: true`

**What goes wrong:** SuperNode VMs deploy before SuperLink is ready. Every SuperNode hits the full 5-minute discovery retry loop, and if the SuperLink boot is slow (e.g., Docker pull for version override), some SuperNodes may time out.
**Why it happens:** The default value for `ready_status_gate` is `false`, meaning OneFlow considers VMs running as soon as the hypervisor boots them. This is before the OS loads, let alone the Flower container.
**How to avoid:** Always set `"ready_status_gate": true` in the service template. This is the single most important configuration decision for Flower cluster orchestration.
**Warning signs:** SuperNode logs show 30 discovery attempts before finding the SuperLink endpoint; all SuperNodes report ready at approximately the same time (5+ minutes after boot).

### Pitfall 2: Service-Level vs Role-Level User Input Conflicts

**What goes wrong:** A variable defined at both service and role level causes unexpected values. Role-level takes precedence over service-level.
**Why it happens:** The precedence rule is documented but easy to forget. If FLOWER_VERSION is defined at both levels, the role-level value wins.
**How to avoid:** Define shared variables (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL) ONLY at the service level. Define role-specific variables (FL_NUM_ROUNDS for SuperLink, ML_FRAMEWORK for SuperNode) ONLY at the role level. Never duplicate a variable at both levels unless intentionally overriding.
**Warning signs:** SuperLink and SuperNode running different Flower versions despite the user setting it once. gRPC protocol errors at runtime.

### Pitfall 3: SuperLink Cardinality > 1

**What goes wrong:** Multiple SuperLink instances create independent Flower coordinators. SuperNodes discover one randomly via OneGate (the jq filter takes `nodes[0]`). The federation is split.
**Why it happens:** An operator sets `cardinality: 2` thinking it adds redundancy.
**How to avoid:** Hard-constrain SuperLink cardinality to 1. Set `min_vms: 1` and `max_vms: 1` for the superlink role. Document clearly that Flower SuperLink is a singleton.
**Warning signs:** Two SuperLink VMs running; SuperNodes connect to different SuperLinks; training rounds have inconsistent client counts.

### Pitfall 4: Missing TOKEN=YES in VM Templates

**What goes wrong:** OneGate API calls fail with authentication errors. SuperLink cannot publish FL_ENDPOINT; SuperNodes cannot discover SuperLink; REPORT_READY fails.
**Why it happens:** `TOKEN=YES` must be in the VM template's CONTEXT section. If the base VM template omits it, OneFlow does not add it automatically.
**How to avoid:** Verify both VM templates (SuperLink and SuperNode) have `TOKEN=YES` in their CONTEXT section. This is an infrastructure-level variable, not a user input.
**Warning signs:** OneGate calls return HTTP 401; `/run/one-context/token.txt` does not exist in the VM; SuperNode discovery immediately fails with "OneGate not available."

### Pitfall 5: Incorrect OneGate jq Path for Multi-Node Roles

**What goes wrong:** If the superlink role ever has cardinality > 1 (it should not, but defensive coding matters), the jq filter `.nodes[0]` always selects the first node. If that node is unhealthy, SuperNodes connect to a non-functional SuperLink.
**Why it happens:** The jq filter uses a fixed index `[0]` instead of filtering by FL_READY=YES.
**How to avoid:** Keep SuperLink cardinality at 1. For defense-in-depth, the jq filter could select nodes where FL_READY=YES:
```bash
.SERVICE.roles[] | select(.name == "superlink")
| .nodes[] | select(.vm_info.VM.USER_TEMPLATE.FL_READY == "YES")
| .vm_info.VM.USER_TEMPLATE.FL_ENDPOINT
```
**Warning signs:** SuperNode connects but gets connection refused; SuperLink VM exists but is unhealthy.

### Pitfall 6: Elasticity Policies on SuperLink Role

**What goes wrong:** Auto-scaling adds or removes SuperLink instances, breaking the singleton model.
**Why it happens:** Copy-paste from a generic multi-tier service template that has elasticity on all roles.
**How to avoid:** Never define elasticity_policies on the superlink role. Only the supernode role should have scaling capability. Set `min_vms: 1, max_vms: 1` on superlink to make it impossible to scale.
**Warning signs:** Service enters SCALING state for the superlink role; multiple superlink VMs appear.

## Code Examples

### Complete OneFlow Service Template (Flower Federated Learning)

```json
{
  "name": "Flower Federated Learning",
  "description": "1 SuperLink + N SuperNodes for federated learning",
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
      }
    }
  ]
}
```

**Notes:**
- `template_id: 0` is a placeholder. The actual VM template IDs are assigned at marketplace registration time.
- Service-level user_inputs (FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL) are shared across both roles.
- Role-level user_inputs are role-specific: SuperLink gets strategy/rounds, SuperNode gets framework/use-case.
- `min_vms: 1, max_vms: 1` on superlink prevents scaling the singleton coordinator.
- `min_vms: 2, max_vms: 10` on supernode provides a reasonable default range for FL (minimum 2 for meaningful federated learning).

### OneGate Discovery jq Filter (from SuperNode discover.sh)

```bash
# Already defined in spec/02-supernode-appliance.md Section 6c
# Included here for reference in the orchestration context

SERVICE_JSON=$(curl -s "${ONEGATE_ENDPOINT}/service" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}")

FL_ENDPOINT=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT // empty
')
```

### Manual Scaling Command (SuperNode Cardinality)

```bash
# Scale SuperNode count to 5
oneflow scale <service_id> supernode 5

# Scale with force (override min/max bounds)
oneflow scale <service_id> supernode 15 --force

# From inside a service VM via OneGate
onegate service scale --role supernode --cardinality 5
```

### Service Lifecycle Commands

```bash
# Create service from template
oneflow-template create flower-service.json

# List templates
oneflow-template list

# Instantiate a service
oneflow-template instantiate <template_id>

# Instantiate with overrides
oneflow-template instantiate <template_id> \
  --extra_template '{"custom_attrs_values": {"FLOWER_VERSION": "1.26.0"}}'

# Check service status
oneflow show <service_id>

# Undeploy (reverse order: SuperNodes first, then SuperLink)
oneflow delete <service_id>
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `custom_attrs` for service variables | `user_inputs` (same concept, renamed) | OpenNebula 6.8+ | Aligns OneFlow with VM template concepts. Use `user_inputs` in JSON. |
| `vm_template_contents` as KEY=VALUE string | `template_contents` as JSON object | OpenNebula 7.0 | Easier to read and manipulate. Can use nested objects. |
| `vm_template` field for role template reference | `template_id` field | OpenNebula 7.0 | Renamed for clarity. Same function -- references the VM template ID. |
| Manual READY=YES via custom scripts | `REPORT_READY=YES` + `READY_SCRIPT_PATH` | OpenNebula 6.10 (one-apps) | Built-in conditional readiness reporting. The `READY_SCRIPT_PATH` feature was added in one-apps for OpenNebula 6.10.0. |

**Deprecated/outdated:**
- `custom_attrs` has been renamed to `user_inputs` in recent OpenNebula versions. Both may work but `user_inputs` is the current naming.
- `vm_template_contents` (string format) is being replaced by `template_contents` (JSON object format) in OpenNebula 7.0. The spec should use the newer format.
- `vm_template` (integer) is being renamed to `template_id` in OpenNebula 7.0. Use `template_id`.

**Compatibility note:** The spec targets OpenNebula 7.0+. The JSON schema should use 7.0 field names (`template_id`, `user_inputs`, `template_contents`) while noting backward compatibility with 6.x names where relevant.

## Open Questions

Things that could not be fully resolved:

1. **Can `${superlink.template.context.eth0_ip}` reliably resolve the SuperLink's IP?**
   - What we know: The `${ROLE_NAME.xpath}` syntax is documented for inter-role attribute references in `template_contents`. It works with `straight` deployment and parent-child relationships. The syntax resolves attributes from the parent VM's template.
   - What's unclear: Whether ETH0_IP is populated in the VM template CONTEXT at the time the child role resolves the reference. Network configuration by the contextualization agent may happen after template instantiation but before the context is fully available to OneFlow.
   - Recommendation: Do NOT use this for primary SuperLink address injection. OneGate dynamic discovery is the proven path. Note this as an open question for runtime validation. The defense-in-depth model (OneGate discovery as primary, retry loop as fallback) makes this question non-blocking.

2. **OneGate attribute size limits for FL_CA_CERT**
   - What we know: A 4096-bit RSA CA certificate is approximately 1.7-2.7 KB after base64 encoding. OneGate stores attributes in the VM's USER_TEMPLATE which is persisted as XML.
   - What's unclear: Whether there is a hard size limit on individual OneGate attributes or the total USER_TEMPLATE size.
   - Recommendation: Assume the 2-3 KB payload is within limits (certificates have been successfully used in similar OneGate patterns). Document as a validation item for implementation.

3. **OneFlow field naming: `vm_template` vs `template_id` in OpenNebula 7.0**
   - What we know: OpenNebula 7.0 documentation uses `template_id` and `template_contents`. Earlier versions used `vm_template` and `vm_template_contents`.
   - What's unclear: Whether the old names are still accepted as aliases in 7.0, or if migration is required.
   - Recommendation: Use `template_id` and `template_contents` (7.0 naming) as the primary schema. Note the 6.x names as backward-compatible alternatives.

4. **FL_NODE_CONFIG per-SuperNode differentiation via OneFlow**
   - What we know: Each SuperNode needs a unique `partition-id` in FL_NODE_CONFIG for data partitioning. OneFlow's user_inputs apply the same value to all VMs in a role.
   - What's unclear: How to assign unique partition-id values to each SuperNode VM. Options include: (a) post-boot OneGate-based index assignment, (b) using the VM's VMID modulo cardinality, (c) making data partitioning automatic in the ClientApp.
   - Recommendation: Document this as a limitation of the OneFlow template approach. The simplest solution is to have the boot script compute `partition-id` from the VM's position in the OneGate service response (index of the node in the role's nodes array). This is a Phase 4 spec item.

## Sources

### Primary (HIGH confidence)
- [OpenNebula 7.0 OneFlow Services Management](https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/) - Service template structure, deployment strategies, user_inputs, template_contents, ready_status_gate
- [OpenNebula 6.10 OneFlow Services Management](https://docs.opennebula.io/6.10/management_and_operations/multivm_service_management/appflow_use_cli.html) - Cross-referenced for completeness; identical behavior to 7.0 for core features
- [OpenNebula 6.10 OneFlow API Specification](https://docs.opennebula.io/6.10/integration_and_development/system_interfaces/appflow_api.html) - Complete JSON schema for service templates and roles
- [OpenNebula 7.0 OneGate API](https://docs.opennebula.io/7.0/product/integration_references/system_interfaces/onegate_api/) - OneGate endpoints, authentication, GET /service response structure
- [OpenNebula 6.8 OneFlow Auto-scaling](https://docs.opennebula.io/6.8/management_and_operations/multivm_service_management/appflow_elasticity.html) - Elasticity policies, cardinality, min/max bounds

### Secondary (MEDIUM confidence)
- [OpenNebula one-apps Issue #47: Conditionally report Onegate READY=YES](https://github.com/OpenNebula/one-apps/issues/47) - READY_SCRIPT feature implemented for 6.10.0
- Existing spec files (spec/01-superlink-appliance.md, spec/02-supernode-appliance.md) - OneGate publication contract, discovery protocol, health check mechanisms
- Existing spec files (spec/04-tls-certificate-lifecycle.md, spec/05-supernode-tls-trust.md) - TLS attribute publication and retrieval via OneGate

### Tertiary (LOW confidence)
- `${ROLE_NAME.template.context.variable}` inter-role resolution for network addresses (documented but IP resolution timing unverified)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - OneFlow and OneGate are the only OpenNebula tools for this purpose; no alternative evaluation needed
- Architecture (service template structure): HIGH - verified against official documentation for OpenNebula 6.10 and 7.0
- Architecture (ready_status_gate + REPORT_READY): HIGH - explicitly documented behavior confirmed across multiple versions
- Architecture (OneGate coordination protocol): HIGH - already implemented in existing spec (Phases 1-2); Phase 4 wraps it in service template context
- Pitfalls: HIGH - derived from documented behavior and existing spec constraints
- Cardinality/scaling: HIGH - elasticity policies are well-documented
- Inter-role IP resolution: MEDIUM - syntax documented but runtime behavior for network addresses unverified
- FL_NODE_CONFIG partitioning: MEDIUM - requires spec-level design decision, not just documentation lookup

**Research date:** 2026-02-07
**Valid until:** 2026-04-07 (90 days -- OpenNebula 7.0 is a stable release; core OneFlow/OneGate behavior is unlikely to change within this window)
