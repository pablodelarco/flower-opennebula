# Phase 9: Edge and Auto-Scaling - Research

**Researched:** 2026-02-09
**Domain:** Edge-optimized appliance design, OneFlow elasticity policies, FL fault tolerance
**Confidence:** HIGH (primary sources: OpenNebula 6.8/7.0 official docs, Flower API docs, existing project specs)

## Summary

Phase 9 is the final phase of the specification project and covers two distinct but related domains: (1) an edge-optimized SuperNode appliance with a reduced footprint targeting <2GB image size, and (2) OneFlow auto-scaling via elasticity policies for dynamic client scaling during training.

The edge SuperNode requires stripping framework dependencies, using only the base `flwr/supernode` image, and potentially switching to Ubuntu Minimal cloud images. The standard SuperNode QCOW2 is 2-5GB depending on framework variant; achieving <2GB requires the scikit-learn variant or the base (no framework) image combined with image size optimization. The key challenge is intermittent connectivity handling, which is largely delegated to Flower's native `--max-retries 0` reconnection but needs spec-level documentation of retry strategies, backoff, and partial participation semantics.

OneFlow auto-scaling uses `elasticity_policies` with expression-based triggers that evaluate VM attributes (from USER_TEMPLATE, MONITORING, or VM/TEMPLATE). Custom FL metrics can be published from inside VMs via OneGate PUT requests, enabling FL-aware scaling triggers. The spec must define what metrics to publish, threshold expressions, cooldown periods, and how scaling interacts with active training rounds.

**Primary recommendation:** Define the edge SuperNode as a stripped-down variant of the base QCOW2 (no ML framework pre-installed, scikit-learn at most), with enhanced retry/backoff configuration variables and a clear intermittent connectivity handling specification. For auto-scaling, define custom FL metrics published via OneGate and elasticity policy expressions using those metrics, with FL-aware cooldown periods.

## Standard Stack

### OneFlow Elasticity Engine (No Additional Libraries)

OneFlow's built-in elasticity engine is the only technology needed for auto-scaling. No external tools (Kubernetes HPA, Prometheus-based autoscalers, etc.) are applicable.

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| OneFlow elasticity_policies | OpenNebula 7.0+ | Expression-based auto-scaling triggers | Built into OpenNebula, evaluates VM attributes, supports CHANGE/CARDINALITY/PERCENTAGE_CHANGE |
| OneFlow scheduled_policies | OpenNebula 7.0+ | Time-based scheduled scaling | Cron recurrence or one-time triggers for predictable workload patterns |
| OneGate PUT API | OpenNebula 7.0+ | Custom metric publication from VM | VM-internal metrics pushed to USER_TEMPLATE, consumed by elasticity expressions |

### Edge Optimization Stack

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| Ubuntu 24.04 Minimal Cloud Image | 24.04 | Reduced base OS footprint | Official Ubuntu minimal images ~250-500MB vs ~2GB standard |
| `flwr/supernode:1.25.0` (base) | 1.25.0 | Flower client without ML framework | ~190MB Docker image, smallest possible Flower footprint |
| Docker CE | 24+ | Container runtime | Same as standard appliance |

### Flower Fault Tolerance

| Component | Purpose | Key Parameters |
|-----------|---------|----------------|
| `--max-retries 0` | Unlimited reconnection attempts | Already specified in Phase 1 |
| `--max-wait-time 0` | No reconnection timeout | Already specified in Phase 1 |
| `FaultTolerantFedAvg` strategy | Tolerates client dropouts during training rounds | `min_completion_rate_fit=0.5`, `min_completion_rate_evaluate=0.5` |
| `accept_failures=True` (FedAvg default) | Proceeds with aggregation despite client failures | Default in all strategies |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Ubuntu 24.04 Minimal | Alpine Linux (~50-200MB QCOW2) | Much smaller but incompatible with one-apps contextualization, Docker ecosystem differences, breaks consistency with existing appliances |
| OneFlow elasticity | External monitoring + manual scaling | Loses integration with OpenNebula, adds complexity |
| Custom reconnection wrapper | Flower-native `--max-retries` | Hand-rolling reconnection contradicts Phase 1 delegation principle |

## Architecture Patterns

### Pattern 1: Edge SuperNode Appliance Variant

**What:** A stripped-down SuperNode QCOW2 targeting <2GB image size for bandwidth-constrained edge environments.

**Key differences from standard SuperNode:**

| Aspect | Standard SuperNode | Edge SuperNode |
|--------|-------------------|----------------|
| Base OS | Ubuntu 24.04 (full server) | Ubuntu 24.04 Minimal Cloud Image |
| Pre-baked Docker image | Framework-specific (PyTorch ~1.2GB, TF ~700MB, sklearn ~400MB) | Base `flwr/supernode:1.25.0` only (~190MB) |
| ML framework | Pre-installed in Docker image | User provides via custom Docker image or `FL_ISOLATION=process` |
| Target QCOW2 size | 2.5-5 GB | <2 GB |
| Recommended VM resources | 4 vCPU, 8GB RAM, 40GB disk | 2 vCPU, 2-4GB RAM, 10-20GB disk |
| Network dependency | Pre-baked (network-free boot) | Pre-baked (network-free boot, even more critical at edge) |
| Connectivity model | Persistent LAN/WAN | Intermittent, bandwidth-constrained |
| Retry configuration | Default (unlimited, immediate) | Enhanced (configurable backoff, bounded retries optional) |

**Image size breakdown (estimated):**

| Component | Standard (PyTorch) | Edge |
|-----------|-------------------|------|
| Ubuntu base | ~800 MB | ~300-400 MB (minimal) |
| Docker CE | ~400 MB | ~400 MB |
| Flower base image | ~190 MB | ~190 MB |
| Framework image | ~800 MB - 1.2 GB | 0 (not pre-baked) |
| Utilities (jq, curl, nc) | ~5 MB | ~5 MB |
| **Total QCOW2** | **~2.5 - 5 GB** | **~1.0 - 1.5 GB** |

### Pattern 2: OneFlow Elasticity with FL-Aware Custom Metrics

**What:** SuperNode VMs publish FL training status to OneGate, enabling elasticity policies to make FL-aware scaling decisions.

**Custom metrics published by SuperNode via OneGate PUT:**

| Metric | Value | Published When | Elasticity Use |
|--------|-------|----------------|----------------|
| `FL_TRAINING_ACTIVE` | `YES`/`NO` | Training round starts/ends | Scale-down protection during active training |
| `FL_ROUND_NUMBER` | integer | Each round | Track training progress |
| `FL_CLIENT_STATUS` | `IDLE`/`TRAINING`/`DISCONNECTED` | Status changes | Detect unhealthy nodes |

**Elasticity expression pattern:**

```json
{
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
      "period": 60,
      "cooldown": 600
    }
  ]
}
```

**How OneFlow evaluates expressions:**
1. OneFlow evaluates expressions periodically (every `period` seconds).
2. For each attribute in the expression, OneFlow calculates the **average value across all running VMs** in the role.
3. The attribute is looked up in `/VM/USER_TEMPLATE`, `/VM/MONITORING`, `/VM/TEMPLATE`, and `/VM` (in that order).
4. If the expression evaluates to true for `period_number` consecutive periods, the scaling action triggers.
5. After scaling, the service enters COOLDOWN state for the configured duration.

### Pattern 3: Intermittent Connectivity Handling

**What:** Specification of how the edge SuperNode handles network disruptions during federated learning.

**Three layers of resilience (already partially specified):**

1. **Flower-native reconnection** (`--max-retries 0`): Unlimited gRPC reconnection attempts. Handles SuperLink restarts, transient network failures. Already specified in Phase 1.

2. **OneGate discovery retry** (30 retries, 10s interval, 5min timeout): Handles timing gap between SuperNode boot and SuperLink readiness. Already specified in Phase 1.

3. **Edge-specific enhancements** (NEW for Phase 9):
   - Configurable backoff strategy for reconnection (exponential vs fixed)
   - Bounded retry windows for constrained environments
   - Partial participation tolerance in aggregation strategy

**Client disconnect mid-round behavior (Flower-native):**

| Event | Flower Server Behavior | Impact on Training |
|-------|----------------------|-------------------|
| Client disconnects during `fit()` | Server records failure in `failures` list | Round proceeds if `accept_failures=True` (default) and enough results returned |
| Client disconnects before `fit()` assigned | Client not sampled; server selects different clients | No impact on current round |
| All sampled clients disconnect | `aggregate_fit()` returns `None`; global model unchanged | Round effectively skipped, next round attempted |
| Client reconnects between rounds | Client available for next round's sampling | Transparent to training |
| Available clients drop below `min_available_clients` | SuperLink waits before starting next round | Training paused until enough clients reconnect |
| Available clients drop below `min_fit_clients` during round | Round proceeds with available results if `accept_failures=True` | Reduced data diversity for this round |

### Anti-Patterns to Avoid

- **Setting `min_available_clients` equal to SuperNode cardinality at edge:** If all N nodes must be available, any single node failure blocks training. Set `min_available_clients` below the expected node count.
- **Aggressive scale-down cooldown:** Scaling down during active training rounds removes clients mid-round, causing failures. Use long cooldown periods (>= round duration).
- **Elasticity policies on SuperLink role:** SuperLink is singleton (already documented in Phase 4 anti-patterns). Elasticity policies must only apply to SuperNode role.
- **Scaling below `min_fit_clients`:** OneFlow's `min_vms` must be >= `FL_MIN_FIT_CLIENTS` to prevent training deadlock.
- **Using framework-specific images for edge:** Framework images (PyTorch ~4-5GB) defeat the <2GB edge target. Use base image with `FL_ISOLATION=process` for custom ClientApp containers.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Client reconnection logic | Custom reconnect wrapper scripts | Flower's `--max-retries 0 --max-wait-time 0` | Already battle-tested in Flower; Phase 1 decision to delegate |
| Auto-scaling triggers | Custom cron jobs checking metrics | OneFlow `elasticity_policies` with expressions | Native OpenNebula integration, evaluates VM attributes automatically |
| Custom metrics pipeline | External monitoring agent | OneGate PUT from configure/bootstrap scripts | Built into OpenNebula, no additional infrastructure |
| Lightweight container runtime | Replace Docker with podman/containerd | Docker CE (same as standard) | Consistency with existing appliance stack, Docker CE footprint is acceptable |
| Custom fault-tolerant aggregation | Custom aggregation strategy | `FaultTolerantFedAvg` strategy or `accept_failures=True` on FedAvg | Flower provides this natively |

## Common Pitfalls

### Pitfall 1: Scale-Down Removing Clients Mid-Training-Round

**What goes wrong:** OneFlow scales down SuperNode role during an active training round. The removed VM's Flower container receives SIGTERM. The SuperLink records the client as a failure. If enough clients are removed, the round fails.

**Why it happens:** OneFlow's elasticity engine does not know about FL training round boundaries. It evaluates expression thresholds and scales immediately (after cooldown).

**How to avoid:**
- Use long cooldown periods (minimum 300-600 seconds) to span typical round durations.
- Recommend `FaultTolerantFedAvg` for auto-scaling deployments (tolerates 50% dropout).
- Document that `min_vms` must be >= `FL_MIN_FIT_CLIENTS`.
- Scale-down expression should require more consecutive periods before triggering than scale-up.

**Warning signs:** Training rounds failing after scale-down events; SuperLink logs showing "not enough results" for aggregation.

### Pitfall 2: Edge Node Partition-ID Instability After Reconnection

**What goes wrong:** An edge SuperNode disconnects, reconnects, and re-joins the training. Its `partition-id` was auto-computed at boot from the OneGate `nodes` array index. If VMs were added/removed during the disconnection, the partition-id no longer corresponds to the original data shard.

**Why it happens:** Auto-computed partition-id is a boot-time value. The VM does not recompute it on reconnection. Other VMs may have been assigned the same partition-id.

**How to avoid:** For edge deployments with expected churn, use explicit `FL_NODE_CONFIG` with operator-managed partition assignments rather than auto-computed values. Alternatively, use ClientApps that handle data sharding internally (e.g., by VMID hash).

### Pitfall 3: Edge Image Size Exceeds 2GB Target

**What goes wrong:** The "edge" SuperNode QCOW2 is built with standard Ubuntu 24.04 server image instead of Ubuntu Minimal, or includes unused packages, pushing it above 2GB.

**Why it happens:** Using the same QCOW2 build process as the standard appliance without stripping packages.

**How to avoid:** Start from Ubuntu 24.04 Minimal Cloud Image, install only Docker CE + contextualization + utilities (jq, curl, nc). Pre-pull only the base `flwr/supernode:1.25.0` image. Run `docker system prune` and `apt-get clean` before exporting.

### Pitfall 4: Elasticity Expression Averaging Masks Individual VM Issues

**What goes wrong:** OneFlow averages the attribute value across all running VMs. If 9 VMs have CPU at 10% and 1 VM has CPU at 90%, the average is 19% -- below any typical scale-up threshold. The overloaded VM is masked.

**Why it happens:** OneFlow's expression evaluator uses the average across the role, not individual VM values.

**How to avoid:** Use custom FL-specific metrics (published via OneGate) rather than raw infrastructure metrics. For example, `FL_CLIENT_STATUS=DISCONNECTED` count rather than average CPU. Consider MAX-based expressions or individual VM monitoring via Phase 8 monitoring stack.

### Pitfall 5: Cooldown Blocking Emergency Scale-Up

**What goes wrong:** After a scale-down event, the service enters COOLDOWN state. During cooldown, a surge in demand occurs but scale-up is delayed until cooldown expires.

**Why it happens:** During cooldown, ALL scaling actions for ALL roles are delayed (not just the role that scaled).

**How to avoid:** Keep scale-down cooldown reasonable (300-600s). Use `min_vms` as a hard floor to prevent over-aggressive scale-down. Do not define elasticity on SuperLink role (which would block SuperNode scaling during its cooldown).

## Code Examples

### Custom FL Metrics Publication via OneGate

```bash
# Source: OpenNebula 6.8 OneGate documentation
# Published from SuperNode bootstrap.sh or a periodic cron job

# Publish FL client status to OneGate USER_TEMPLATE
curl -X "PUT" "${ONEGATE_ENDPOINT}/vm" \
  --header "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
  --header "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_CLIENT_STATUS = IDLE"

# Publish training round number (if tracking)
curl -X "PUT" "${ONEGATE_ENDPOINT}/vm" \
  --header "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
  --header "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_TRAINING_ACTIVE = YES"
```

### Elasticity Policy JSON for SuperNode Role

```json
{
  "name": "supernode",
  "type": "vm",
  "template_id": 0,
  "cardinality": 2,
  "min_vms": 2,
  "max_vms": 10,
  "parents": ["superlink"],

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

### Edge SuperNode Reduced Resource VM Template (Conceptual)

```
# Edge SuperNode VM Template -- reduced resources
CPU = "2"
VCPU = "2"
MEMORY = "2048"
DISK = [
  IMAGE = "Flower SuperNode - Edge",
  SIZE = "10240"
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
  FL_EDGE_MAX_BACKOFF = "300"
]
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Manual `oneflow scale` commands | Elasticity policies with expressions | Stable since OpenNebula 5.x | Automatic scaling without operator intervention |
| External monitoring for scaling triggers | OneGate PUT custom metrics + elasticity expressions | Available since OneNebula 5.x | VM-internal metrics drive scaling decisions natively |
| Alpine Linux for edge VMs | Ubuntu 24.04 Minimal Cloud Image | Ubuntu 24.04 (April 2024) | Consistent with standard appliance stack while reducing footprint |
| Custom fault-tolerant aggregation | `FaultTolerantFedAvg` built into Flower | Flower 1.0+ | Native dropout tolerance with configurable completion rates |

**Key insight for OpenNebula 7.0:** The OneFlow elasticity engine is unchanged in 7.0. The main 7.0 improvements (Virtual Router roles, attribute naming `user_inputs` instead of `custom_attrs`, JSON `template_contents`) affect template syntax but not elasticity semantics. The spec should use 7.0 field names as already established in Phase 4.

## Open Questions

1. **Ubuntu Minimal + one-apps contextualization compatibility**
   - What we know: Ubuntu Minimal Cloud Images are official Ubuntu images with reduced footprint (~250-500MB). one-apps contextualization packages target Ubuntu 24.04 LTS.
   - What's unclear: Whether one-apps contextualization packages install cleanly on Ubuntu Minimal (which strips many server packages). The minimal image may lack packages that one-apps assumes are present.
   - Recommendation: Spec should note this as an implementation validation item. If incompatible, use standard Ubuntu 24.04 with aggressive package removal to achieve <2GB.

2. **Flower backoff strategy configurability**
   - What we know: Flower's `--max-retries` and `--max-wait-time` control reconnection behavior. The gRPC layer has its own reconnection backoff.
   - What's unclear: Whether Flower exposes configurable backoff strategies (exponential, jitter) or if gRPC defaults are used. This is LOW confidence from training data.
   - Recommendation: Spec should define the desired backoff behavior (exponential with max cap) as a specification requirement. Whether this maps to Flower CLI flags or gRPC channel options is an implementation detail.

3. **OneFlow scale-down VM selection order**
   - What we know: Phase 4 spec states "newest VMs removed first by default" during scale-down.
   - What's unclear: Whether this is configurable (e.g., remove IDLE clients preferentially), or always newest-first.
   - Recommendation: Spec should document newest-first as the assumed behavior and note that FL-aware selection (remove idle clients first) is not supported by OneFlow natively. The workaround is long cooldown periods.

4. **Practical image size with Ubuntu Minimal + Docker + Flower base**
   - What we know: Ubuntu Minimal ~250-500MB, Docker CE ~400MB, Flower base ~190MB. Theoretical total ~1.0-1.5GB.
   - What's unclear: Actual QCOW2 size after build (filesystem overhead, apt cache remnants, Docker layer storage). Could exceed estimates.
   - Recommendation: Document the <2GB target as a soft requirement with a validation plan. If QCOW2 exceeds 2GB, document the actual size and optimization strategies.

## Sources

### Primary (HIGH confidence)
- [OpenNebula 6.8 OneFlow Auto-scaling](https://docs.opennebula.io/6.8/management_and_operations/multivm_service_management/appflow_elasticity.html) -- elasticity_policies JSON schema, expression syntax, adjustment types, cooldown behavior
- [OpenNebula 7.0 What's New](https://docs.opennebula.io/7.0/software/release_information/release_notes_70/whats_new/) -- OneFlow 7.0 changes (virtual router roles, attribute naming)
- [Flower FedAvg API](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FedAvg.html) -- accept_failures, min_fit_clients, aggregate_fit behavior
- [Flower FaultTolerantFedAvg API](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FaultTolerantFedAvg.html) -- min_completion_rate_fit, dropout handling
- Existing project specs: `spec/02-supernode-appliance.md`, `spec/08-single-site-orchestration.md`, `spec/12-multi-site-federation.md`

### Secondary (MEDIUM confidence)
- [OpenNebula OneGate Usage](https://docs.opennebula.io/6.8/management_and_operations/multivm_service_management/onegate_usage.html) -- PUT API for custom metrics
- [OpenNebula 7.0 Compatibility Guide](https://docs.opennebula.io/7.0/software/release_information/release_notes_70/compatibility/) -- OneFlow attribute naming changes
- [Ubuntu Minimal Cloud Images](https://cloud-images.ubuntu.com/minimal/releases/) -- availability and size estimates

### Tertiary (LOW confidence)
- FL edge computing surveys (multiple 2025 papers) -- general patterns for intermittent connectivity, partial participation
- Flower `start_client` docs (deprecated API) -- `max_retries` parameter semantics
- Web search: Alpine Linux VM images -- size estimates but NOT recommended due to compatibility concerns

## Metadata

**Confidence breakdown:**
- Standard stack (OneFlow elasticity): HIGH -- official OpenNebula docs, unchanged API across versions
- Edge appliance architecture: MEDIUM -- image size estimates are theoretical, Ubuntu Minimal compatibility unverified
- FL fault tolerance: HIGH -- Flower API docs are authoritative
- Intermittent connectivity handling: MEDIUM -- backoff strategy configurability in Flower is unclear
- Custom metrics for scaling: HIGH -- OneGate PUT API is well-documented

**Research date:** 2026-02-09
**Valid until:** 2026-03-09 (30 days -- stable domain, no fast-moving dependencies)
