# Flower-OpenNebula Integration: Appliance Specification

**Phases:** 01 - Base Appliance Architecture, 02 - Security and Certificate Automation
**Requirements:** APPL-01, APPL-02, APPL-03, APPL-04
**Status:** Specification

---

## 1. Scope

This specification defines the base appliance architecture for running the Flower federated learning framework on the OpenNebula cloud platform. It covers two marketplace appliances (SuperLink and SuperNode), their Docker-in-VM packaging, boot sequences, and every contextualization parameter needed for zero-config deployment.

**What this phase covers:**
- SuperLink appliance: FL coordinator that orchestrates training rounds and aggregates model updates.
- SuperNode appliance: FL client that trains locally on private data and reports model updates.
- Contextualization variable reference: the complete mapping from OpenNebula USER_INPUTs to Flower configuration.

**What this phase does NOT cover (deferred to later phases):**
- TLS certificate automation (Phase 2)
- ML framework variants and use case templates (Phase 3)
- OneFlow service template orchestration (Phase 4)
- Training configuration and checkpointing (Phase 5)
- GPU passthrough (Phase 6)
- Multi-site federation (Phase 7)
- Monitoring and observability (Phase 8)
- Edge optimization and auto-scaling (Phase 9)

---

## 2. Architecture Diagram

```
+------------------------------------------------------------------+
|                    OpenNebula Cloud Platform                      |
|                                                                   |
|  +-----------------------------+  +-----------------------------+ |
|  |   SuperLink VM (APPL-01)   |  |   SuperNode VM (APPL-02)   | |
|  |                             |  |                             | |
|  |  +------+  +-------------+ |  |  +------+  +-------------+ | |
|  |  |Ubuntu|  |   Docker    | |  |  |Ubuntu|  |   Docker    | | |
|  |  |24.04 |  |   CE 24+   | |  |  |24.04 |  |   CE 24+   | | |
|  |  +------+  +------+------+ |  |  +------+  +------+------+ | |
|  |                    |        |  |                    |        | |
|  |  +-----------------v------+ |  |  +-----------------v------+ | |
|  |  | flwr/superlink:1.25.0 | |  |  | flwr/supernode:1.25.0 | | |
|  |  |                        | |  |  |                        | | |
|  |  |  - Fleet API  :9092    | |  |  |  - ClientApp           | | |
|  |  |  - Control API :9093   |<-------  - Training engine     | | |
|  |  |  - ServerAppIo :9091   | |  |  |  - /app/data (RO)      | | |
|  |  |  - state.db            | |  |  |  - No listening ports   | | |
|  |  +------------------------+ |  |  +------------------------+ | |
|  |                             |  |                             | |
|  |  Contextualization scripts  |  |  Contextualization scripts  | |
|  |  /opt/flower/scripts/       |  |  /opt/flower/scripts/       | |
|  |  - configure.sh             |  |  - configure.sh             | |
|  |  - bootstrap.sh             |  |  - bootstrap.sh             | |
|  |  - health-check.sh          |  |  - discover.sh              | |
|  |  - common.sh                |  |  - health-check.sh          | |
|  +-----------------------------+  |  - common.sh                | |
|              |                    +-----------------------------+ |
|              | OneGate PUT                   | OneGate GET        |
|              v                               v                   |
|  +----------------------------------------------------------+   |
|  |                    OneGate Service                        |   |
|  |  FL_READY=YES  FL_ENDPOINT=ip:9092  FL_VERSION=1.25.0    |   |
|  +----------------------------------------------------------+   |
+------------------------------------------------------------------+
```

**Data flow:**
1. SuperLink boots, starts Flower container, publishes endpoint to OneGate.
2. SuperNode boots, discovers SuperLink via OneGate (or static address), starts Flower container.
3. SuperNode connects to SuperLink Fleet API on port 9092 (gRPC).
4. SuperLink orchestrates training rounds; SuperNode trains locally and reports model updates.
5. Data never leaves the SuperNode VM -- only model weights/gradients are transmitted.

**TLS mode (Phase 2):** When `FL_TLS_ENABLED=YES`, the gRPC connection on port 9092 is encrypted with TLS 1.2+. The SuperLink generates a self-signed CA and server certificate at boot, publishes the CA cert to OneGate, and SuperNodes retrieve it automatically. See `spec/04-tls-certificate-lifecycle.md` and `spec/05-supernode-tls-trust.md` for the complete TLS specification.

---

## 3. Design Principles

| Principle | Description | Implementation |
|-----------|-------------|----------------|
| **Zero-config deployment** | Deploy SuperLink + SuperNode with no parameters changed and see federated learning running. | All 18 user-facing variables have sensible defaults (FedAvg, 3 rounds, insecure mode, subprocess isolation). |
| **Pre-baked fat image** | QCOW2 ships with Docker and Flower image pre-pulled. No network required at boot. | `flwr/superlink:1.25.0` and `flwr/supernode:1.25.0` pre-pulled during image build. Version override triggers pull with fallback. |
| **Immutable appliance** | Configuration applied once at boot. No runtime reconfiguration. Redeploy to change. | Contextualization reads variables once. No config watchers or management APIs. |
| **Linear boot sequence** | Sequential boot steps with fail-fast validation and clear error messages. | SuperLink: 12 steps. SuperNode: 13 steps (extra discovery phase). |
| **Dual discovery** | SuperNode finds SuperLink via OneGate (auto) or static address (manual). | Static address takes precedence. OneGate used in OneFlow deployments. Fails clearly if neither available. |
| **Delegate to Flower** | Boot scripts handle setup; Flower handles all runtime behavior (reconnection, retries, round management). | `--max-retries 0` (unlimited) for reconnection. No custom reconnect wrappers. |
| **Best-effort OneGate** | OneGate publication is useful but not required. SuperLink works without it. | Publication failure logs warning; boot continues. Static addressing works regardless. |

---

## 4. Spec Sections

### Phase 1: Base Appliance Architecture

| Section | File | Requirement | Summary |
|---------|------|-------------|---------|
| SuperLink Appliance | [`spec/01-superlink-appliance.md`](01-superlink-appliance.md) | APPL-01 | FL coordinator: QCOW2 packaging, 12-step boot sequence, Docker container config, OneGate publication contract, 11 contextualization parameters. |
| SuperNode Appliance | [`spec/02-supernode-appliance.md`](02-supernode-appliance.md) | APPL-02 | FL client: dual SuperLink discovery (OneGate + static), 13-step boot sequence, connection lifecycle delegation to Flower, 7 contextualization parameters. |
| Contextualization Reference | [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) | APPL-03 | Complete variable reference: 29 variables total, USER_INPUT definitions, validation rules, zero-config walkthrough, parameter interaction notes. |

### Phase 2: Security and Certificate Automation

| Section | File | Requirement | Summary |
|---------|------|-------------|---------|
| TLS Certificate Lifecycle | [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md) | APPL-04 | SuperLink TLS: self-signed CA generation (OpenSSL), dual provisioning (auto-gen vs operator-provided), boot sequence changes (Step 7a), Docker TLS flags, OneGate CA cert publication (FL_TLS, FL_CA_CERT). |
| SuperNode TLS Trust | [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md) | APPL-04 | SuperNode TLS: CA cert retrieval from OneGate, static provisioning fallback, TLS mode detection (4-case priority), boot sequence changes (Step 7b), Docker `--root-certificates`, end-to-end TLS handshake walkthrough. |

**Reading order:** Start with this overview, then read the Phase 1 specs in order (01, 02, 03). For TLS implementation, continue with Phase 2 specs (04 for SuperLink TLS, then 05 for SuperNode TLS and end-to-end walkthrough).

---

## 5. Technology Stack

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| Cloud platform | OpenNebula | 7.0+ | VM management, marketplace, OneFlow, OneGate, contextualization |
| VM base OS | Ubuntu 24.04 LTS | 24.04 | Matches Flower Docker image base. LTS until 2029. |
| Container runtime | Docker CE | 24+ | Runs Flower containers. Pre-installed in QCOW2. |
| FL coordinator | flwr/superlink | 1.25.0 | Flower SuperLink. Manages training rounds and aggregation. |
| FL client | flwr/supernode | 1.25.0 | Flower SuperNode. Local model training with data privacy. |
| Guest agent | one-apps contextualization | latest | Networking, SSH keys, CONTEXT variables, REPORT_READY. |
| Service discovery | OneGate API | (platform) | SuperLink publishes endpoint; SuperNode discovers it. |
| Orchestration | OneFlow | (platform) | Deploys SuperLink + SuperNode roles with dependency ordering. |
| Utilities | jq, curl, netcat | any | JSON parsing, HTTP calls, TCP health checks. |

---

## 6. Deployment Topology

### Single-Site (Phase 1 Target)

```
                   OneFlow Service
                   +-----------+
                   |           |
            +------v---+  +---v------+  +----------+
            | SuperLink|  | SuperNode|  | SuperNode|
            | (1 VM)   |  | (VM #1)  |  | (VM #2)  |
            +----+-----+  +----+-----+  +----+-----+
                 |              |              |
            Port 9092      gRPC connect    gRPC connect
            (Fleet API)    to SuperLink    to SuperLink
```

**Cardinality:** 1 SuperLink + N SuperNodes (N >= 2 for meaningful federated learning).

### Cross-Site Preview (Phase 7)

```
     Zone A                  Zone B                  Zone C
  +-----------+          +-----------+          +-----------+
  | SuperLink |<---------| SuperNode |          | SuperNode |
  | (Zone A)  |<---------|  (Zone B) |          |  (Zone C) |
  +-----------+    gRPC  +-----------+          +-----------+
                   over         |                     |
                   WAN          v                     v
                        (Local data stays     (Local data stays
                         in Zone B)            in Zone C)
```

Cross-site deployment requires VPN/overlay networking and TLS certificates (Phases 2 and 7).

---

## 7. Key Decisions

Decisions made during Phase 1 specification that constrain future phases.

| # | Decision | Rationale | Affects |
|---|----------|-----------|---------|
| 1 | Ubuntu 24.04 as base OS | Matches Flower Docker image base, LTS until 2029 | All phases (OS is fixed) |
| 2 | Pre-baked fat image strategy | Network-free boot for edge/air-gapped. Fallback on version override failure. | Image build process, Phase 9 (edge) |
| 3 | Subprocess isolation mode as default | Single container per VM. Simplest pattern. Process mode documented but not recommended. | Phase 3 (variants may use process mode) |
| 4 | Immutable appliance model | No runtime reconfiguration. Redeploy to change config. | Phase 4 (OneFlow handles redeployment) |
| 5 | FL_* naming convention | Short prefix, no collision with OpenNebula built-ins. `FLOWER_` for product-level, `FL_` for config. | All phases (naming is established) |
| 6 | TCP port check for SuperLink health | `nc -z localhost 9092`. Zero additional dependencies. | Phase 8 (may upgrade to gRPC health probe) |
| 7 | Dual discovery model | Static IP override > OneGate dynamic > fail. Priority is deterministic. | Phase 7 (cross-site uses static mode) |
| 8 | Flower-native reconnection delegation | `--max-retries 0` (unlimited). No custom reconnect wrappers. | Phase 4 (OneFlow can rely on reconnection) |
| 9 | OneGate publication is best-effort | SuperLink works without OneGate. Only discovery is affected. | Phase 4 (OneFlow templates), Phase 7 (cross-site) |
| 10 | Container UID 49999 ownership | All mounted directories owned by Flower's `app` user. Standard for Flower Docker images. | Phase 2 (certs), Phase 5 (checkpoints) |

---

## 8. Open Questions and Assumptions

### Open Questions

| # | Question | Impact | Status | Resolution Path |
|---|----------|--------|--------|-----------------|
| 1 | Does OneFlow wait for `REPORT_READY` before marking a role as ready for child roles? | If not, SuperNode deployment starts before SuperLink is actually healthy. | Unresolved | Validate during Phase 4 implementation. SuperNode retry loop provides defense-in-depth. |
| 2 | What is the exact JSON path for `FL_ENDPOINT` in the OneGate `/service` response? | Incorrect path breaks dynamic discovery. | Partially verified | jq path `.SERVICE.roles[].nodes[0].vm_info.VM.USER_TEMPLATE.FL_ENDPOINT` matches documentation but needs runtime validation. |
| 3 | Can `${parent.template.context.eth0_ip}` resolve IPs reliably in OneFlow? | If not, OneGate discovery is the only reliable method. | Unresolved | Validate during Phase 4. OneGate discovery is the primary mechanism regardless. |
| 4 | What is the compressed QCOW2 size with all components pre-baked? | If >3 GB, marketplace delivery may be slow. | Estimated ~2 GB | Measure during image build. Soft target: under 3 GB. |

### Assumptions

| # | Assumption | Basis | Risk if Wrong |
|---|------------|-------|---------------|
| 1 | Flower 1.25.0 gRPC protocol is stable for SuperLink-SuperNode communication | Flower maintains backward compatibility within minor versions | Low: version matching constraint mitigates |
| 2 | OneGate link-local endpoint (169.254.16.9:5030) is reachable from tenant VMs | Standard OpenNebula networking configuration | Medium: some network configurations may block link-local. Pre-check handles this. |
| 3 | Docker CE 24+ starts within 60 seconds on target hardware | Standard Docker behavior on modern hardware | Low: timeout is configurable if needed |
| 4 | Ubuntu 24.04 one-apps contextualization packages are available and maintained | OpenNebula actively maintains one-apps for Ubuntu LTS releases | Low: Ubuntu 24.04 is a primary platform |

---

## 9. Phase Roadmap Reference

This spec is Phase 1 of a 9-phase specification project. Each subsequent phase builds on the base architecture defined here.

| Phase | Name | Depends On | Adds To Base Architecture |
|-------|------|------------|---------------------------|
| **1** | **Base Appliance Architecture** | -- | **This phase.** SuperLink + SuperNode appliances with full contextualization. |
| 2 | Security and Certificate Automation | Phase 1 | TLS certificates, OneGate-based cert distribution, `--insecure` removal. |
| 3 | ML Framework Variants | Phase 1 | PyTorch/TensorFlow/sklearn appliance variants, use case templates. |
| 4 | Single-Site Orchestration | Phase 1, 2 | OneFlow service template, coordinated deployment, cardinality config. |
| 5 | Training Configuration | Phase 4 | Advanced strategies, hyperparameter tuning, model checkpointing. |
| 6 | GPU Acceleration | Phase 1 | NVIDIA GPU passthrough, CUDA config, `FL_GPU_ENABLED` activation. |
| 7 | Multi-Site Federation | Phase 2, 4 | Cross-zone deployment, VPN networking, gRPC keepalive tuning. |
| 8 | Monitoring and Observability | Phase 5, 6 | Prometheus metrics, Grafana dashboards, structured logging. |
| 9 | Edge and Auto-Scaling | Phase 4, 7 | Edge-optimized SuperNode, OneFlow elasticity rules. |

**Parallelizable after Phase 1:** Phases 2, 3, and 6 depend only on Phase 1 and can execute in parallel.

---

*Specification Overview: Flower-OpenNebula Appliance Architecture*
*Phases: 01 - Base Appliance Architecture, 02 - Security and Certificate Automation*
*Version: 1.1*
