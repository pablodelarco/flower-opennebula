---
phase: 02-security-and-certificate-automation
plan: 01
subsystem: security
tags: [tls, certificates, openssl, onegate, grpc, flower]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperLink appliance spec with boot sequence, OneGate publication contract, contextualization variable reference with Phase 2 placeholders
provides:
  - TLS certificate lifecycle specification for SuperLink (generation, file layout, dual provisioning, boot sequence changes, Docker TLS flags, OneGate publication)
  - Four fully specified contextualization variables (FL_TLS_ENABLED, FL_SSL_CA_CERTFILE, FL_SSL_CERTFILE, FL_SSL_KEYFILE)
  - OneGate publication contract extension (FL_TLS, FL_CA_CERT attributes)
  - Certificate generation sequence with exact OpenSSL commands
affects: [02-02-supernode-tls-trust, 04-oneflow-orchestration, 07-multi-site-federation]

# Tech tracking
tech-stack:
  added: []
  patterns: [dual-provisioning-model, boot-sequence-delta-spec, all-or-none-validation]

key-files:
  created: [spec/04-tls-certificate-lifecycle.md]
  modified: []

key-decisions:
  - "Self-signed CA generated at boot is the default; operator-provided certs are the override path"
  - "CA key retained on SuperLink (root:root 0600) for potential Phase 7 cross-zone use"
  - "FL_SSL_CA_CERTFILE is the decision variable for auto-gen vs operator-provided (all-or-none rule for the three FL_SSL_* vars)"
  - "OneGate FL_CA_CERT publication is best-effort (matches Phase 1 OneGate model)"
  - "365-day cert validity with no rotation mechanism (immutable appliance model applies)"
  - "ca.key NOT mounted into container (defense-in-depth via root:root 0600 ownership)"

patterns-established:
  - "Boot sequence delta specification: present Phase 2 changes as NEW/UPDATED markers on Phase 1 steps, not a full rewrite"
  - "Dual provisioning model: auto-generation (zero-config) vs operator-provided (FL_SSL_* CONTEXT variables)"
  - "All-or-none validation: FL_SSL_CA_CERTFILE triggers requirement for FL_SSL_CERTFILE and FL_SSL_KEYFILE"

# Metrics
duration: 5min
completed: 2026-02-07
---

# Phase 2 Plan 1: TLS Certificate Lifecycle Summary

**SuperLink TLS certificate lifecycle spec covering auto-generated and operator-provided certificate paths with OpenSSL generation sequence, file permissions, Docker TLS flags, and OneGate CA certificate publication**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-07T17:30:34Z
- **Completed:** 2026-02-07T17:35:06Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments
- Complete TLS certificate lifecycle specification with 10 sections plus appendix
- Full OpenSSL certificate generation sequence (8 steps: CA key, CA cert, server key, CSR, signed server cert, cleanup, permissions, chain verification)
- Dual provisioning model with clear decision flowchart (auto-gen default vs operator-provided via FL_SSL_* variables)
- Boot sequence delta specification (Step 7a insertion, Step 8 and Step 12 updates) referencing Phase 1 steps by number
- OneGate publication contract extended with FL_TLS and FL_CA_CERT attributes
- Four contextualization variables fully specified with USER_INPUT definitions, validation rules, and all-or-none enforcement
- Failure modes table with 9 classified scenarios (7 fatal, 1 non-blocking, 1 runtime)

## Task Commits

Each task was committed atomically:

1. **Task 1: Write TLS certificate lifecycle spec section** - `37639ba` (feat)

## Files Created/Modified
- `spec/04-tls-certificate-lifecycle.md` - TLS certificate lifecycle specification: generation sequence, file layout, dual provisioning, boot sequence changes, Docker TLS config, OneGate publication, contextualization variables, failure modes, security considerations

## Decisions Made
- Self-signed CA is the default zero-config path; operator-provided certificates use FL_SSL_* CONTEXT variables
- CA private key retained on SuperLink with root:root 0600 (defense-in-depth: not mounted into container, available for Phase 7)
- FL_SSL_CA_CERTFILE is the decision variable: its presence triggers operator-provided path, its absence triggers auto-generation
- All three FL_SSL_* variables must be provided together on SuperLink (all-or-none rule)
- OneGate FL_CA_CERT publication follows Phase 1 best-effort model (warning on failure, not fatal)
- 365-day certificate validity with no rotation mechanism (immutable appliance model: redeploy to renew)
- Boot sequence changes presented as delta to Phase 1 (NEW Step 7a, UPDATED Steps 8 and 12)

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Plan 02-02 (SuperNode TLS trust and end-to-end handshake) can reference the OneGate publication contract (FL_TLS, FL_CA_CERT) defined in this spec
- The dual provisioning model and contextualization variables are ready for SuperNode-side specification
- Phase 4 (OneFlow orchestration) has FL_TLS_ENABLED service-level setting documented for template design

## Self-Check: PASSED

---
*Phase: 02-security-and-certificate-automation*
*Completed: 2026-02-07*
