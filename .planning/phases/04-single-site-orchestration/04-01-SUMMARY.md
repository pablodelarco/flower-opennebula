---
phase: 04-single-site-orchestration
plan: 01
subsystem: infra
tags: [oneflow, onegate, service-template, orchestration, cardinality, user-inputs]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperLink and SuperNode VM templates, OneGate publication contract, contextualization variables
  - phase: 02-security-and-certificate-automation
    provides: TLS certificate lifecycle and FL_TLS_ENABLED variable
  - phase: 03-ml-framework-variants-and-use-cases
    provides: ML_FRAMEWORK and FL_USE_CASE variables for SuperNode role user_inputs
provides:
  - Complete OneFlow service template JSON for single-site Flower cluster deployment
  - Three-level user_inputs hierarchy (service, SuperLink role, SuperNode role)
  - SuperLink singleton constraint (min_vms=1, max_vms=1)
  - SuperNode cardinality configuration (default 2, range 2-10)
  - Auto-computed partition-id from OneGate service response
affects: [04-02, 05, 07, 09]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Three-level user_inputs hierarchy: service-level shared vars > role-level specific vars"
    - "ready_status_gate: true gates child role deployment on parent application health"
    - "Auto-computed FL_NODE_CONFIG from VM index in OneGate service response"

key-files:
  created:
    - spec/08-single-site-orchestration.md
  modified: []

key-decisions:
  - "Service-level user_inputs for FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL (consistency across roles)"
  - "SuperLink hard singleton via min_vms=1, max_vms=1 (no elasticity policies)"
  - "SuperNode default cardinality 2, min 2, max 10 (FL requires >= 2 clients)"
  - "Auto-computed partition-id from OneGate VM index when FL_NODE_CONFIG is empty"
  - "User-provided FL_NODE_CONFIG overrides auto-computation (explicit operator intent)"
  - "template_contents injects infrastructure CONTEXT vars (TOKEN, REPORT_READY, etc.) per-role"

patterns-established:
  - "OneFlow service template structure for Flower cluster with straight deployment and ready_status_gate"
  - "user_inputs partitioning: shared vars at service level, role-specific vars at role level"

# Metrics
duration: 4min
completed: 2026-02-07
---

# Phase 4 Plan 1: OneFlow Service Template Definition Summary

**Complete OneFlow service template JSON with straight deployment, ready_status_gate, three-level user_inputs hierarchy, SuperLink singleton constraint, and auto-computed SuperNode partition-id**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-07T21:34:06Z
- **Completed:** 2026-02-07T21:38:13Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- Complete, valid OneFlow service template JSON with field-by-field annotations and OpenNebula 6.x backward compatibility notes
- Three-level user_inputs hierarchy cleanly separating shared, SuperLink-specific, and SuperNode-specific configuration
- SuperLink hard singleton constraint preventing split-brain federation
- Auto-computed partition-id mechanism using VM index from OneGate service response, with user-override precedence

## Task Commits

Each task was committed atomically:

1. **Task 1: Create OneFlow service template specification (Sections 1-3)** - `584e354` (feat)
2. **Task 2: Add cardinality configuration and per-node differentiation (Sections 4-5)** - `4f23fb9` (feat)

## Files Created/Modified
- `spec/08-single-site-orchestration.md` - OneFlow service template definition with role structure, user_inputs mapping, cardinality configuration, and per-SuperNode differentiation

## Decisions Made
- Service-level user_inputs for FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL to prevent version/TLS/log drift across roles
- SuperLink hard-constrained to cardinality 1 via min_vms=1, max_vms=1 (Flower SuperLink is a singleton coordinator)
- SuperNode default cardinality 2 with range 2-10 (FL requires >= 2 clients for FedAvg)
- Auto-computed partition-id from VM index in OneGate service response when FL_NODE_CONFIG is empty
- User-provided FL_NODE_CONFIG overrides auto-computation (operator intent takes precedence)
- Infrastructure CONTEXT vars (TOKEN, REPORT_READY, READY_SCRIPT_PATH, NETWORK) in template_contents per-role, not in user_inputs

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Spec defines the complete service template structure; Plan 2 (04-02) adds the deployment sequence walkthrough, OneGate coordination protocol, scaling operations, and service lifecycle
- The ready_status_gate + REPORT_READY interaction resolves the blocker noted in STATE.md
- Auto-partition-id mechanism is documented with pseudocode ready for implementation

## Self-Check: PASSED

---
*Phase: 04-single-site-orchestration*
*Completed: 2026-02-07*
