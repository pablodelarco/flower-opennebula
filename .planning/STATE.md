# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Enable privacy-preserving federated learning on distributed OpenNebula infrastructure through marketplace appliances that any tenant can deploy with minimal configuration.
**Current focus:** Phase 3 IN PROGRESS (ML Framework Variants and Use Cases). Plan 03-01 complete, Plan 03-02 next.

## Current Position

Phase: 3 of 9 (ML Framework Variants and Use Cases)
Plan: 1 of 2 in current phase
Status: In progress
Last activity: 2026-02-07 -- Completed 03-01-PLAN.md (ML framework variant strategy and Dockerfiles)

Progress: [██████░░░░░░░░░░░░░░] 30% (6/20 plans)

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: 5 min
- Total execution time: 27 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Base Appliance Architecture | 3/3 | 13 min | 4 min |
| 2. Security and Certificate Automation | 2/2 | 11 min | 6 min |
| 3. ML Framework Variants and Use Cases | 1/2 | 3 min | 3 min |

**Recent Trend:**
- Last 5 plans: 01-03 (5 min), 02-01 (5 min), 02-02 (6 min), 03-01 (3 min)
- Trend: consistent

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: 9-phase structure following foundation -> security -> variants -> orchestration -> training -> GPU -> federation -> monitoring -> edge progression
- [Roadmap]: Docker-in-VM as primary packaging approach (from research)
- [Roadmap]: Phases 2, 3, 6 can execute in parallel after Phase 1 (all depend only on Phase 1)
- [01-01]: Ubuntu 24.04 as base OS (matches Flower Docker image base)
- [01-01]: Pre-baked fat image strategy (Flower image pre-pulled, network-free boot)
- [01-01]: Linear boot sequence over state machine (12 steps)
- [01-01]: TCP port check for health probe (nc -z, zero additional deps)
- [01-01]: Immutable appliance model (no runtime reconfiguration)
- [01-01]: Subprocess isolation mode as default (single container per VM)
- [01-01]: OneGate publication is best-effort (degraded but functional without it)
- [01-01]: FL_* prefix for Flower-specific context variables
- [01-02]: Dual discovery model: static IP override > OneGate dynamic > fail
- [01-02]: Discovery retry: 30 retries, 10s fixed interval, 5min total timeout
- [01-02]: Container running-state health check (no port check for outbound-only SuperNode)
- [01-02]: Flower-native reconnection delegation (--max-retries 0 = unlimited)
- [01-02]: No persistent state volume for SuperNode (training state is ephemeral)
- [01-02]: Data mount read-only (/opt/flower/data -> /app/data:ro)
- [01-03]: FLOWER_VERSION validated as semver format (X.Y.Z)
- [01-03]: Fail-fast validation checks all variables before aborting (not one-at-a-time)
- [01-03]: FL_MIN_FIT_CLIENTS <= FL_MIN_AVAILABLE_CLIENTS is a warning, not hard error
- [01-03]: Placeholder variables logged when ignored in Phase 1 (not silently dropped)
- [02-01]: Self-signed CA generated at boot is default; operator-provided certs via FL_SSL_* are override path
- [02-01]: CA key retained on SuperLink (root:root 0600) for potential Phase 7 cross-zone use
- [02-01]: FL_SSL_CA_CERTFILE is the decision variable (all-or-none rule for three FL_SSL_* vars)
- [02-01]: OneGate FL_CA_CERT publication is best-effort (matches Phase 1 model)
- [02-01]: 365-day cert validity with no rotation (immutable appliance: redeploy to renew)
- [02-01]: ca.key NOT mounted into container (defense-in-depth via root:root 0600)
- [02-02]: TLS mode detection: 4-case priority (explicit CONTEXT YES > explicit NO > OneGate auto > insecure default)
- [02-02]: FL_SSL_CA_CERTFILE overrides OneGate FL_CA_CERT (operator CA takes precedence)
- [02-02]: FL_TLS=YES without FL_CA_CERT is FATAL on SuperNode (no silent security downgrade)
- [02-02]: FL_TLS_ENABLED=NO overrides OneGate FL_TLS=YES (respects operator intent, logs warning)
- [02-02]: Single-file mount for SuperNode (ca.crt only, not directory)
- [02-02]: Step 7b inserted in SuperNode boot for CA cert PEM validation
- [03-01]: Multiple framework-specific QCOW2 images over single fat image (size, conflict isolation, marketplace clarity)
- [03-01]: PyTorch, TensorFlow, scikit-learn as the three supported frameworks
- [03-01]: LLM deps (bitsandbytes, peft, transformers) in PyTorch variant, not a fourth variant
- [03-01]: flower-supernode-{framework}:{VERSION} naming convention for custom Docker images
- [03-01]: No fallback between framework variants (wrong QCOW2 for requested framework is fatal)
- [03-01]: CPU-only framework installs in Phase 3 (GPU variants deferred to Phase 6)

### Pending Todos

None.

### Blockers/Concerns

- GPU passthrough validation needed on target hardware (affects Phase 6 scope -- may need CPU-only fallback)
- OneGate cross-zone behavior unverified (affects Phase 7 -- may need explicit endpoint config instead of dynamic discovery)
- REPORT_READY + OneFlow role dependency interaction needs validation (affects Phase 4 -- SuperNode retry loop provides defense-in-depth)
- PyTorch variant QCOW2 size (~4-5 GB) needs validation during implementation; revisit LLM dep placement if exceeds 5 GB

## Session Continuity

Last session: 2026-02-07T19:44:40Z
Stopped at: Completed 03-01-PLAN.md (ML framework variant strategy and Dockerfiles)
Resume file: None
