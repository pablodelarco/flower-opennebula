---
phase: 01-base-appliance-architecture
plan: 02
subsystem: infra
tags: [flower, supernode, docker, qcow2, onegate, discovery, appliance]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperLink appliance spec (discovery contract, OneGate publication format)
provides:
  - Complete SuperNode appliance specification (APPL-02)
  - Dual discovery model (OneGate dynamic + static IP override)
  - SuperNode boot sequence with discovery phase
  - SuperNode contextualization parameter table
affects: [02-security-certificate-automation, 03-ml-framework-variants, 04-single-site-orchestration, 06-gpu-acceleration, 07-multi-site-federation, 09-edge-auto-scaling]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Dual discovery model: static IP override > OneGate dynamic > fail"
    - "Discovery retry loop: 30 retries, 10s interval, 5min total timeout"
    - "Container health check by running state (no port check for outbound-only clients)"
    - "Flower-native reconnection delegation (--max-retries 0 = unlimited)"

key-files:
  created:
    - spec/02-supernode-appliance.md
  modified: []

key-decisions:
  - "Container health check uses docker inspect running state, not port check (SuperNode has no listening ports)"
  - "Discovery retry uses fixed 10s interval, not exponential backoff (bounded 5min window makes backoff unnecessary)"
  - "OneGate connectivity pre-check fails fast before entering retry loop"
  - "No persistent state volume for SuperNode (training state is ephemeral)"
  - "Data mount is read-only (/opt/flower/data -> /app/data:ro)"

patterns-established:
  - "Dual discovery: static takes precedence over OneGate, with fail-fast on no option available"
  - "OneGate pre-check before retry loop to distinguish unreachable from not-yet-published"
  - "Health check by container running state for outbound-only services"

# Metrics
duration: 4min
completed: 2026-02-05
---

# Phase 1 Plan 2: SuperNode Appliance Specification Summary

**SuperNode appliance spec with dual SuperLink discovery (OneGate dynamic + static override), 13-step boot sequence, and Flower-native reconnection delegation**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-05T12:33:05Z
- **Completed:** 2026-02-05T12:37:25Z
- **Tasks:** 1
- **Files modified:** 1

## Accomplishments

- Complete SuperNode appliance specification covering all 16 required sections
- Dual SuperLink discovery model with deterministic priority (static > OneGate > fail)
- OneGate discovery retry loop fully specified (30 retries, 10s interval, 5min timeout)
- Boot sequence documented as 13 linear steps with WHAT/WHY/FAILURE for each
- Connection lifecycle delegated to Flower-native reconnection (--max-retries 0)
- Zero-config behavior documented: deploy with no parameters, auto-discover via OneGate

## Task Commits

Each task was committed atomically:

1. **Task 1: Write SuperNode appliance spec section** - `2ba24f7` (feat)

## Files Created/Modified

- `spec/02-supernode-appliance.md` - Complete SuperNode appliance specification (573 lines, 16 sections)

## Decisions Made

1. **Container health = running state, not port check** -- The SuperNode does not listen on any port (it makes outbound connections only). Health is determined by `docker inspect --format='{{.State.Running}}'` rather than TCP port checks.

2. **Fixed retry interval over exponential backoff** -- The total discovery window is bounded at 5 minutes. A fixed 10s interval simplifies log analysis and has negligible impact on OneGate load at 1 request every 10 seconds.

3. **OneGate pre-check before retry loop** -- A connectivity pre-check to OneGate distinguishes between "OneGate reachable but SuperLink not published yet" (enter retry loop) and "OneGate unreachable" (fail immediately with actionable error). This prevents wasting 5 minutes on a loop that cannot succeed.

4. **No persistent state volume** -- Unlike SuperLink (which has a state database), SuperNode training state is ephemeral. If the container restarts, it re-registers with SuperLink and awaits the next round. No `/app/state` volume is mounted.

5. **Data mount is read-only** -- The bind mount `/opt/flower/data:/app/data:ro` is read-only to prevent accidental training data modification by the ClientApp.

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- SuperNode spec complete and ready for Phase 2 (TLS certificate retrieval from SuperLink via OneGate)
- SuperNode spec cross-references SuperLink spec sections for FL_ENDPOINT contract, port 9092, and version matching
- Plan 01-03 (contextualization reference table) can aggregate parameters from both appliance specs
- Open question carried forward: REPORT_READY interaction with OneFlow role dependency ordering needs validation during implementation

---
*Phase: 01-base-appliance-architecture*
*Completed: 2026-02-05*
