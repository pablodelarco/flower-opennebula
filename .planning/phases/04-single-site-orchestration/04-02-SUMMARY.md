---
phase: 04-single-site-orchestration
plan: 02
subsystem: infra
tags: [oneflow, onegate, deployment-sequence, coordination-protocol, scaling, lifecycle, anti-patterns]

# Dependency graph
requires:
  - phase: 04-single-site-orchestration-plan-01
    provides: OneFlow service template JSON, role structure, user_inputs hierarchy, cardinality config, partition-id auto-computation
  - phase: 01-base-appliance-architecture
    provides: SuperLink 12-step boot sequence, SuperNode 13-step boot sequence, OneGate publication contract
  - phase: 02-security-and-certificate-automation
    provides: TLS certificate lifecycle, FL_TLS and FL_CA_CERT OneGate attributes
provides:
  - End-to-end deployment sequence walkthrough with 12-step timeline
  - OneGate coordination protocol documenting how Phase 1/2 contracts work together in OneFlow context
  - SuperNode scaling operations (scale-up, scale-down, partition-id implications)
  - Service lifecycle management (state machine, deploy, undeploy, failure handling)
  - Anti-patterns table with 8 common misconfigurations and correct approaches
  - Overview updated with Phase 3 and Phase 4 references
  - Open Question #1 resolved (ready_status_gate behavior confirmed)
affects: [05, 07, 09]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ready_status_gate: true ensures SuperLink publishes to OneGate before SuperNodes are created"
    - "OneGate publication happens BEFORE REPORT_READY, guaranteeing attribute availability"
    - "Reverse dependency order for shutdown (SuperNodes first, then SuperLink)"

key-files:
  created: []
  modified:
    - spec/08-single-site-orchestration.md
    - spec/00-overview.md

key-decisions:
  - "ready_status_gate resolves Open Question #1: YES, OneFlow waits for READY=YES before child role deployment"
  - "Discovery succeeds on first attempt in ready_status_gate deployments (retry loop is defense-in-depth only)"
  - "Reverse shutdown order: SuperNodes terminated first to prevent reconnection storms"
  - "Anti-patterns documented as table format for quick reference"

patterns-established:
  - "OneGate coordination: publication -> REPORT_READY -> ready_status_gate -> child role creation"
  - "Anti-patterns section as standard spec format for common misconfigurations"

# Metrics
duration: 2min
completed: 2026-02-07
---

# Phase 4 Plan 2: Deployment Sequence and Service Lifecycle Summary

**End-to-end deployment walkthrough with OneGate coordination protocol, SuperNode scaling, service lifecycle state machine, and 8-item anti-patterns reference**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-07T22:09:37Z
- **Completed:** 2026-02-07T22:11:31Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Complete 12-step deployment sequence walkthrough from instantiation to RUNNING state with timing estimates (60-90s nominal)
- OneGate coordination protocol tying together Phase 1 and Phase 2 publication/discovery contracts in the OneFlow service context
- SuperNode scaling operations with partition-id implications and FL_MIN_FIT_CLIENTS interaction
- Service lifecycle management with state machine diagram, failure handling for all crash scenarios, and graceful shutdown ordering
- Anti-patterns table documenting 8 common misconfigurations (ready_status_gate, cardinality, TOKEN=YES, etc.)
- Overview updated with Phase 3 and Phase 4 spec tables, resolved Open Question #1, bumped to version 1.2

## Task Commits

Each task was committed atomically:

1. **Task 1: Deployment sequence, coordination protocol, scaling, and service lifecycle (Sections 6-9)** - `242def6` (feat)
2. **Task 2: Anti-patterns, spec footer, and overview update with Phase 4** - `09a9799` (feat)

## Files Created/Modified
- `spec/08-single-site-orchestration.md` - Added Sections 6-10 (deployment sequence, OneGate coordination, scaling operations, service lifecycle, anti-patterns) and spec footer
- `spec/00-overview.md` - Added Phase 3 and Phase 4 tables, resolved Open Question #1, bumped version to 1.2

## Decisions Made
- ready_status_gate behavior confirmed: OneFlow requires READY=YES in VM user template before considering role running for dependency purposes (resolves Open Question #1 from Phase 1)
- Discovery succeeds on first attempt when ready_status_gate is true (retry loop retained as defense-in-depth)
- Reverse shutdown ordering: SuperNodes terminated before SuperLink to prevent reconnection storms
- Anti-patterns documented in table format for quick-reference scanning

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Phase 4 (Single-Site Orchestration) is now complete: service template definition (Plan 1) + deployment sequence and lifecycle (Plan 2)
- spec/08-single-site-orchestration.md covers the full single-site deployment story from template structure through anti-patterns
- Phase 5 (Training Configuration) can proceed -- it builds on the service template and deployment sequence defined here
- Phase 7 (Multi-Site Federation) can reference the single-site coordination protocol as baseline

## Self-Check: PASSED

---
*Phase: 04-single-site-orchestration*
*Completed: 2026-02-07*
