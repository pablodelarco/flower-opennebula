---
phase: 02-security-and-certificate-automation
plan: 02
subsystem: security
tags: [tls, certificates, onegate, grpc, flower, supernode, trust-chain]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperNode appliance spec with boot sequence and discovery model
  - phase: 02-01
    provides: TLS certificate lifecycle spec with OneGate publication contract (FL_TLS, FL_CA_CERT), dual provisioning model, contextualization variables
provides:
  - SuperNode TLS trust specification (CA cert retrieval, TLS mode detection, boot sequence changes, Docker --root-certificates)
  - End-to-end TLS handshake walkthrough (9 steps from SuperLink boot to encrypted gRPC)
  - Complete APPL-04 specification (combined with Plan 02-01, both server and client sides specified)
  - Spec overview updated with Phase 2 section navigation
affects: [04-oneflow-orchestration, 07-multi-site-federation]

# Tech tracking
tech-stack:
  added: []
  patterns: [tls-mode-detection-priority, onegate-trust-distribution, boot-sequence-delta-spec]

key-files:
  created: [spec/05-supernode-tls-trust.md]
  modified: [spec/00-overview.md]

key-decisions:
  - "TLS mode detection uses 4-case priority: explicit CONTEXT YES > explicit CONTEXT NO > OneGate auto-detection > insecure default"
  - "FL_SSL_CA_CERTFILE in CONTEXT overrides OneGate FL_CA_CERT retrieval (operator CA takes precedence)"
  - "FL_TLS=YES without FL_CA_CERT on OneGate is FATAL on SuperNode (no silent security downgrade)"
  - "FL_TLS_ENABLED=NO explicitly set overrides OneGate FL_TLS=YES (respects operator intent, warns on mismatch)"
  - "Single-file mount for SuperNode (ca.crt:/app/ca.crt:ro) not directory mount (only CA cert needed)"
  - "Step 7b inserted in SuperNode boot for CA cert validation (openssl x509 PEM check)"

patterns-established:
  - "TLS mode detection with explicit priority ordering (CONTEXT > OneGate > default)"
  - "OneGate as trust distribution channel for CA certificates"
  - "End-to-end walkthrough format: numbered steps tracing artifact flow across VM boundaries"

# Metrics
duration: 6min
completed: 2026-02-07
---

# Phase 2 Plan 2: SuperNode TLS Trust and End-to-End Handshake Summary

**SuperNode CA certificate retrieval (OneGate + static), TLS mode detection with 4-case priority, boot sequence delta (Step 7 update, Step 7b insertion, Step 10 update), Docker --root-certificates, and complete 9-step end-to-end TLS handshake walkthrough from SuperLink boot through encrypted gRPC channel**

## Performance

- **Duration:** 6 min
- **Started:** 2026-02-07T17:38:31Z
- **Completed:** 2026-02-07T17:44:15Z
- **Tasks:** 2
- **Files created:** 1
- **Files modified:** 1

## Accomplishments
- Complete SuperNode TLS trust specification with 11 sections plus appendix (835 lines)
- CA certificate retrieval from OneGate with exact jq extraction paths for FL_TLS and FL_CA_CERT
- Static CA provisioning via FL_SSL_CA_CERTFILE for non-OneFlow and cross-zone deployments
- TLS mode detection with 4-case priority logic and decision flowchart
- Boot sequence delta: Step 7 updated (TLS discovery), Step 7b inserted (cert validation), Step 10 updated (Docker TLS flags)
- Docker run commands shown side-by-side (Phase 1 insecure vs Phase 2 TLS with --root-certificates)
- End-to-end TLS handshake walkthrough covering all 9 steps from SuperLink boot to encrypted gRPC
- ASCII sequence diagram showing temporal flow across SuperLink, OneGate, and SuperNode
- 9 failure modes classified with symptoms and recovery actions
- Security considerations: OneGate trust channel, data privacy, cross-zone notes
- Spec overview updated with Phase 2 section navigation and TLS mode annotation
- Two SuperNode TLS variables fully specified (FL_TLS_ENABLED, FL_SSL_CA_CERTFILE) with USER_INPUT definitions

## Task Commits

Each task was committed atomically:

1. **Task 1: Write SuperNode TLS trust spec section** - `4ebb340` (feat)
2. **Task 2: Update spec overview with Phase 2 section references** - `1301d73` (docs)

## Files Created/Modified
- `spec/05-supernode-tls-trust.md` - SuperNode TLS trust specification: trust model, OneGate CA retrieval, static provisioning, TLS mode detection, cert validation, boot sequence changes, Docker run (TLS), end-to-end handshake walkthrough, contextualization variables, failure modes, security considerations
- `spec/00-overview.md` - Added Phase 2 section table (04 and 05), TLS mode note in architecture diagram, updated title/footer/reading order

## Decisions Made
- TLS mode detection uses 4-case priority: explicit CONTEXT (YES/NO) > OneGate auto-detection > insecure default
- FL_SSL_CA_CERTFILE in CONTEXT overrides OneGate retrieval (allows operator-provided CA even in OneFlow)
- FL_TLS=YES on SuperLink without FL_CA_CERT is FATAL on SuperNode (prevents silent security downgrade)
- FL_TLS_ENABLED=NO explicitly overrides OneGate FL_TLS=YES (respects operator intent, logs mismatch warning)
- Single-file mount (ca.crt only) for SuperNode, not directory mount (SuperNode needs only CA cert)
- Step 7b inserted for CA certificate PEM validation before container start

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 2 is now COMPLETE: both Plan 02-01 (SuperLink TLS lifecycle) and Plan 02-02 (SuperNode TLS trust) are specified
- Combined, they satisfy all three Phase 2 success criteria from the roadmap:
  1. SuperLink generates and publishes certificates (spec 04)
  2. SuperNodes retrieve and trust the CA cert (spec 05)
  3. Complete TLS handshake path traceable end-to-end (spec 05, Section 8)
- Phase 4 (OneFlow orchestration) can reference FL_TLS_ENABLED service-level setting
- Phase 7 (multi-site federation) has static cert provisioning path documented for cross-zone use

## Self-Check: PASSED

---
*Phase: 02-security-and-certificate-automation*
*Completed: 2026-02-07*
