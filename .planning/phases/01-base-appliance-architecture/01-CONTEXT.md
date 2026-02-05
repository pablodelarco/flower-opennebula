# Phase 1: Base Appliance Architecture - Context

**Gathered:** 2026-02-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Spec the SuperLink (Flower server) and SuperNode (Flower client) marketplace appliances: their Docker-in-VM packaging, boot sequences, and every contextualization parameter mapped to Flower configuration. TLS/security (Phase 2), ML framework variants (Phase 3), and orchestration (Phase 4) are separate phases.

</domain>

<decisions>
## Implementation Decisions

### Base OS and packaging
- Ubuntu 24.04 LTS preferred as base OS — researcher to validate compatibility with Flower Docker images
- Docker-in-VM packaging approach (decided during roadmap research)
- Minimum Docker version constraint (e.g., Docker CE 24+) rather than pinning specific versions
- Soft image size guidelines only — no hard limits, but keep marketplace images practical
- Image strategy (pre-baked fat vs minimal pull-at-boot): Claude's discretion, optimized for production edge AI where network reliability varies

### Boot sequence and initialization
- Boot sequence formality: Claude's discretion on whether to spec as linear steps or state machine
- Failure handling: Claude's discretion on retry logic and failure signaling via OneGate
- Health check approach: Claude's discretion on endpoint vs container-level checks
- Reconfigurability: Claude's discretion on immutable vs reconfigurable appliances
- Boot timing targets: Claude's discretion on whether to include SLA-style guidance
- SuperNode wait-for-SuperLink behavior: Claude's discretion on blocking wait vs Flower-native reconnect
- Boot logging: Claude's discretion on custom log paths vs systemd journal

### Contextualization parameter design
- Naming convention: Claude's discretion, following OpenNebula marketplace norms
- Validation strictness: Claude's discretion on fail-fast vs lenient defaults
- Zero-config defaults: YES — deploying SuperLink + SuperNode with no parameters changed must work out of the box (FedAvg, sensible round count, default port)
- Parameter table scope: Claude's discretion on whether to include all params in Phase 1 or extend incrementally

### SuperNode discovery model
- Dual mode: OneGate dynamic discovery by default (within OneFlow deployments), static IP/hostname override available for manual/cross-site setups
- Discovery retry semantics: Claude's discretion on backoff and timeout behavior
- OneGate publication contract: Claude's discretion on what SuperLink publishes (minimal vs rich metadata)
- Cross-network connectivity scope: Claude's discretion on what Phase 1 covers vs deferring to Phase 7

### Claude's Discretion
Significant latitude given across all areas. The user trusts Claude to make production-appropriate decisions for:
- Boot sequence formality and failure handling
- Health check and readiness probe design
- Parameter naming, validation, and table structure
- OneGate data contract and retry semantics
- Image packaging strategy for edge AI environments
- Logging and debugging affordances

</decisions>

<specifics>
## Specific Ideas

- Zero-config must work: a user deploys SuperLink + SuperNode from marketplace with defaults and sees federated learning running
- Base OS leaning Ubuntu 24.04 but researcher should validate Flower Docker image compatibility (openSUSE was a concern)
- This is a spec document, not implementation — every decision should be concrete enough for an engineer to implement without further questions

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-base-appliance-architecture*
*Context gathered: 2026-02-05*
