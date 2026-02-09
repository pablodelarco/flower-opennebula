# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-05)

**Core value:** Enable privacy-preserving federated learning on distributed OpenNebula infrastructure through marketplace appliances that any tenant can deploy with minimal configuration.
**Current focus:** Phase 6 COMPLETE (GPU Acceleration). Phase 7 (Multi-Site Federation) next.

## Current Position

Phase: 6 of 9 (GPU Acceleration)
Plan: 2 of 2 in current phase
Status: Phase complete
Last activity: 2026-02-09 -- Completed 06-02-PLAN.md (validation scripts and contextualization integration)

Progress: [█████████████░░░░░░░] 65% (13/20 plans)

## Performance Metrics

**Velocity:**
- Total plans completed: 13
- Average duration: 5 min
- Total execution time: 70 min

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 1. Base Appliance Architecture | 3/3 | 13 min | 4 min |
| 2. Security and Certificate Automation | 2/2 | 11 min | 6 min |
| 3. ML Framework Variants and Use Cases | 2/2 | 7 min | 4 min |
| 4. Single-Site Orchestration | 2/2 | 6 min | 3 min |
| 5. Training Configuration | 2/2 | 20 min | 10 min |
| 6. GPU Acceleration | 2/2 | 13 min | 7 min |

**Recent Trend:**
- Last 5 plans: 05-01 (18 min), 05-02 (2 min), 06-01 (7 min), 06-02 (6 min)
- Trend: Phase 6 complete in 13 min total (2 plans)

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
- [03-02]: FL_USE_CASE is optional list variable on SuperNode with default 'none'
- [03-02]: Incompatible ML_FRAMEWORK + FL_USE_CASE is a fatal boot error (not a warning)
- [03-02]: LLM fine-tuning has no demo mode (requires pre-provisioned data)
- [03-02]: Data provisioning auto-selects: /app/data has files -> local; otherwise -> flwr-datasets download
- [03-02]: image-classification supports both PyTorch (primary) and TensorFlow (alternate)
- [04-01]: Service-level user_inputs for FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL (consistency across roles)
- [04-01]: SuperLink hard singleton via min_vms=1, max_vms=1 (no elasticity policies)
- [04-01]: SuperNode default cardinality 2, min 2, max 10 (FL requires >= 2 clients)
- [04-01]: Auto-computed partition-id from OneGate VM index when FL_NODE_CONFIG is empty
- [04-01]: User-provided FL_NODE_CONFIG overrides auto-computation (explicit operator intent)
- [04-01]: Infrastructure CONTEXT vars (TOKEN, REPORT_READY, etc.) in template_contents per-role, not user_inputs
- [04-02]: ready_status_gate resolves Open Question #1: YES, OneFlow waits for READY=YES before child role deployment
- [04-02]: Discovery succeeds on first attempt in ready_status_gate deployments (retry loop is defense-in-depth only)
- [04-02]: Reverse shutdown order: SuperNodes terminated first to prevent reconnection storms
- [04-02]: Anti-patterns documented as table format for quick reference
- [05-01]: Six strategies: FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg
- [05-01]: STRATEGY_MAP factory pattern in ServerApp for strategy instantiation from run_config
- [05-01]: generate_run_config() bash bridge translates FL_* context vars to run_config key-value pairs
- [05-01]: .npz (NumPy) as default checkpoint format (framework-agnostic via ArrayRecord)
- [05-01]: checkpoint_latest.npz symlink + checkpoint_latest.json metadata for stable resume path
- [05-01]: FL_RESUME_ROUND NOT implemented (Flower has no round offset concept)
- [05-01]: Boot-time byzantine client count validation (n >= 2f+3 for Krum, n >= 4f+3 for Bulyan)
- [05-01]: Appliance does NOT manage storage backends (checkpoint storage is infrastructure concern)
- [05-02]: Phase 5 variables are functional (not placeholders) in contextualization reference
- [05-02]: Strategy-specific parameters exposed at SuperLink role level only
- [05-02]: Checkpointing configuration (FL_CHECKPOINT_*) grouped as SuperLink role-level user_inputs
- [06-01]: Full GPU passthrough over vGPU (license-free, near-bare-metal performance)
- [06-01]: driverctl for persistent driver binding (survives kernel updates, systemd-integrated)
- [06-01]: Memory growth as default over memory fraction (simpler for single-client scenario)
- [06-01]: MIG deferred to future phase (requires A100/H100, sparse OpenNebula docs)
- [06-01]: CPU fallback is WARNING not FATAL (degraded SuperNode better than missing one)
- [06-01]: FL_GPU_ENABLED as opt-in switch; FL_CUDA_VISIBLE_DEVICES and FL_GPU_MEMORY_FRACTION as advanced tuning
- [06-02]: GPU validation scripts are specification-only (not executable artifacts in QCOW2)
- [06-02]: FL_GPU_ENABLED promoted from placeholder to functional in contextualization reference and SuperNode spec
- [06-02]: SuperNode boot sequence expanded from 13 to 14 steps (GPU Detection at Step 9)
- [06-02]: FL_GPU_AVAILABLE published to OneGate for GPU status reporting

### Pending Todos

None.

### Blockers/Concerns

- GPU passthrough validation needed on target hardware (CPU-only fallback path fully specified in Phase 6)
- OneGate cross-zone behavior unverified (affects Phase 7 -- may need explicit endpoint config instead of dynamic discovery)
- PyTorch variant QCOW2 size (~4-5 GB) needs validation during implementation; revisit LLM dep placement if exceeds 5 GB

## Session Continuity

Last session: 2026-02-09T09:12:26Z
Stopped at: Completed 06-02-PLAN.md (validation scripts and contextualization integration)
Resume file: None
