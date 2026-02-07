---
phase: 05-training-configuration
plan: 01
subsystem: training
tags: [aggregation, strategies, checkpointing, failure-recovery, contextualization]

dependency-graph:
  requires: [phase-01, phase-03, phase-04]
  provides: [training-configuration-spec, strategy-selection-architecture, checkpoint-mechanism]
  affects: [phase-05-plan-02, phase-08]

tech-stack:
  added: []
  patterns: [strategy-factory-STRATEGY_MAP, run_config-bridge, evaluate_fn-checkpoint-callback, checkpoint-symlink-latest]

file-tracking:
  key-files:
    created:
      - spec/09-training-configuration.md
    modified: []

decisions:
  - id: "05-01-01"
    decision: "Six strategies: FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg"
    rationale: "Covers general-purpose (FedAvg), heterogeneity (FedProx), adaptive optimization (FedAdam), and three levels of byzantine robustness"
  - id: "05-01-02"
    decision: "Strategy selection via STRATEGY_MAP factory pattern in ServerApp"
    rationale: "Strategy instantiation requires Python (constructor args, types); cannot be done at the Docker/bash layer"
  - id: "05-01-03"
    decision: "generate_run_config() bash bridge translates FL_* to run_config key-value pairs"
    rationale: "Bridges OpenNebula contextualization (bash) to Flower application layer (Python run_config)"
  - id: "05-01-04"
    decision: ".npz (NumPy) as default checkpoint format"
    rationale: "Framework-agnostic; ArrayRecord always converts to NumPy ndarrays regardless of ML framework"
  - id: "05-01-05"
    decision: "checkpoint_latest.npz symlink + checkpoint_latest.json metadata"
    rationale: "Stable path for resume workflow without searching for highest-numbered file; metadata for operational visibility"
  - id: "05-01-06"
    decision: "FL_RESUME_ROUND NOT implemented"
    rationale: "Flower has no round offset concept; documenting the limitation is better than implementing a fragile workaround"
  - id: "05-01-07"
    decision: "Boot-time byzantine client count validation (n >= 2f+3 for Krum, n >= 4f+3 for Bulyan)"
    rationale: "Mathematical guarantee of byzantine strategies requires minimum client count; failing at boot is better than cryptic aggregation errors at runtime"
  - id: "05-01-08"
    decision: "Appliance does NOT manage storage backends (disk attachment, NFS, S3)"
    rationale: "Checkpoint storage is an infrastructure concern; the appliance writes to a local path and the operator decides what backs it"

metrics:
  duration: "18 min"
  completed: "2026-02-08"
---

# Phase 5 Plan 1: Training Configuration Summary

**One-liner:** Six aggregation strategies with STRATEGY_MAP factory, run_config bridge, .npz checkpointing via evaluate_fn, and four failure recovery scenarios.

## What Was Done

### Task 1: Aggregation Strategy Specification (Sections 1-5)

Created `spec/09-training-configuration.md` with:

- **Section 1 (Purpose and Scope):** Covers aggregation strategies, checkpointing, and failure recovery. Excludes monitoring (Phase 8), auto-scaling (Phase 9), and GPU config (Phase 6).
- **Section 2 (Strategy Reference):** All six strategies documented with algorithm summary, when-to-use guidance, Flower class name, parameter table, minimum client requirements, and important caveats. Includes FedProx client-side implementation warning and FedAdam initial_parameters requirement.
- **Section 3 (Selection Architecture):** Complete data flow from FL_STRATEGY context variable through configure.sh `generate_run_config()` to ServerApp `STRATEGY_MAP` factory. Includes bash bridge function and Python factory pattern. Anti-patterns table covers four common mistakes.
- **Section 4 (Parameter Variables):** Eight new Phase 5 contextualization variables with full USER_INPUT definitions, validation rules, Flower mappings, and conditional applicability. FL_STRATEGY extended from 3 to 6 options. Updated variable count: 38 total (was 30).
- **Section 5 (Validation Rules):** Bash pseudocode for boot-time validation including float range checks, byzantine client count formulas, conditional warnings for irrelevant parameters, and FedProx client-side notice.

### Task 2: Checkpointing and Failure Recovery (Sections 6-9)

Appended to `spec/09-training-configuration.md`:

- **Section 6 (Model Checkpointing):** Explicit evaluate_fn implementation (`make_checkpoint_fn`), .npz format recommendation, naming convention (checkpoint_round_N.npz, checkpoint_latest.npz symlink, checkpoint_latest.json metadata), volume mount configuration, and configure.sh additions.
- **Section 7 (Resume from Checkpoint):** Resume workflow (load checkpoint_latest.npz as initial_arrays), Python implementation pattern, round counter restart behavior, and FL_RESUME_ROUND non-implementation rationale.
- **Section 8 (Storage Backend Options):** Four options (local disk, persistent volume, NFS, S3) with recommendation hierarchy. Appliance writes to local path; what backs it is the operator's choice.
- **Section 9 (Failure Recovery):** Four scenarios (SuperNode crash, SuperLink crash, full redeployment, network partition) with checkpoint role, data loss analysis, and recovery time estimates.

## Task Commits

| Task | Commit | Description |
|------|--------|-------------|
| 1+2 | de05920 | Complete spec/09-training-configuration.md (949 lines, all 9 sections) |

## Verification Results

| Check | Result |
|-------|--------|
| File exists and is 400+ lines | PASS (949 lines) |
| All 6 strategies documented | PASS (107 occurrences) |
| All 8 new variables defined | PASS (116 occurrences) |
| FL_STRATEGY update (3->6) documented | PASS |
| generate_run_config() present | PASS (6 occurrences) |
| STRATEGY_MAP present | PASS (6 occurrences) |
| Checkpointing mechanism specified | PASS (evaluate_fn, naming, volume mount) |
| Resume workflow documented | PASS (Section 7) |
| 4 failure recovery scenarios | PASS (Section 9) |
| Byzantine client count validation | PASS (n >= 2f+3 and n >= 4f+3) |

## Decisions Made

1. **Six strategies (not more, not fewer).** FedAvg (default), FedProx (heterogeneity), FedAdam (adaptive optimization), Krum (byzantine-robust), Bulyan (stronger byzantine), FedTrimmedAvg (simple outlier robustness). These cover the mainstream FL use cases without overwhelming operators with choices.

2. **STRATEGY_MAP factory in ServerApp.** Strategy selection happens in Python, not bash. The bash layer bridges context variables to run_config; the Python layer instantiates the correct class with the correct constructor arguments.

3. **.npz as default checkpoint format.** Framework-agnostic via ArrayRecord's NumPy conversion. PyTorch/TensorFlow users can use native formats in custom ServerApps.

4. **No FL_RESUME_ROUND.** Flower has no round offset concept. Documenting the limitation is clearer than implementing a fragile workaround.

5. **Appliance does not manage storage backends.** Checkpoint storage is an infrastructure concern. The appliance creates `/opt/flower/checkpoints`, sets ownership, and mounts it. What backs the path is the operator's choice.

## Deviations from Plan

None -- plan executed exactly as written. Tasks 1 and 2 were committed together because the spec is a single cohesive document written in one pass.

## Next Phase Readiness

Plan 05-02 (cross-cutting updates) can proceed. It will update:
- `spec/03-contextualization-reference.md` with the 8 new variables
- `spec/08-single-site-orchestration.md` with updated SuperLink user_inputs
- `spec/00-overview.md` with Phase 5 entry

## Self-Check: PASSED
