---
phase: 06-gpu-acceleration
plan: 01
subsystem: infra
tags: [gpu, nvidia, iommu, vfio-pci, uefi, q35, cuda, passthrough, nvidia-container-toolkit, pytorch, tensorflow]

# Dependency graph
requires:
  - phase: 01-base-appliance-architecture
    provides: SuperNode appliance baseline (Docker-in-VM, boot sequence, contextualization)
  - phase: 03-ml-framework-variants
    provides: CPU-only framework Docker images (flower-supernode-pytorch, flower-supernode-tensorflow)
provides:
  - Complete GPU passthrough stack specification (4 layers: host, VM, container, application)
  - CUDA memory management patterns for PyTorch and TensorFlow
  - CPU-only fallback path design
  - FL_GPU_* contextualization variable definitions (preview)
  - Decision records for GPU architecture choices
affects: [06-gpu-acceleration/plan-02, 08-monitoring-and-observability]

# Tech tracking
tech-stack:
  added: [iommu, vfio-pci, driverctl, nvidia-driver-545, nvidia-container-toolkit, nvidia-ctk, cuda]
  patterns: [4-layer GPU stack, CPU-only fallback, WARNING-not-FATAL for missing GPU, pre-baked driver installation]

key-files:
  created:
    - spec/10-gpu-passthrough.md
  modified: []

key-decisions:
  - "DR-01: Full GPU passthrough over vGPU (license-free, near-bare-metal performance)"
  - "DR-02: driverctl for persistent driver binding (survives kernel updates)"
  - "DR-03: Memory growth over memory fraction as default (simpler for single-client)"
  - "DR-04: Defer MIG to future phase (complex host setup, limited OpenNebula docs)"
  - "DR-05: CPU fallback is WARNING not FATAL (degraded but functional training)"

patterns-established:
  - "4-layer GPU stack: host prerequisites > VM template > container runtime > application memory"
  - "CPU-only fallback: torch.cuda.is_available() / tf.config.list_physical_devices('GPU') pattern"
  - "FL_GPU_ENABLED as opt-in switch with WARNING on missing GPU"
  - "Pre-baked NVIDIA driver and Container Toolkit in GPU-enabled QCOW2"

# Metrics
duration: 7min
completed: 2026-02-09
---

# Phase 6 Plan 1: GPU Passthrough Stack Summary

**4-layer GPU passthrough spec from IOMMU/VFIO host config through NVIDIA Container Toolkit to PyTorch/TensorFlow CUDA memory management with CPU-only fallback**

## Performance

- **Duration:** 7 min
- **Started:** 2026-02-09T08:55:23Z
- **Completed:** 2026-02-09T09:02:34Z
- **Tasks:** 3
- **Files created:** 1

## Accomplishments
- Complete 861-line GPU passthrough stack specification covering all 4 layers
- Host IOMMU/VFIO configuration with driverctl binding and OpenNebula PCI discovery
- VM template requirements with UEFI, q35, host-passthrough, NUMA-aware pinning
- NVIDIA Container Toolkit installation and Docker GPU integration
- PyTorch and TensorFlow CUDA memory management patterns with usage guidance
- CPU-only fallback path with device detection, logging, and WARNING-not-FATAL design
- 5 decision records (DR-01 through DR-05) justifying architectural choices
- Cross-references to SuperNode, framework variants, contextualization, and training specs

## Task Commits

Each task was committed atomically:

1. **Task 1: Write GPU passthrough stack specification (Layers 1-2)** - `eba49dc` (feat)
2. **Task 2: Write GPU passthrough stack specification (Layers 3-4)** - `9dbb0fe` (feat)
3. **Task 3: Add decision records and cross-references** - `7b526b7` (feat)

## Files Created/Modified
- `spec/10-gpu-passthrough.md` - Complete GPU passthrough stack specification (861 lines, 15 sections)

## Decisions Made
- DR-01: Full GPU passthrough over vGPU -- license-free with near-bare-metal performance; GRID licensing not justified for one-GPU-per-SuperNode use case
- DR-02: driverctl for persistent driver binding -- survives kernel updates, systemd-integrated, recommended by OpenNebula docs
- DR-03: Memory growth as default over memory fraction -- simpler for single-client scenario; fraction available as opt-in override
- DR-04: MIG deferred to future phase -- requires A100/H100 hardware, complex host setup, sparse OpenNebula docs
- DR-05: CPU fallback is WARNING not FATAL -- degraded SuperNode is better than missing one in FL training rounds

## Deviations from Plan

None -- plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None -- no external service configuration required.

## Next Phase Readiness
- GPU passthrough stack fully specified; ready for Plan 06-02 (validation scripts and contextualization integration)
- Plan 06-02 will add FL_GPU_* USER_INPUT definitions to contextualization reference, GPU validation script spec, and SuperNode boot sequence update
- Open questions (MIG profiles, driver version pinning) documented but do not block Plan 06-02

## Self-Check: PASSED

---
*Phase: 06-gpu-acceleration*
*Completed: 2026-02-09*
