---
phase: 01-base-appliance-architecture
plan: 01
subsystem: infra
tags: [flower, superlink, docker, qcow2, opennebula, onegate, contextualization, federated-learning]

# Dependency graph
requires:
  - phase: none
    provides: "First phase, no dependencies"
provides:
  - "SuperLink appliance specification (APPL-01)"
  - "Docker-in-VM architecture pattern for Flower appliances"
  - "OneGate publication contract (FL_READY, FL_ENDPOINT)"
  - "Contextualization parameter naming convention (FL_* prefix)"
  - "Linear boot sequence pattern (12 steps)"
  - "Pre-baked image strategy with version override/fallback"
affects: [02-supernode-appliance, 03-contextualization-reference, phase-2-tls, phase-4-oneflow]

# Tech tracking
tech-stack:
  added: [ubuntu-24.04, docker-ce-24+, flwr/superlink:1.25.0, one-apps-contextualization]
  patterns: [docker-in-vm, pre-baked-fat-image, linear-boot-sequence, onegate-service-discovery, immutable-appliance]

key-files:
  created: [spec/01-superlink-appliance.md]
  modified: []

key-decisions:
  - "Ubuntu 24.04 as base OS (matches Flower Docker image base, LTS until 2029)"
  - "Pre-baked fat image strategy (Flower image pre-pulled at build time, network-free boot)"
  - "Linear boot sequence over state machine (sequential boot is simpler, sufficient)"
  - "TCP port check for health probe over gRPC health check (zero additional dependencies)"
  - "Immutable appliance model (no runtime reconfiguration, redeploy to change config)"
  - "Subprocess isolation mode as default (single container per VM, simplest pattern)"
  - "OneGate publication is best-effort (degraded but functional without it)"

patterns-established:
  - "Pattern: FL_* prefix for all Flower-specific context variables"
  - "Pattern: 12-step linear boot sequence with WHAT/WHY/FAILURE for each step"
  - "Pattern: Pre-baked Docker image with FLOWER_VERSION override + fallback"
  - "Pattern: OneGate publication contract (FL_READY, FL_ENDPOINT, FL_VERSION, FL_ROLE)"
  - "Pattern: Systemd unit managing Docker container (Type=simple, no -d flag)"
  - "Pattern: UID 49999 ownership for Flower container mount points"

# Metrics
duration: 4min
completed: 2026-02-05
---

# Phase 1 Plan 01: SuperLink Appliance Specification Summary

**Complete SuperLink appliance spec covering QCOW2 packaging, 12-step boot sequence, Docker container configuration, OneGate readiness publication, and full contextualization parameter mapping with zero-config defaults**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-05T12:32:52Z
- **Completed:** 2026-02-05T12:36:51Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments

- Wrote complete SuperLink appliance specification (632 lines, 13 sections + 2 appendices)
- Defined 12-step linear boot sequence from OS boot through OneGate readiness publication with WHAT/WHY/FAILURE for each step
- Specified Docker container configuration with exact `docker run` command, port mappings (9091/9092/9093), and volume mounts
- Documented OneGate publication contract (FL_READY, FL_ENDPOINT, FL_VERSION, FL_ROLE, FL_ERROR)
- Defined 11 contextualization parameters with USER_INPUT definitions, types, defaults, and validation rules
- Specified pre-baked image strategy with version override mechanism and fallback to pre-baked on pull failure
- Documented failure modes table classifying 9 failure types by severity, boot continuation, and recovery action

## Task Commits

Each task was committed atomically:

1. **Task 1: Create spec directory and write SuperLink appliance spec section** - `4840a51` (feat)

## Files Created/Modified

- `spec/01-superlink-appliance.md` - Complete SuperLink appliance specification (APPL-01)

## Decisions Made

1. **Ubuntu 24.04 as base OS** - Matches the base OS inside Flower Docker images, avoiding library mismatches. LTS support until 2029.
2. **Pre-baked fat image strategy** - Flower image pre-pulled at QCOW2 build time. Eliminates boot-time network dependency for edge/air-gapped scenarios. FLOWER_VERSION override triggers pull with fallback.
3. **Linear boot sequence** - 12 sequential steps rather than a state machine. Boot is fundamentally sequential; state machines add unjustified complexity.
4. **TCP port check for health probe** - `nc -z localhost 9092` is sufficient for readiness. gRPC health probe would require additional tooling for marginal benefit.
5. **Immutable appliance model** - No runtime reconfiguration. Redeploy to change configuration. Aligns with OpenNebula's one-shot contextualization model.
6. **Subprocess isolation mode** - Single container per VM. Process isolation mode requires 3+ containers and complex orchestration, unnecessary for the appliance pattern.
7. **OneGate publication is best-effort** - SuperLink functions without OneGate. Only dynamic discovery is affected. Static addressing works regardless.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SuperLink appliance spec complete. Ready for Plan 01-02 (SuperNode appliance specification).
- SuperNode spec will reference the OneGate publication contract and boot sequence patterns established here.
- Contextualization parameter naming convention (FL_* prefix) and USER_INPUT format are established for consistent use in Plan 01-03.

---
*Phase: 01-base-appliance-architecture*
*Completed: 2026-02-05*
