# Project Research Summary

**Project:** Flower-OpenNebula Integration Specification
**Domain:** Federated Learning Cloud Infrastructure (Marketplace Appliance)
**Researched:** 2026-02-05
**Confidence:** MEDIUM-HIGH

## Executive Summary

This project integrates the Flower federated learning framework with OpenNebula cloud infrastructure to create marketplace appliances that enable privacy-preserving distributed machine learning. The research reveals that the optimal approach is a **Docker-in-VM hybrid architecture**: QCOW2 base images with Docker pre-installed pull Flower containers at boot, configured via OpenNebula's native contextualization system. This balances VM-level isolation (critical for multi-tenant clouds), version flexibility (no image rebuild for Flower updates), and GPU passthrough compatibility.

The recommended deployment pattern uses OneFlow service templates to orchestrate 1 SuperLink (FL coordinator) + N SuperNodes (training clients) as a coordinated service with automatic dependency ordering. All inter-component communication uses gRPC with TLS, and clients initiate all connections (NAT-friendly for edge/multi-site deployments). The stack leverages Flower 1.25.0's mature architecture (SuperLink/SuperNode/SuperExec components), OpenNebula 7.0's GPU passthrough and contextualization features, and PyTorch as the primary ML framework.

Critical risks center on version drift between server and client appliances (Flower has monthly releases with breaking changes), TLS certificate distribution in marketplace appliances (cannot pre-bake certs, must automate generation), GPU passthrough configuration fragility (IOMMU, VFIO, UEFI firmware stack must align), and multi-site networking assumptions (SuperLink needs stable routable endpoint, gRPC keepalive must survive load balancer timeouts). Mitigation requires versioned appliance pairs, OneGate-based certificate automation, GPU validation scripts, and VPN/overlay networking for multi-site deployments.

## Key Findings

### Recommended Stack

**Docker-in-VM is the primary packaging approach.** A single "Flower Runner" base image contains Ubuntu 24.04 + Docker Engine + NVIDIA Container Toolkit + contextualization scripts. At boot, the VM pulls the appropriate Flower Docker container (flwr/superlink or flwr/supernode) based on contextualization variables. This provides VM-level security isolation while leveraging Flower's official containers without forking.

**Core technologies:**
- **Flower 1.25.0 (flwr)** — Apache 2.0 FL framework, framework-agnostic (PyTorch/TensorFlow/sklearn), hub-and-spoke architecture matches OpenNebula's orchestration model
- **Flower Docker images (flwr/superlink, flwr/supernode)** — Official containers with Ubuntu 24.04 base, multi-arch (amd64/arm64), tagged by version-python-os pattern
- **OpenNebula 7.0+ with OneFlow** — Multi-VM orchestration with "straight" deployment ordering (server before clients), contextualization for config injection, GPU/PCI passthrough
- **gRPC + TLS** — All Flower communication uses gRPC with certificate-based encryption; Let's Encrypt recommended for production certificates
- **PyTorch >= 2.0** — Default ML framework for proof-of-concept; best GPU support and most Flower examples target it
- **NVIDIA GPU passthrough** — PCI passthrough to VMs with VFIO driver binding, UEFI firmware, q35 machine type, CPU pinning for performance

**Key architectural decision:** Use Flower's **subprocess isolation mode** within each VM (SuperExec embedded in SuperLink/SuperNode process) rather than separate containers per component. This simplifies networking — each appliance VM is self-contained with all processes communicating via loopback.

### Expected Features

**Must have (table stakes):**
- **TS-1: One-click server deployment** — Marketplace appliance deploys SuperLink with all dependencies pre-installed
- **TS-2: One-click client deployment** — Marketplace appliance deploys SuperNode pre-configured to connect to specified SuperLink
- **TS-3: Contextualization-driven configuration** — All parameters (server address, TLS certs, training rounds, aggregation strategy) configurable via OpenNebula context variables, no SSH required
- **TS-4: TLS encryption** — gRPC communication encrypted with certificates; mandatory for multi-site/edge deployments
- **TS-5: Framework-agnostic ML support** — Client appliances support PyTorch, TensorFlow, scikit-learn, HuggingFace (recommend 2-3 variants to avoid image bloat)
- **TS-6: Multiple aggregation strategies** — FedAvg, FedProx, FedAdam, byzantine-robust strategies selectable at deployment
- **TS-7: Basic monitoring and status reporting** — Structured logs showing round progress, connected clients, convergence metrics
- **TS-8: OneFlow service template** — Deploy 1 server + N clients as coordinated service with dependency ordering

**Should have (competitive):**
- **D-1: Multi-site federation via OpenNebula Zones** — Deploy SuperLink in one zone, SuperNodes across zones; automate cross-zone networking
- **D-2: Edge-optimized client appliance** — Lightweight SuperNode for constrained environments, intermittent connectivity handling
- **D-3: Integrated monitoring dashboard** — Pre-configured Grafana/Prometheus showing training progress, client health, convergence curves
- **D-4: Privacy-preserving features** — Differential privacy and secure aggregation (SecAgg/SecAgg+) as configuration options
- **D-5: GPU passthrough configuration** — Auto-detect and configure NVIDIA GPU resources for accelerated training
- **D-6: Pre-built use case templates** — Ready-to-deploy configs for image classification, NLP/LLM fine-tuning, anomaly detection
- **D-7: Automatic client scaling** — OneFlow elasticity rules to scale SuperNode count based on demand
- **D-8: Model checkpoint and recovery** — Automatic checkpointing to persistent storage, resume after failure

**Defer (v2+):**
- All anti-features (AF-1 through AF-8): Custom ML training frameworks, data management pipelines, custom aggregation implementations, web-based IDEs, multi-tenant orchestration layer, blockchain audit, homomorphic encryption, cross-framework model conversion

### Architecture Approach

Flower uses a **hub-and-spoke model** with long-running infrastructure components (SuperLink, SuperNode, SuperExec) and short-lived user code (ServerApp, ClientApp). The SuperLink exposes three gRPC APIs: Fleet API (:9092) for client connections, ServerAppIo API (:9091) for server-side coordination, and Control API (:9093) for CLI management. All connections are client-initiated, making the architecture NAT-friendly. Communication is pull-based: SuperNodes poll SuperLink for tasks, execute locally, push results back.

**Major components:**
1. **SuperLink VM (server appliance)** — Runs flwr/superlink container, exposes ports 9091-9093, handles aggregation, needs stable routable IP for multi-site
2. **SuperNode VM (client appliance)** — Runs flwr/supernode container, connects outbound to SuperLink:9092, accesses local training data, optionally GPU-accelerated
3. **OneFlow service template** — Orchestrates deployment with "straight" strategy (server first, clients after server RUNNING), handles role dependencies and scaling
4. **Contextualization scripts** — Configure TLS certificates, discover SuperLink endpoint via OneGate, generate/register auth keys, start Flower services
5. **OneGate coordination layer** — Runtime service discovery (SuperLink advertises endpoint, clients discover it), authentication key exchange, readiness signaling

**Data flow:** Training data NEVER moves (stays on SuperNode VMs). Only model weights and gradients transfer between SuperLink and SuperNodes (~200MB per round for ResNet-50). Flower handles automatic message chunking for large models (>2GB).

### Critical Pitfalls

1. **Flower version drift between server and client appliances** — Flower has monthly releases with breaking changes (v1.24 dropped Python 3.9, bumped protobuf to 5.x, changed auth format). Appliances downloaded weeks apart can have incompatible protocol versions. **Prevention:** Ship server+client as versioned pairs, implement version handshake check in contextualization, use OneFlow to deploy atomically.

2. **TLS certificate distribution in marketplace appliances** — TLS is mandatory but appliances cannot ship with pre-baked certs (per-tenant uniqueness). Manual cert generation is error-prone and skipped by most users. Flower containers run as UID 49999, causing permission errors on mounted certs. **Prevention:** Automate cert generation in contextualization, use OneGate to distribute CA cert from server to clients, set correct file ownership (chown 49999:49999) in startup scripts.

3. **GPU passthrough configuration fragility** — Requires precise stack: IOMMU enabled in BIOS, VFIO driver binding, UEFI firmware, q35 machine type, CPU pinning, correct PCI address. Host-side configuration varies by hardware. OpenNebula has known issues with GPU detection timing. **Prevention:** Create GPU validation script, document host prerequisites, test on target hardware early, offer CPU-only fallback for demo.

4. **SuperLink networking in multi-site deployments** — SuperLink needs routable IP from ALL client sites. gRPC long-lived connections get killed by load balancer idle timeouts (60s-600s depending on platform). Stateful firewalls close "idle" connections between training rounds. **Prevention:** Design cross-site networking (VPN mesh vs public IP) upfront, configure gRPC keepalive < shortest timeout in path, use FQDN not IP for DNS-based failover.

5. **OneGate service discovery fragility** — SuperNodes must discover SuperLink endpoint and wait for readiness before connecting. OneGate has no pub/sub (clients poll), race conditions if client boots before server TLS ready. **Prevention:** Use OneFlow role ordering (server before clients), implement health-check polling loop in client contextualization with exponential backoff, server pushes readiness signal to OneGate after TLS configured.

## Implications for Roadmap

Based on research, suggested phase structure follows a **foundation → single-site → multi-site → advanced** progression. Each phase validates critical assumptions before adding complexity.

### Phase 1: Foundation — Base Appliance Images
**Rationale:** Everything depends on having working base images. Must resolve packaging approach, GPU stack, and contextualization patterns before orchestration.

**Delivers:**
- Base QCOW2 image (Ubuntu 24.04 + Docker + NVIDIA Container Toolkit + contextualization packages)
- SuperLink appliance with server-specific contextualization scripts
- SuperNode appliance with client-specific contextualization scripts + GPU drivers
- TLS certificate automation (generate CA + server cert on boot)
- Version pinning strategy (Flower 1.25.0, PyTorch 2.5)

**Addresses:** TS-1, TS-2, TS-3, TS-4 (table stakes deployment and configuration)

**Avoids:**
- Pitfall 1 (version drift) via versioned appliance pairs
- Pitfall 2 (TLS distribution) via automated cert generation in contextualization
- Pitfall 3 (GPU passthrough) via validation on target hardware
- Pitfall 7 (image bloat) via Docker-in-VM pattern and minimal base

**Research needed:** GPU validation on Beelink/worker nodes (must test IOMMU, VFIO, PCI passthrough end-to-end).

### Phase 2: Orchestration — OneFlow Service Template
**Rationale:** Validates component integration and service discovery patterns on single OpenNebula cloud before adding network complexity.

**Delivers:**
- OneFlow service template (1 SuperLink + N SuperNodes with dependency ordering)
- OneGate integration (endpoint discovery, readiness signaling, auth key exchange)
- Basic FL training job (PyTorch image classification demo)
- Contextualization script hardening (error handling, logging, health checks)
- Model checkpointing to persistent storage

**Addresses:** TS-6, TS-7, TS-8 (aggregation strategies, monitoring, orchestration), D-8 (checkpointing)

**Avoids:**
- Pitfall 5 (OneGate fragility) via role ordering and health-check polling
- Pitfall 9 (contextualization failures) via numbered scripts with error handling
- Pitfall 4 (networking) deferred — single-site uses flat VNET

**Research needed:** None (standard OneFlow patterns, well-documented).

### Phase 3: GPU and Performance
**Rationale:** GPU passthrough is a hard dependency for deep learning workloads. Must be proven before multi-site (which adds debugging complexity).

**Delivers:**
- GPU-enabled SuperNode VM template (UEFI, q35, CPU pinning, PCI passthrough)
- CUDA memory management (per-process GPU memory fraction, MIG support)
- Pre-built use case templates (ResNet image classification, PyTorch-based)
- Performance benchmarking (training time per round, convergence metrics)

**Addresses:** D-5 (GPU passthrough), D-6 (use case templates — at least 1 GPU-based template)

**Avoids:**
- Pitfall 3 (GPU fragility) via validation script and documented host prerequisites
- Pitfall 6 (CUDA memory exhaustion) via per-process memory limits

**Research needed:** Host GPU configuration verification, driver version compatibility matrix.

### Phase 4: Multi-Site Federation
**Rationale:** Builds on proven single-site foundation. Multi-site is the killer feature for FL privacy but requires networking/TLS hardening.

**Delivers:**
- Cross-zone OneFlow templates (server in Zone A, clients in Zone B/C)
- VPN/overlay networking setup (WireGuard or Tailscale between zones)
- gRPC keepalive configuration (survive load balancer timeouts)
- CLI-managed SuperNode authentication (key registration via flwr CLI)
- Cross-site certificate trust (CA distribution pattern)

**Addresses:** D-1 (multi-site via zones), TS-4 hardened (TLS mandatory for cross-zone)

**Avoids:**
- Pitfall 4 (SuperLink networking) via VPN mesh or public IP with firewall rules
- Pitfall 15 (gRPC header stripping) via direct VPN connections, not proxied

**Research needed:** OpenNebula Zone federation mechanics, cross-zone VM communication patterns (need to verify OneGate is zone-local).

### Phase 5: Monitoring and Observability
**Rationale:** Production readiness requires visibility into training progress. Deferred until core FL works end-to-end.

**Delivers:**
- Prometheus + Grafana stack (separate VM or existing monitoring cluster)
- Flower metrics exporters (training loss, accuracy per round, client participation)
- NVIDIA GPU exporter (utilization, memory, temperature)
- Convergence monitoring (detect non-IID data issues)
- Alerting rules (training stalled, client dropout rate)

**Addresses:** D-3 (monitoring dashboard), TS-7 enhanced (beyond basic logs)

**Avoids:**
- Pitfall 8 (non-IID divergence) via convergence monitoring and FedProx default strategy

**Research needed:** None (standard Prometheus/Grafana patterns).

### Phase 6: Edge and Advanced Features
**Rationale:** Most complex topology. Builds on all previous phases.

**Delivers:**
- Lightweight SuperNode appliance (Alpine or minimal Ubuntu, <2GB image)
- Intermittent connectivity handling (retry logic, checkpoint recovery)
- Bandwidth optimization (model compression, gradient quantization)
- OneFlow auto-scaling (elasticity policies based on training demand)
- Differential privacy and secure aggregation configuration

**Addresses:** D-2 (edge-optimized client), D-4 (privacy features), D-7 (auto-scaling)

**Avoids:**
- Pitfall 11 (name length limits) via short naming conventions
- Pitfall 8 (non-IID data) via FedProx default and DP options

**Research needed:** Edge resource requirements (CPU/RAM for CPU-only training), model compression techniques compatible with Flower.

### Phase Ordering Rationale

- **Foundation first (Phase 1)** because appliance packaging decisions (Docker-in-VM, version pinning, contextualization architecture) propagate through all phases
- **Orchestration second (Phase 2)** to validate service discovery and FL end-to-end before adding GPU/multi-site complexity
- **GPU third (Phase 3)** as a standalone validation — if GPU passthrough fails on target hardware, project scope changes significantly
- **Multi-site fourth (Phase 4)** builds on proven single-site, adds networking complexity in isolation
- **Monitoring fifth (Phase 5)** is production hardening, not core functionality
- **Edge last (Phase 6)** is the most complex topology, requires all prior patterns working

**Dependency chain:**
```
Phase 1 (base images)
  → Phase 2 (OneFlow + FL demo)
    → Phase 3 (GPU) — independent of Phase 4
    → Phase 4 (multi-site) — independent of Phase 3
      → Phase 5 (monitoring) — depends on Phases 3+4 for realistic workloads
        → Phase 6 (edge) — depends on all prior
```

Phases 3 and 4 can partially overlap if resourced separately.

### Research Flags

**Phases needing deeper research during planning:**
- **Phase 3 (GPU):** Hardware-specific validation — must test IOMMU, VFIO, driver versions on Beelink/worker nodes before committing to this phase
- **Phase 4 (multi-site):** OpenNebula Zone federation mechanics — need to verify whether OneGate is zone-local or federated, test cross-zone VM-to-VM communication
- **Phase 6 (edge):** Lightweight base image options — need to validate Alpine vs minimal Ubuntu with NVIDIA Container Toolkit support

**Phases with standard patterns (skip research-phase):**
- **Phase 2 (OneFlow):** Well-documented in OpenNebula 7.0 docs, standard service template patterns
- **Phase 5 (monitoring):** Standard Prometheus/Grafana deployment, Flower supports metric export

**Consulting engagement priorities (Flower Labs, EUR 15K budget):**
1. Multi-tenant isolation model (per-tenant SuperLink vs shared SuperLink with run-level isolation)
2. Version compatibility guarantees (can v1.24 SuperNode connect to v1.25 SuperLink?)
3. Certificate automation patterns (any reference implementations for cloud environments?)
4. gRPC keepalive best practices for cloud load balancers
5. GPU memory management for multi-client sharing

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | **HIGH** | Flower Docker images, OpenNebula 7.0 features, GPU passthrough all verified via official docs |
| Features | **MEDIUM-HIGH** | Table stakes features verified against Flower architecture; competitive features extrapolated from FL platform comparisons |
| Architecture | **HIGH** | Flower component model and gRPC communication verified; OpenNebula mapping extrapolated from marketplace appliance patterns (novel integration) |
| Pitfalls | **MEDIUM** | Flower version issues and TLS challenges verified via official docs and changelogs; GPU and multi-site pitfalls based on OpenNebula community forums (medium confidence on specific failure modes) |

**Overall confidence:** MEDIUM-HIGH

Research is strong for Flower and OpenNebula independently. The integration layer is novel (no prior Flower-OpenNebula marketplace appliance exists), so some patterns are extrapolated from general principles rather than verified examples.

### Gaps to Address

**GPU passthrough validation (Phase 1 blocker):**
- **Gap:** Unknown whether Beelink Mini PC (Intel N100) and Raspberry Pi 4 support IOMMU and VFIO for GPU passthrough. If not, need alternative hardware or CPU-only deployment path.
- **Handling:** Run GPU validation script on target hardware in first week of Phase 1. If fails, pivot to CPU-only demo or document different hardware requirements.

**Flower Enterprise licensing (clarification needed):**
- **Gap:** Documentation unclear on whether Helm charts require Enterprise license or if it's just managed TLS/OIDC features. Docker-based deployment (our approach) uses open-source images, but need to confirm no hidden licensing triggers.
- **Handling:** Clarify with Flower Labs during consulting engagement. Likely not blocking (we're using Docker CLI, not Helm).

**OneFlow cross-zone behavior (Phase 4):**
- **Gap:** Unclear whether OneGate service discovery works across OpenNebula federated zones or is zone-local only. If zone-local, multi-site deployments need explicit SuperLink endpoint configuration rather than dynamic discovery.
- **Handling:** Test with federated OpenNebula zones in Phase 4, or fallback to explicit endpoint configuration via contextualization variables (simpler, more predictable).

**openSUSE compatibility (EU-sovereignty requirement):**
- **Gap:** Flower Docker images are Ubuntu 24.04 based. EU-sovereign stack prefers openSUSE guest OS. Need to verify Docker engine + NVIDIA Container Toolkit compatibility on openSUSE 15.
- **Handling:** Test in Phase 1. Docker is OS-agnostic, but driver/kernel interactions may differ. Ubuntu is fallback if issues arise.

**Multi-tenant isolation model (design decision):**
- **Gap:** Unclear whether to recommend per-tenant SuperLink instances (simple, secure, higher resource overhead) or shared SuperLink with Flower's multi-run (complex, efficient, weaker isolation). This decision affects Phase 1 appliance design.
- **Handling:** Default to per-tenant SuperLink for initial release (aligns with OpenNebula multi-tenancy model). Consult with Flower Labs on multi-run isolation guarantees.

## Sources

### Primary (HIGH confidence)

**Flower Framework:**
- Flower Architecture Explanation — https://flower.ai/docs/framework/explanation-flower-architecture.html
- Flower Network Communication Reference — https://flower.ai/docs/framework/ref-flower-network-communication.html
- Flower Docker Documentation — https://flower.ai/docs/framework/docker/index.html
- Flower TLS Configuration — https://flower.ai/docs/framework/how-to-enable-tls-connections.html
- Flower SuperNode Authentication — https://flower.ai/docs/framework/how-to-authenticate-supernodes.html
- Flower Changelog (v1.25.0) — https://flower.ai/docs/framework/ref-changelog.html
- Flower PyPI (v1.25.0, Dec 2025) — https://pypi.org/project/flwr/

**OpenNebula Platform:**
- OpenNebula 7.0 Marketplace Appliances — https://docs.opennebula.io/7.0/product/apps-marketplace/managing_marketplaces/marketapps/
- OpenNebula 7.0 OneFlow — https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/
- OpenNebula 7.0 Contextualization — https://docs.opennebula.io/7.0/product/virtual_machines_operation/guest_operating_systems/kvm_contextualization/
- OpenNebula 7.0 NVIDIA GPU Passthrough — https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/
- OpenNebula OneGate API — https://docs.opennebula.io/6.10/integration_and_development/system_interfaces/onegate_api.html
- one-apps Toolchain — https://github.com/OpenNebula/one-apps/

### Secondary (MEDIUM confidence)

**Integration and Community:**
- Flower Docker Hub (flwr org) — https://hub.docker.com/u/flwr
- Flower + NVIDIA FLARE Integration — https://developer.nvidia.com/blog/supercharging-the-federated-learning-ecosystem-by-integrating-flower-and-nvidia-flare/
- Flower + Red Hat Collaboration — https://flower.ai/blog/2025-11-17-red-hat-flower-collaboration/
- Rhino + Flower Partnership — https://www.rhinofcp.com/news/rhino-flower-partnership
- FEDn Platform (competitive analysis) — https://www.scaleoutsystems.com/framework
- OpenNebula GPU Passthrough Forum Issue #10855 — https://forum.opennebula.io/t/gpu-passthrough-no-longer-works-since-vgpu-support-was-added/10855
- OpenNebula NVIDIA PCI Issue #5968 — https://github.com/OpenNebula/one/issues/5968

### Tertiary (LOW confidence)

**Needs validation during implementation:**
- Flower Enterprise vs open-source feature boundary (Helm licensing requirements unclear)
- openSUSE + NVIDIA Container Toolkit + Flower Docker compatibility (untested combination)
- OneFlow dynamic server IP propagation to client roles across federated zones (mechanism needs verification)
- Edge appliance resource requirements (estimated from general edge computing literature, not FL-specific measurements)

---
*Research completed: 2026-02-05*
*Ready for roadmap: yes*
