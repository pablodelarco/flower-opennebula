# Roadmap: Flower-OpenNebula Integration Spec

## Overview

This roadmap delivers the complete technical specification for integrating the Flower federated learning framework into OpenNebula's marketplace and orchestration platform. The spec progresses from foundational appliance architecture through single-site orchestration, GPU acceleration, multi-site federation, and advanced features. Each phase produces a self-contained spec section that both Flower Labs and OpenNebula engineering can reference and act on. The target is a demo-ready specification for April 2026 events (Flower AI Summit, OpenNebula OneNext).

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: Base Appliance Architecture** - Spec the SuperLink and SuperNode appliance designs with full contextualization parameter mapping
- [x] **Phase 2: Security and Certificate Automation** - Spec TLS certificate lifecycle, OneGate-based distribution, and Flower container permissions
- [x] **Phase 3: ML Framework Variants and Use Cases** - Spec appliance variants per ML framework and pre-built use case templates
- [x] **Phase 4: Single-Site Orchestration** - Spec the OneFlow service template for coordinated Flower cluster deployment
- [ ] **Phase 5: Training Configuration** - Spec aggregation strategy selection, parameter exposure, and model checkpointing
- [ ] **Phase 6: GPU Acceleration** - Spec NVIDIA GPU passthrough, CUDA memory management, and validation procedures
- [ ] **Phase 7: Multi-Site Federation** - Spec cross-zone deployment architecture, networking, and certificate trust distribution
- [ ] **Phase 8: Monitoring and Observability** - Spec structured logging, Prometheus/Grafana monitoring stack, dashboards, and alerting
- [ ] **Phase 9: Edge and Auto-Scaling** - Spec edge-optimized SuperNode appliance and OneFlow elasticity rules

## Phase Details

### Phase 1: Base Appliance Architecture
**Goal**: The spec fully defines both marketplace appliances (SuperLink and SuperNode) with their Docker-in-VM packaging, boot sequences, and every contextualization parameter mapped to Flower configuration
**Depends on**: Nothing (first phase)
**Requirements**: APPL-01, APPL-02, APPL-03
**Success Criteria** (what must be TRUE):
  1. A reader can identify every component in the SuperLink appliance (base OS, Docker engine, contextualization agent, Flower container) and its boot-time initialization sequence
  2. A reader can identify every component in the SuperNode appliance (base OS, Docker engine, ML framework dependencies, Flower container) and how it discovers and connects to the SuperLink
  3. Every Flower configuration parameter has a corresponding OpenNebula USER_INPUT variable with defined type, default value, and validation rule
  4. The spec includes a complete contextualization variable reference table that an engineer could use to implement the appliance without further questions
**Plans**: 3 plans

Plans:
- [x] 01-01-PLAN.md -- SuperLink appliance specification (APPL-01)
- [x] 01-02-PLAN.md -- SuperNode appliance specification (APPL-02)
- [x] 01-03-PLAN.md -- Contextualization reference table and spec overview (APPL-03)

### Phase 2: Security and Certificate Automation
**Goal**: The spec fully defines the TLS certificate lifecycle -- generation on server boot, automated distribution to clients via OneGate, correct file permissions for Flower containers, and the trust chain model
**Depends on**: Phase 1
**Requirements**: APPL-04
**Success Criteria** (what must be TRUE):
  1. The spec defines the exact certificate generation sequence (CA creation, server cert signing, file paths, and ownership set to UID 49999)
  2. The spec defines how the SuperLink publishes its CA certificate to OneGate and how SuperNodes retrieve and trust it
  3. A reader can trace the complete TLS handshake path from SuperNode boot through certificate retrieval to authenticated gRPC connection
**Plans**: 2 plans

Plans:
- [x] 02-01-PLAN.md -- TLS certificate lifecycle specification (SuperLink: generation, provisioning, OneGate publication)
- [x] 02-02-PLAN.md -- SuperNode TLS trust and end-to-end handshake walkthrough

### Phase 3: ML Framework Variants and Use Cases
**Goal**: The spec defines appliance variant strategy (which ML frameworks get dedicated images, with size targets) and provides at least three pre-built use case templates deployable purely through contextualization
**Depends on**: Phase 1
**Requirements**: APPL-05, ML-03
**Success Criteria** (what must be TRUE):
  1. The spec defines at least three appliance variants (PyTorch-focused, TensorFlow-focused, lightweight/scikit-learn) with image size targets and justification for the split
  2. Each use case template (image classification, anomaly detection, LLM fine-tuning) is defined with its required contextualization parameters and expected outputs
  3. A reader can deploy any use case template by setting only contextualization variables -- no SSH, no code changes
  4. The spec includes a decision record for the variant strategy (why these frameworks, why not a single fat image)
**Plans**: 2 plans

Plans:
- [x] 03-01-PLAN.md -- ML framework variant strategy and Dockerfiles (APPL-05)
- [x] 03-02-PLAN.md -- Pre-built use case templates with contextualization-only deployment (ML-03)

### Phase 4: Single-Site Orchestration
**Goal**: The spec defines the OneFlow service template that deploys a complete Flower cluster (1 SuperLink + N SuperNodes) with automatic dependency ordering, OneGate service discovery, and configurable cardinality
**Depends on**: Phase 1, Phase 2
**Requirements**: ORCH-01
**Success Criteria** (what must be TRUE):
  1. The spec includes a complete OneFlow service template (or template skeleton) with SuperLink parent role, SuperNode child roles, and "straight" deployment ordering
  2. The spec defines the OneGate coordination protocol -- SuperLink readiness signaling, endpoint advertisement, and SuperNode discovery polling with backoff
  3. A reader can understand how to deploy a 1+N Flower cluster from the marketplace and what happens at each stage of the deployment sequence
  4. The spec defines cardinality configuration (min, max, default SuperNode count) and how it maps to OneFlow scaling
**Plans**: 2 plans

Plans:
- [x] 04-01-PLAN.md -- OneFlow service template definition, user_inputs mapping, cardinality, and per-node differentiation
- [x] 04-02-PLAN.md -- Deployment sequence walkthrough, OneGate coordination protocol, scaling, and service lifecycle

### Phase 5: Training Configuration
**Goal**: The spec defines how users select aggregation strategies and configure training parameters through contextualization, and how model checkpoints are persisted and recovered
**Depends on**: Phase 4
**Requirements**: ML-01, ML-04
**Success Criteria** (what must be TRUE):
  1. The spec defines every supported aggregation strategy (FedAvg, FedProx, FedAdam, byzantine-robust) with its exposed parameters and when to use each one
  2. The spec defines the checkpointing mechanism -- automatic save frequency, storage backend options (Longhorn PV, NFS, S3-compatible), file format, and resume-from-checkpoint workflow
  3. A reader can configure a non-default aggregation strategy and checkpoint frequency using only contextualization variables
  4. The spec addresses failure recovery -- what happens when a SuperLink or SuperNode crashes mid-training, and how checkpoints enable resumption
**Plans**: 2 plans

Plans:
- [ ] 05-01-PLAN.md -- Aggregation strategy reference, selection architecture, and checkpointing mechanism (ML-01, ML-04)
- [ ] 05-02-PLAN.md -- Cross-cutting updates: contextualization reference, OneFlow service template, and overview (ML-01, ML-04)

### Phase 6: GPU Acceleration
**Goal**: The spec defines the complete GPU passthrough stack from host BIOS configuration through VM template to container runtime, including memory management and a validation procedure
**Depends on**: Phase 1
**Requirements**: ML-02
**Success Criteria** (what must be TRUE):
  1. The spec defines the full GPU passthrough stack: IOMMU/VFIO host prerequisites, UEFI firmware, q35 machine type, PCI device assignment in VM template, NVIDIA Container Toolkit configuration
  2. The spec defines CUDA memory management options (per-process GPU memory fraction, multi-instance GPU support) and when each applies
  3. The spec includes a GPU validation script specification that an engineer could implement to verify the stack is correctly configured
  4. The spec addresses the CPU-only fallback path for environments without GPU passthrough capability
**Plans**: TBD

Plans:
- [ ] 06-01: TBD
- [ ] 06-02: TBD

### Phase 7: Multi-Site Federation
**Goal**: The spec defines how to deploy a Flower federation across multiple OpenNebula zones with cross-zone networking, certificate trust, and gRPC connection resilience
**Depends on**: Phase 2, Phase 4
**Requirements**: ORCH-02
**Success Criteria** (what must be TRUE):
  1. The spec defines the multi-site deployment topology -- SuperLink placement, SuperNode distribution across zones, and the networking requirements for each zone
  2. The spec defines at least two cross-zone networking options (VPN/overlay such as WireGuard, and direct public IP) with trade-offs and selection criteria
  3. The spec defines gRPC keepalive configuration to survive load balancer and stateful firewall idle timeouts, with specific recommended values
  4. The spec defines how TLS certificate trust extends across zones (CA distribution, per-zone client certs, or shared trust bundle)
  5. A reader can plan a 3-zone federation deployment (1 SuperLink zone + 2 SuperNode zones) using only this spec section
**Plans**: TBD

Plans:
- [ ] 07-01: TBD
- [ ] 07-02: TBD
- [ ] 07-03: TBD

### Phase 8: Monitoring and Observability
**Goal**: The spec defines both basic structured logging and a full Prometheus/Grafana monitoring stack for FL training visibility, GPU utilization, and alerting
**Depends on**: Phase 5, Phase 6
**Requirements**: OBS-01, OBS-02
**Success Criteria** (what must be TRUE):
  1. The spec defines structured log format for FL training events -- round progress, connected clients, per-round loss/accuracy, client join/leave events
  2. The spec defines Prometheus metrics exporters for Flower training metrics and NVIDIA GPU utilization with specific metric names and labels
  3. The spec includes pre-built Grafana dashboard definitions (or specifications) showing training convergence curves, client health, and GPU utilization
  4. The spec defines alerting rules for critical conditions (training stalled, excessive client dropout, GPU memory exhaustion)
**Plans**: TBD

Plans:
- [ ] 08-01: TBD
- [ ] 08-02: TBD

### Phase 9: Edge and Auto-Scaling
**Goal**: The spec defines an edge-optimized SuperNode appliance for constrained environments and OneFlow elasticity rules for dynamic client scaling during training
**Depends on**: Phase 4, Phase 7
**Requirements**: ORCH-03, EDGE-01
**Success Criteria** (what must be TRUE):
  1. The spec defines the edge SuperNode appliance with a target image size under 2GB, reduced resource footprint, and differences from the standard SuperNode
  2. The spec defines intermittent connectivity handling -- retry logic, backoff strategy, and how partial participation affects training rounds
  3. The spec defines OneFlow auto-scaling triggers (CPU/memory thresholds, custom metrics), scale-up/down behavior during active training, and min/max bounds
  4. The spec addresses client join/leave semantics -- what happens to an active training round when a SuperNode scales in or an edge node disconnects
**Plans**: TBD

Plans:
- [ ] 09-01: TBD
- [ ] 09-02: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 -> 9
Note: Phases 2, 3, and 6 all depend only on Phase 1 and could execute in parallel if needed.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Base Appliance Architecture | 3/3 | Complete | 2026-02-05 |
| 2. Security and Certificate Automation | 2/2 | Complete | 2026-02-07 |
| 3. ML Framework Variants and Use Cases | 2/2 | Complete | 2026-02-07 |
| 4. Single-Site Orchestration | 2/2 | Complete | 2026-02-07 |
| 5. Training Configuration | 0/2 | Not started | - |
| 6. GPU Acceleration | 0/2 | Not started | - |
| 7. Multi-Site Federation | 0/3 | Not started | - |
| 8. Monitoring and Observability | 0/2 | Not started | - |
| 9. Edge and Auto-Scaling | 0/2 | Not started | - |
