---
phase: 09-edge-and-auto-scaling
plan: 01
subsystem: spec
tags: [edge, auto-scaling, oneflow, elasticity, flower, opennebula, supernode, qcow2]

# Dependency graph
requires:
  - phase: 04-single-site-orchestration
    provides: OneFlow service template with SuperNode role cardinality and elasticity preview
  - phase: 07-multi-site-federation
    provides: Cross-zone deployment topology, training site template variant
provides:
  - Complete edge SuperNode appliance specification (under 2 GB QCOW2)
  - OneFlow elasticity policy definitions for FL-aware auto-scaling
  - Intermittent connectivity handling with configurable backoff
  - Client join/leave semantics during auto-scaling and edge events
  - 2 new contextualization variables (FL_EDGE_BACKOFF, FL_EDGE_MAX_BACKOFF)
affects: [09-02 spec integration plan]

# Tech tracking
tech-stack:
  added: [Ubuntu 24.04 Minimal Cloud Image, FaultTolerantFedAvg strategy]
  patterns: [edge appliance variant pattern, exponential backoff for discovery, OneGate PUT for custom FL metrics, elasticity expression evaluation]

key-files:
  created:
    - spec/14-edge-and-auto-scaling.md
  modified: []

key-decisions:
  - "DR-01: Ubuntu Minimal over Alpine for edge base OS (one-apps compatibility, consistency)"
  - "DR-02: Base Flower image only at edge, no framework pre-baked (size target, flexibility)"
  - "DR-03: Exponential backoff default for edge discovery retry (WAN-friendly, unlimited retries)"
  - "DR-04: FaultTolerantFedAvg recommended for edge (tolerates 50% dropout)"
  - "Numeric encoding for FL_CLIENT_STATUS (1=IDLE, 2=TRAINING, 3=DISCONNECTED) for OneFlow expression evaluation"
  - "min_vms >= FL_MIN_FIT_CLIENTS constraint for auto-scaling (prevents training deadlock)"
  - "600s default cooldown for scale-down (protects active training rounds up to 10 minutes)"

patterns-established:
  - "Edge appliance variant: stripped-down QCOW2 targeting under 2 GB via Ubuntu Minimal + base Flower image only"
  - "Three-layer resilience model: Flower-native reconnection > OneGate discovery retry > edge-specific backoff"
  - "Custom FL metrics via OneGate PUT: numeric encoding for status values consumed by OneFlow elasticity expressions"
  - "Cooldown as scale-down protection: cooldown period >= 2x expected training round duration"

# Metrics
duration: 6min
completed: 2026-02-09
---

# Phase 9 Plan 01: Edge and Auto-Scaling Specification Summary

**Edge SuperNode appliance variant (under 2 GB QCOW2 via Ubuntu Minimal), OneFlow elasticity policies with FL-aware custom metrics, and three-layer intermittent connectivity resilience model**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-09T18:33:59Z
- **Completed:** 2026-02-09T18:40:01Z
- **Tasks:** 2
- **Files created:** 1

## Accomplishments
- Complete edge SuperNode appliance specification: Ubuntu Minimal base, base Flower image only, under 2 GB target, with component-by-component size breakdown and build optimization steps
- Three-layer intermittent connectivity handling with configurable exponential backoff for edge discovery (FL_EDGE_BACKOFF, FL_EDGE_MAX_BACKOFF)
- OneFlow auto-scaling architecture with CPU-based and FL-aware elasticity policies, scheduled policies, and complete SuperNode role JSON
- Custom FL metrics via OneGate (FL_TRAINING_ACTIVE, FL_CLIENT_STATUS, FL_ROUND_NUMBER) with numeric encoding for expression evaluation
- Client join/leave semantics covering both auto-scaling events and edge disconnect scenarios
- 7 anti-patterns documented for edge and auto-scaling deployments
- 4 decision records with rationale (Ubuntu Minimal, base image, exponential backoff, FaultTolerantFedAvg)

## Task Commits

Each task was committed atomically:

1. **Tasks 1-2: Edge and auto-scaling specification** - `93a7b17` (feat)

## Files Created/Modified
- `spec/14-edge-and-auto-scaling.md` - Complete edge and auto-scaling specification (801 lines) covering EDGE-01 and ORCH-03

## Decisions Made

1. **Ubuntu Minimal over Alpine for edge base OS** -- one-apps contextualization compatibility, consistency with the Ubuntu 24.04 stack used across all other appliance variants. Size savings of Alpine (50-200 MB) vs Ubuntu Minimal (300-400 MB) are manageable.

2. **Base Flower image only, no framework pre-baked at edge** -- Including any ML framework Docker image pushes the QCOW2 above 2 GB. Operators provide frameworks via custom Docker images or FL_ISOLATION=process.

3. **Exponential backoff as default discovery retry strategy** -- Starts at 10s, doubles, caps at 300s. Unlimited retries (no maximum count). Better for intermittent WAN than fixed 10s interval with 30-retry limit.

4. **FaultTolerantFedAvg recommended for edge** -- Provides explicit min_completion_rate_fit=0.5 tolerance. Not enforced -- operators can use any strategy.

5. **Numeric encoding for FL_CLIENT_STATUS** -- OneFlow expressions evaluate numerically. String values cannot be compared with operators. 1=IDLE, 2=TRAINING, 3=DISCONNECTED enables expressions like `FL_CLIENT_STATUS > 1.5`.

6. **600s default cooldown for scale-down policies** -- Protects active training rounds up to 10 minutes. Recommendation: cooldown >= 2x expected round duration.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- This is the FINAL PHASE (Phase 9) of the specification project. Plan 09-01 delivers the self-contained edge and auto-scaling specification.
- Plan 09-02 (cross-cutting updates) will integrate Phase 9 variables into the contextualization reference, update the SuperNode appliance spec, and update the overview document.
- All 4 roadmap success criteria for Phase 9 are addressable from this specification:
  1. Edge SuperNode with under 2 GB target (Section 2)
  2. Intermittent connectivity handling (Section 3)
  3. OneFlow auto-scaling triggers (Section 8)
  4. Client join/leave semantics (Section 9)

## Self-Check: PASSED

---
*Phase: 09-edge-and-auto-scaling*
*Completed: 2026-02-09*
