---
phase: 03-ml-framework-variants-and-use-cases
plan: 02
subsystem: spec
tags: [flower, fab, use-cases, cifar10, sklearn, llm, peft, lora, contextualization]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperNode appliance spec with contextualization variables and data mount path
  - phase: 03-01
    provides: Framework-specific Docker images with ML_FRAMEWORK variable and Dockerfiles
provides:
  - Three pre-built use case templates (image-classification, anomaly-detection, llm-fine-tuning)
  - FL_USE_CASE contextualization variable with USER_INPUT definition
  - Framework/use-case compatibility matrix with boot-time validation pseudocode
  - FAB pre-installation and runtime activation patterns
  - Data provisioning strategy (demo auto-download and production pre-provisioned)
affects:
  - 04 (OneFlow templates may set FL_USE_CASE per SuperNode role)
  - 05 (training configuration interacts with use case FAB server_app.py)
  - 06 (LLM fine-tuning use case requires GPU passthrough)

# Tech tracking
tech-stack:
  added: []
  patterns: [FAB pre-installation via flwr install in Dockerfile, FL_USE_CASE compatibility validation at boot, demo/production data provisioning selection]

key-files:
  created:
    - spec/07-use-case-templates.md
  modified: []

key-decisions:
  - "FL_USE_CASE is an optional list variable on SuperNode with default 'none' (no pre-built use case)"
  - "Incompatible ML_FRAMEWORK + FL_USE_CASE combination is a fatal boot error (not a warning)"
  - "LLM fine-tuning has no demo mode -- requires pre-provisioned data at /app/data/instructions.jsonl"
  - "Data provisioning selection is automatic: if /app/data has files, use them; otherwise fall back to flwr-datasets"
  - "image-classification supports both PyTorch (primary) and TensorFlow (alternate) frameworks"

patterns-established:
  - "FAB pre-installation: COPY .fab + flwr install in Dockerfile after pip install of dependencies"
  - "Boot-time compatibility validation: case statement checking FL_USE_CASE against ML_FRAMEWORK"
  - "Data selection pattern: os.path.isdir + os.listdir to choose between local and downloaded data"
  - "LoRA adapter weight exchange for LLM fine-tuning (only trainable params sent to SuperLink)"

# Metrics
duration: 4min
completed: 2026-02-07
---

# Phase 3 Plan 2: Pre-Built Use Case Templates Summary

**Three use case templates (image-classification, anomaly-detection, llm-fine-tuning) with FL_USE_CASE variable, compatibility matrix, FAB lifecycle, and dual-path data provisioning**

## Performance

- **Duration:** 4 min
- **Started:** 2026-02-07T19:46:48Z
- **Completed:** 2026-02-07T19:50:28Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments
- Complete 978-line spec covering ML-03 requirement (pre-built use case templates)
- FL_USE_CASE contextualization variable defined with USER_INPUT format and SuperNode integration
- Framework/use-case compatibility matrix with boot-time validation pseudocode (case statement)
- Three use cases fully specified with contextualization parameters, client_app.py code, expected outputs
- FAB pre-installation process: build pipeline from source to Dockerfile COPY + flwr install
- FAB runtime activation flow: configure.sh activation and subprocess mode constraints
- Data provisioning strategy: demo mode (flwr-datasets auto-download) and production mode (pre-provisioned at /app/data)
- LLM fine-tuning correctly documents GPU as hard dependency (Phase 6), VRAM requirements table, no demo mode
- Updated SuperNode USER_INPUT block with new FL_USE_CASE variable (total: 30 variables)

## Task Commits

Each task was committed atomically:

1. **Task 1: Write use case template specification** - `734d8be` (feat)

## Files Created/Modified
- `spec/07-use-case-templates.md` - Complete use case template specification (ML-03). 978 lines covering all 10 sections: purpose, FL_USE_CASE variable, compatibility matrix, three use case templates, FAB pre-installation, FAB activation, data provisioning, and new variable summary.

## Decisions Made
- **FL_USE_CASE variable:** Optional list on SuperNode, default `none`. Values: none, image-classification, anomaly-detection, llm-fine-tuning.
- **Incompatible combo is fatal:** Boot aborts on invalid ML_FRAMEWORK + FL_USE_CASE pairing (not a warning). Clear error messages show required framework.
- **LLM data is manual-only:** No demo mode for llm-fine-tuning (instruction datasets are task-specific). ClientApp raises FileNotFoundError without pre-provisioned data.
- **Auto data selection:** ClientApp checks /app/data for files; if present, uses local data; otherwise downloads via flwr-datasets.
- **Image classification dual-framework:** Both PyTorch (CNN) and TensorFlow (MobileNetV2) implementations supported; selected by ML_FRAMEWORK value.

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness
- Phase 3 is now complete (both plans: 03-01 variant strategy + 03-02 use case templates)
- Phase 4 (OneFlow orchestration) can reference use case templates and FL_USE_CASE variable
- Phase 5 (training config) can extend strategy selection beyond the FedAvg defaults used in use case templates
- Phase 6 (GPU) is required before LLM fine-tuning use case can be deployed

## Self-Check: PASSED

---
*Phase: 03-ml-framework-variants-and-use-cases*
*Completed: 2026-02-07*
