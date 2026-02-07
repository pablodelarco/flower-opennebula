# Requirements: Flower-OpenNebula Integration Spec

**Defined:** 2026-02-05
**Core Value:** Enable privacy-preserving federated learning on distributed OpenNebula infrastructure through marketplace appliances that any tenant can deploy with minimal configuration.

## v1 Requirements

Requirements for initial release of the technical specification.

### Appliance Design

- [x] **APPL-01**: Spec defines SuperLink (server) appliance with QCOW2 packaging, Docker-in-VM architecture, boot-time Flower container pull, and all contextualization parameters
- [x] **APPL-02**: Spec defines SuperNode (client) appliance with pre-configured server connectivity, local data mount points, and ML framework selection via contextualization
- [x] **APPL-03**: Spec maps all Flower configuration parameters to OpenNebula contextualization variables (USER_INPUTS) with types, defaults, and validation rules
- [x] **APPL-04**: Spec defines TLS certificate automation — generation on server boot, distribution to clients via OneGate, correct file ownership for Flower containers (UID 49999)
- [x] **APPL-05**: Spec defines appliance variants for ML frameworks (PyTorch-focused, TensorFlow-focused, lightweight/scikit-learn) with image size targets

### Orchestration & Deployment

- [ ] **ORCH-01**: Spec defines OneFlow service template with SuperLink parent role and SuperNode child roles, "straight" deployment ordering, and cardinality configuration
- [ ] **ORCH-02**: Spec defines multi-site federation architecture — SuperLink in Zone A, SuperNodes across Zones B/C, cross-zone networking (VPN/overlay), certificate trust distribution
- [ ] **ORCH-03**: Spec defines auto-scaling via OneFlow elasticity rules — scale triggers, client join/leave during training, min/max bounds

### Machine Learning & Training

- [ ] **ML-01**: Spec defines aggregation strategy selection via contextualization — FedAvg, FedProx, FedAdam, byzantine-robust options with parameter exposure
- [ ] **ML-02**: Spec defines GPU passthrough configuration — NVIDIA PCI passthrough, UEFI/q35 VM template, Container Toolkit, CUDA memory management, validation script
- [x] **ML-03**: Spec defines pre-built use case templates — at minimum: image classification (ResNet), anomaly detection (IoT), LLM fine-tuning (FlowerTune/PEFT) with contextualization-only deployment
- [ ] **ML-04**: Spec defines model checkpointing to persistent storage — automatic save every N rounds, resume from checkpoint after failure, storage backend options

### Observability

- [ ] **OBS-01**: Spec defines basic monitoring via structured logging — round progress, connected clients, convergence metrics (loss, accuracy per round)
- [ ] **OBS-02**: Spec defines Grafana/Prometheus monitoring stack — metrics exporters, pre-built dashboards, GPU utilization, training convergence curves, alerting rules

### Edge

- [ ] **EDGE-01**: Spec defines edge-optimized SuperNode appliance — lightweight image (<2GB), reduced resource footprint, intermittent connectivity handling, retry logic

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Privacy

- **PRIV-01**: Spec defines differential privacy configuration — noise multiplier, clipping norm, server/client-side options
- **PRIV-02**: Spec defines secure aggregation (SecAgg/SecAgg+) enablement as contextualization option

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| Custom ML training framework | Flower already supports all major frameworks; abstraction layer creates maintenance burden |
| Data management / pipeline system | Data stays local by FL design; data tooling is a separate product domain |
| Custom aggregation server | Flower's SuperLink is battle-tested; use Strategy API for extensions |
| Web-based IDE / notebooks | Development belongs on workstations, not production FL infrastructure |
| Multi-tenant FL orchestration platform | Each tenant deploys own instances; OpenNebula handles isolation at VM level |
| Blockchain audit / incentive layer | Structured logging serves audit needs; blockchain adds massive complexity |
| Homomorphic encryption | Impractical performance overhead; Flower's SecAgg provides meaningful privacy |
| Cross-framework model conversion | All federation clients must use same model architecture; conversion incompatible with FL |
| Building actual appliances | This project produces the spec, not the implementation |
| OpenNebula core platform changes | Integration works within existing marketplace, OneFlow, and contextualization capabilities |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| APPL-01 | Phase 1: Base Appliance Architecture | Complete |
| APPL-02 | Phase 1: Base Appliance Architecture | Complete |
| APPL-03 | Phase 1: Base Appliance Architecture | Complete |
| APPL-04 | Phase 2: Security and Certificate Automation | Complete |
| APPL-05 | Phase 3: ML Framework Variants and Use Cases | Complete |
| ORCH-01 | Phase 4: Single-Site Orchestration | Pending |
| ORCH-02 | Phase 7: Multi-Site Federation | Pending |
| ORCH-03 | Phase 9: Edge and Auto-Scaling | Pending |
| ML-01 | Phase 5: Training Configuration | Pending |
| ML-02 | Phase 6: GPU Acceleration | Pending |
| ML-03 | Phase 3: ML Framework Variants and Use Cases | Complete |
| ML-04 | Phase 5: Training Configuration | Pending |
| OBS-01 | Phase 8: Monitoring and Observability | Pending |
| OBS-02 | Phase 8: Monitoring and Observability | Pending |
| EDGE-01 | Phase 9: Edge and Auto-Scaling | Pending |

**Coverage:**
- v1 requirements: 15 total
- Mapped to phases: 15
- Unmapped: 0

---
*Requirements defined: 2026-02-05*
*Last updated: 2026-02-07 after Phase 3 completion*
