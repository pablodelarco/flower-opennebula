---
phase: 03-ml-framework-variants-and-use-cases
plan: 01
subsystem: infra
tags: [docker, flower, pytorch, tensorflow, sklearn, qcow2, ml-framework]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperNode appliance spec with base Docker image and ML_FRAMEWORK placeholder variable
provides:
  - Three framework-specific SuperNode Docker image variants with Dockerfiles
  - ML_FRAMEWORK variable runtime behavior and configure.sh selection logic
  - QCOW2 build strategy for framework-specific marketplace appliances
  - Decision records justifying variant approach, framework selection, and LLM dependency placement
affects:
  - 03-02 (use case templates depend on framework variants for dependency availability)
  - 04 (OneFlow templates may reference framework-specific QCOW2 images)
  - 06 (GPU variants extend these CPU-only framework images)

# Tech tracking
tech-stack:
  added: [torch, torchvision, tensorflow-cpu, scikit-learn, pandas, bitsandbytes, peft, transformers, flwr-datasets]
  patterns: [framework-specific Docker image extension from flwr/supernode base, ML_FRAMEWORK case statement selection, separate QCOW2 per variant]

key-files:
  created:
    - spec/06-ml-framework-variants.md
  modified: []

key-decisions:
  - "DR-01: Multiple framework-specific QCOW2 images over single fat image (size, conflict isolation, marketplace clarity)"
  - "DR-02: PyTorch, TensorFlow, scikit-learn as the three supported frameworks (ecosystem coverage, Flower example support)"
  - "DR-03: LLM dependencies (bitsandbytes, peft, transformers) included in PyTorch variant rather than separate fourth variant"
  - "flower-supernode-{framework}:{VERSION} naming convention for custom Docker images"
  - "No fallback between framework variants -- wrong QCOW2 for requested framework is a fatal error"

patterns-established:
  - "Framework Docker image extension: FROM flwr/supernode:1.25.0 + pip install framework"
  - "ML_FRAMEWORK case statement in configure.sh for image tag selection"
  - "CPU-only pip installs: --index-url .../whl/cpu for PyTorch, tensorflow-cpu for TensorFlow"
  - "Separate marketplace listings per framework variant"

# Metrics
duration: 3min
completed: 2026-02-07
---

# Phase 3 Plan 1: ML Framework Variant Strategy Summary

**Three framework-specific SuperNode Docker images (PyTorch with LLM deps, TensorFlow CPU, scikit-learn) with Dockerfiles, size targets, ML_FRAMEWORK selection logic, and ADR-style decision records**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-07T19:41:44Z
- **Completed:** 2026-02-07T19:44:40Z
- **Tasks:** 1
- **Files created:** 1

## Accomplishments
- Complete spec defining three SuperNode Docker image variants extending flwr/supernode:1.25.0
- Full Dockerfiles for PyTorch (with LLM fine-tuning deps), TensorFlow (CPU-only), and scikit-learn variants
- ML_FRAMEWORK contextualization variable behavior fully specified with configure.sh case statement
- QCOW2 build strategy with separate marketplace listings per framework
- Three ADR-style decision records (why variants, why these frameworks, why LLM in PyTorch)
- Cross-references to SuperNode appliance spec, contextualization reference, and boot sequence

## Task Commits

Each task was committed atomically:

1. **Task 1: Write appliance variant strategy specification** - `a6f8972` (feat)

## Files Created/Modified
- `spec/06-ml-framework-variants.md` - Complete ML framework variant strategy specification (APPL-05). 487 lines covering variant overview, Dockerfiles, image size targets, ML_FRAMEWORK variable behavior, QCOW2 build strategy, decision records, and cross-references.

## Decisions Made
- **DR-01: Multiple variants over fat image** -- Separate QCOW2 per framework for size efficiency (~3-5 GB each vs ~5-7 GB fat), framework conflict isolation, and marketplace clarity
- **DR-02: PyTorch, TensorFlow, scikit-learn** -- Covers research/deep learning, enterprise/Keras, and lightweight/tabular workloads. JAX and XGBoost excluded as niche use cases.
- **DR-03: LLM deps in PyTorch variant** -- bitsandbytes, peft, transformers included in PyTorch variant (~500 MB addition) to avoid a fourth variant. LLM fine-tuning always requires PyTorch. Revisit if QCOW2 exceeds 5 GB.
- **Naming convention:** `flower-supernode-{framework}:{VERSION}` distinguishes from official `flwr/supernode` images
- **No cross-framework fallback:** Requesting a framework not pre-baked in the QCOW2 is a fatal error (unlike version override which falls back to pre-baked version)

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness
- Framework variant strategy is complete; ready for Plan 03-02 (use case templates)
- Use case templates can reference the framework variants defined here for dependency availability
- Phase 6 (GPU) can extend these CPU-only variants with CUDA-enabled framework builds
- Image size targets are soft estimates; implementation phase will validate actual sizes

## Self-Check: PASSED

---
*Phase: 03-ml-framework-variants-and-use-cases*
*Completed: 2026-02-07*
