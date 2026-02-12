# Flower + OpenNebula

> Privacy-preserving federated learning as a one-click cloud appliance.

[![Flower](https://img.shields.io/badge/Flower-1.25.0-blue)](https://flower.ai/)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-7.0+-brightgreen)](https://opennebula.io/)
[![License](https://img.shields.io/badge/License-Apache_2.0-orange)](LICENSE)
[![Spec](https://img.shields.io/badge/Spec-11%2C500_lines-lightgrey)](#documentation)
[![IPCEI-CIS](https://img.shields.io/badge/EU-IPCEI--CIS-yellow)](#project-context)

## What is this?

A production-ready integration that packages [Flower](https://flower.ai/) federated learning as native [OpenNebula](https://opennebula.io/) marketplace appliances. Deploy a complete FL cluster -- coordinator, training nodes, monitoring dashboard -- from the marketplace with zero code. Set a few context variables, click deploy, and start training across distributed sites while raw data never leaves its source.

This repository contains both the **implementation** (Packer templates, appliance scripts, Docker configs, OneFlow orchestration, a real-time dashboard, and a working CIFAR-10 demo) and a **comprehensive technical specification** (~11,500 lines across 15 documents) covering every design decision.

## Architecture

```
                      OpenNebula Marketplace
                             |
                  +----------+----------+
                  |                     |
          +-------v-------+    +-------v-------+
          | Flower         |    | Flower         |
          | SuperLink      |    | SuperNode      |
          | (QCOW2 image)  |    | (QCOW2 image)  |
          +-------+--------+    +-------+--------+
                  |                     |
          User deploys from       User deploys from
          marketplace, sets       marketplace, sets
          CONTEXT variables       CONTEXT variables
                  |                     |
                  v                     v
          +----------------+    +----------------+
          | Ubuntu 24.04   |    | Ubuntu 24.04   |
          | Docker CE      |    | Docker CE      |
          | flwr/superlink |    | flwr/supernode |
          | Auto-configures|    | Auto-discovers |
          | from CONTEXT   |    | server via     |
          | variables      |    | OneGate        |
          +-------+--------+    +--------+-------+
                  |                      |
                  +--- gRPC (port 9092) -+
                  |                      |
                  v                      v
            Coordinates FL          Trains locally
            rounds, aggregates      on private data
            model updates           sends weights back

  +-----------+
  | Dashboard |
  |   :8080   |
  +-----------+
```

Each appliance is a QCOW2 VM image: Ubuntu 24.04 + Docker + pre-pulled Flower containers. At boot, OpenNebula's contextualization injects configuration and the appliance self-configures. The SuperNode image includes all three ML frameworks (PyTorch, TensorFlow, scikit-learn); set `ONEAPP_FL_FRAMEWORK` to select one at deployment time. Users never SSH in. They never write code. They deploy from the marketplace and get a running FL cluster.

## Features

- **Zero-code deployment** -- Deploy from the OpenNebula marketplace with context variables. No Dockerfiles, no scripts, no SSH.
- **Automatic service discovery** -- SuperLink publishes its endpoint to OneGate; SuperNodes find it automatically.
- **TLS encryption** -- Auto-generated self-signed CA with zero-config setup, or bring your own PKI.
- **Three ML frameworks** -- PyTorch, TensorFlow, and scikit-learn pre-baked in a single SuperNode image. Select at deployment time via `ONEAPP_FL_FRAMEWORK`.
- **Six aggregation strategies** -- FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg.
- **Pre-built use cases** -- Image classification, anomaly detection, LLM fine-tuning. Set one variable, deploy.
- **GPU passthrough** -- Full NVIDIA PCI passthrough with CUDA Container Toolkit. Falls back to CPU gracefully.
- **Three deployment topologies** -- Single-site, multi-site federation (WireGuard VPN), and lightweight edge (<2 GB).
- **Real-time dashboard** -- FastAPI + Tailwind CSS dashboard at port 8080 with animated SVG topology, dark/light mode.
- **OneFlow orchestration** -- One command deploys the full cluster with correct startup ordering and scaling policies.
- **Model checkpointing** -- Automatic save/resume with framework-agnostic NumPy format.
- **Edge resilience** -- Exponential backoff, intermittent WAN tolerance, fault-tolerant aggregation.

## Quick Start

Get a working cluster in ~15 minutes. Full tutorial: **[tutorial/QUICKSTART.md](tutorial/QUICKSTART.md)**

```bash
# Option A: Import from marketplace (recommended)
# In Sunstone: Storage -> Apps -> "Service Flower FL 1.25.0" -> Export

# Option B: Build from source
cd build && make all
oneimage create --name "Flower SuperLink" --path ./export/flower-superlink.qcow2 -d default
oneimage create --name "Flower SuperNode" --path ./export/flower-supernode.qcow2 -d default
onetemplate create /tmp/superlink.tmpl
onetemplate create /tmp/supernode.tmpl
oneflow-template create build/oneflow/flower-cluster.yaml

# Deploy the cluster (SuperLink boots first, SuperNodes auto-discover)
oneflow-template instantiate <service-template-id>

# Run federated training (requires Python 3.11+)
cd demo
python3 -m venv .venv && source .venv/bin/activate
pip install -e .
flwr run . opennebula
```

See also: **[tutorial/BUILD.md](tutorial/BUILD.md)** for building from source with Packer.

## Validated Results

This integration has been validated on a live OpenNebula cluster (1 SuperLink + 2 SuperNodes, 2 vCPU / 4 GB RAM each). Three rounds of FedAvg on CIFAR-10 with privacy-preserving data partitioning:

```
INFO :      Starting Flower ServerApp, config: num_rounds=3, no round_timeout
INFO :      [ROUND 1]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      [ROUND 2]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      [ROUND 3]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      Run finished 3 round(s)
INFO :          History (loss, distributed):
INFO :              round 1: 1.27
INFO :              round 2: 1.03
INFO :              round 3: 0.94
```

Loss dropped from **1.27 to 0.94** across 3 rounds. Only model weights (~3.5 MB per round) crossed the network -- raw CIFAR-10 images never left their respective VMs.

## Dashboard

The real-time monitoring dashboard runs at **port 8080** on the OpenNebula frontend. Built with FastAPI and Tailwind CSS, it provides:

- **Animated SVG topology** -- Visual cluster map showing SuperLink and SuperNode connectivity
- **Live training progress** -- Round-by-round loss/accuracy curves updated in real time
- **Node health** -- Per-VM container status, uptime, resource utilization
- **Dark/light mode** -- Toggleable theme with responsive layout

```bash
cd dashboard && pip install fastapi uvicorn
uvicorn app:app --host 0.0.0.0 --port 8080
```

The dashboard collects state from OpenNebula CLI and Docker container logs via SSH. No agents needed on the VMs.

## Documentation

| Resource | Description |
|----------|-------------|
| **[tutorial/QUICKSTART.md](tutorial/QUICKSTART.md)** | Deploy a cluster in 15 minutes |
| **[tutorial/BUILD.md](tutorial/BUILD.md)** | Build appliance images from source |
| **[spec/00-overview.md](spec/00-overview.md)** | Architecture overview and design principles |
| **[spec/](spec/)** | Full technical specification (15 documents, ~11,500 lines) |

<details>
<summary><strong>The 9 Specification Phases</strong></summary>

### Phase 1: Base Appliance Architecture

Defines the two core appliances -- SuperLink (server) and SuperNode (client) -- with their VM packaging, boot sequences, and all configuration parameters. This is the foundation everything builds on.

**Key deliverables:**
- SuperLink appliance: 12-step boot sequence, Docker container configuration, OneGate publication contract
- SuperNode appliance: 15-step boot sequence, dual discovery model (OneGate + static IP)
- Contextualization reference: 48 variables with types, defaults, and validation rules
- Pre-baked fat image strategy: Docker images pre-pulled in QCOW2, zero network needed at boot

**Spec files:** `spec/01-superlink-appliance.md`, `spec/02-supernode-appliance.md`, `spec/03-contextualization-reference.md`

---

### Phase 2: Security and Certificate Automation

Automatic TLS encryption between SuperLink and SuperNodes -- certificate generation, distribution, and trust establishment.

**How it works:**
1. SuperLink generates a self-signed CA + server certificate at boot
2. CA certificate is published to OneGate (base64-encoded)
3. SuperNodes retrieve the CA cert from OneGate at boot
4. gRPC connection is TLS-encrypted
5. Operators can provide their own certificates via `FL_SSL_*` variables

**Spec files:** `spec/04-tls-certificate-lifecycle.md`, `spec/05-supernode-tls-trust.md`

---

### Phase 3: ML Framework Variants and Use Cases

Separate QCOW2 images per ML framework and pre-built use case templates deployable by setting a single variable.

| Variant | QCOW2 Size | Includes |
|---------|-----------|----------|
| PyTorch | ~4-5 GB | PyTorch, torchvision, PEFT, transformers |
| TensorFlow | ~3 GB | TensorFlow, Keras |
| scikit-learn | ~2.5 GB | scikit-learn, NumPy, pandas |

**Use case templates:** `image-classification`, `anomaly-detection`, `llm-fine-tuning`

**Spec files:** `spec/06-ml-framework-variants.md`, `spec/07-use-case-templates.md`

---

### Phase 4: Single-Site Orchestration

OneFlow service template that deploys a complete Flower cluster (1 SuperLink + N SuperNodes) with automatic dependency ordering and ready-state gating.

**Spec file:** `spec/08-single-site-orchestration.md`

---

### Phase 5: Training Configuration

Aggregation strategy selection, training parameter tuning, and model checkpointing with automatic save/resume.

| Strategy | Use Case |
|----------|----------|
| FedAvg | Default. Homogeneous data. |
| FedProx | Heterogeneous data across clients. |
| FedAdam | Adaptive learning rate, non-IID data. |
| Krum | Byzantine-robust (tolerates malicious clients). |
| Bulyan | Stronger Byzantine robustness. |
| FedTrimmedAvg | Outlier-tolerant aggregation. |

**Spec file:** `spec/09-training-configuration.md`

---

### Phase 6: GPU Acceleration

Complete NVIDIA GPU passthrough stack from host BIOS through VM template to container runtime.

```
Layer 1: Host        IOMMU enabled, VFIO driver bound to GPU
Layer 2: VM          UEFI firmware, q35 machine, PCI passthrough
Layer 3: Container   NVIDIA Container Toolkit, --gpus all
Layer 4: App         CUDA visible devices, memory management
```

**Spec files:** `spec/10-gpu-passthrough.md`, `spec/11-gpu-validation.md`

---

### Phase 7: Multi-Site Federation

Flower deployment across multiple OpenNebula zones -- SuperLink in one datacenter, SuperNodes distributed across others. Cross-zone networking via WireGuard VPN or direct public IP.

**Spec file:** `spec/12-multi-site-federation.md`

---

### Phase 8: Monitoring and Observability

Structured JSON logging, real-time FL Dashboard, and GPU telemetry via DCGM.

| Tier | What | Enabled By |
|------|------|-----------|
| Structured Logging | JSON logs with 12 FL event types | `FL_LOG_FORMAT=json` |
| FL Dashboard | Real-time cluster topology and training progress at port 8080 | Built-in |

**Note:** Flower 1.25.0 does not expose native Prometheus metrics. The FL Dashboard at port 8080 provides monitoring by collecting state from OpenNebula CLI and Docker logs.

**Spec file:** `spec/13-monitoring-observability.md`

---

### Phase 9: Edge and Auto-Scaling

Lightweight edge SuperNode (<2 GB) for constrained environments and OneFlow auto-scaling for dynamic client management.

| Property | Standard SuperNode | Edge SuperNode |
|----------|-------------------|----------------|
| QCOW2 size | 2.5-5 GB | <2 GB |
| Resources | 4 vCPU, 8 GB RAM | 2 vCPU, 2-4 GB RAM |
| Connectivity | Reliable LAN | Intermittent WAN (exponential backoff) |

**Spec file:** `spec/14-edge-and-auto-scaling.md`

</details>

<details>
<summary><strong>Configuration Variables (48 total)</strong></summary>

All 48 variables have sensible defaults. Deploy with zero changes for a working FL cluster running FedAvg for 3 rounds.

### Essential Variables

| Variable | Appliance | Default | What It Controls |
|----------|-----------|---------|-----------------|
| `FLOWER_VERSION` | Both | `1.25.0` | Flower Docker image version |
| `FL_NUM_ROUNDS` | SuperLink | `3` | Number of training rounds |
| `FL_STRATEGY` | SuperLink | `FedAvg` | Aggregation strategy |
| `FL_MIN_FIT_CLIENTS` | SuperLink | `2` | Minimum clients per training round |
| `FL_MIN_AVAILABLE_CLIENTS` | SuperLink | `2` | Minimum clients before training starts |
| `FL_TLS_ENABLED` | Both | `NO` | Enable TLS encryption |
| `FL_GPU_ENABLED` | SuperNode | `NO` | Enable NVIDIA GPU passthrough |
| `FL_USE_CASE` | SuperNode | `none` | Pre-built template to deploy |
| `FL_LOG_FORMAT` | Both | `text` | Log format (`text` or `json`) |
| `FL_METRICS_ENABLED` | SuperLink | `NO` | Enable Prometheus metrics exporter |
| `FL_SUPERLINK_ADDRESS` | SuperNode | _(empty)_ | Static SuperLink address (overrides OneGate) |
| `FL_CHECKPOINT_ENABLED` | SuperLink | `NO` | Enable model checkpointing |

### Variables by Category

| Category | Count | Appliance | Phase |
|----------|-------|-----------|-------|
| Core FL parameters | 11 | SuperLink | 1 |
| SuperNode connection | 7 | SuperNode | 1 |
| TLS placeholders | 5 | Both | 2 |
| Training strategy | 8 | SuperLink | 5 |
| GPU configuration | 3 | SuperNode | 6 |
| Multi-site networking | 3 | Both | 7 |
| Monitoring | 4 | Both | 8 |
| Edge backoff | 2 | SuperNode | 9 |
| Shared infrastructure | 5 | Both | 1 |

Full reference: [`spec/03-contextualization-reference.md`](spec/03-contextualization-reference.md)

</details>

<details>
<summary><strong>Spec Documents Reference</strong></summary>

All specification documents live in `spec/`. Read them in this order:

| # | File | Phase | Lines | What It Covers |
|---|------|-------|-------|---------------|
| 00 | `spec/00-overview.md` | All | 295 | Architecture diagram, design principles, reading order |
| 01 | `spec/01-superlink-appliance.md` | 1 | 652 | SuperLink VM: boot sequence, Docker config, OneGate contract |
| 02 | `spec/02-supernode-appliance.md` | 1 | 663 | SuperNode VM: discovery, boot sequence, data mount |
| 03 | `spec/03-contextualization-reference.md` | 1-9 | 1053 | All 48 variables: definitions, validation, interactions |
| 04 | `spec/04-tls-certificate-lifecycle.md` | 2 | 770 | TLS cert generation, CA publication to OneGate |
| 05 | `spec/05-supernode-tls-trust.md` | 2 | 835 | CA retrieval, TLS mode detection, handshake walkthrough |
| 06 | `spec/06-ml-framework-variants.md` | 3 | 487 | PyTorch/TensorFlow/scikit-learn variant strategy |
| 07 | `spec/07-use-case-templates.md` | 3 | 978 | Image classification, anomaly detection, LLM fine-tuning |
| 08 | `spec/08-single-site-orchestration.md` | 4 | 977 | OneFlow service template, scaling, anti-patterns |
| 09 | `spec/09-training-configuration.md` | 5 | 949 | 6 strategies, checkpointing, failure recovery |
| 10 | `spec/10-gpu-passthrough.md` | 6 | 1119 | 4-layer GPU stack: host, VM, container, application |
| 11 | `spec/11-gpu-validation.md` | 6 | -- | GPU validation scripts and procedures |
| 12 | `spec/12-multi-site-federation.md` | 7 | 952 | Cross-zone topology, WireGuard, gRPC keepalive |
| 13 | `spec/13-monitoring-observability.md` | 8 | 1024 | JSON logging, Prometheus, DCGM, Grafana, alerts |
| 14 | `spec/14-edge-and-auto-scaling.md` | 9 | 801 | Edge variant, auto-scaling, client join/leave |

**Total:** ~11,500 lines of specification across 15 documents.

</details>

## Deployment Topologies

### Single-Site

One OpenNebula zone. SuperLink + SuperNodes on the same network. OneFlow orchestrates everything, OneGate handles discovery.

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
```

### Multi-Site Federation

SuperLink in one zone, SuperNodes across remote zones. WireGuard VPN or direct public IP.

```
     Zone A                  Zone B                  Zone C
  +-----------+          +-----------+          +-----------+
  | SuperLink |<---------| SuperNode |          | SuperNode |
  | (Zone A)  |<---------|  (Zone B) |          |  (Zone C) |
  +-----------+    gRPC  +-----------+          +-----------+
                   over         |                     |
                   WAN    Data stays here        Data stays here
```

### Edge Deployment

Central SuperLink + lightweight edge SuperNodes (<2 GB) on intermittent WAN with exponential backoff.

```
     Coordinator Zone                Edge Sites (intermittent WAN)
  +-----------------+          +-----------+     +-----------+
  |   SuperLink     |<- - - - -| Edge Node |     | Edge Node |
  |   (1 VM)        |   gRPC   | (<2GB)    |     | (<2GB)    |
  |   4 vCPU, 8 GB  |<- - - - -| 2 vCPU    |     | 2 vCPU    |
  +-----------------+   WAN    | 2 GB RAM  |     | 2 GB RAM  |
                       (may    +-----------+     +-----------+
                       drop)
```

## Technology Stack

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| Cloud platform | OpenNebula | 7.0+ | VM management, marketplace, OneFlow, OneGate |
| VM base OS | Ubuntu | 24.04 LTS | Matches Flower Docker image base, LTS until 2029 |
| Container runtime | Docker CE | 24+ | Runs Flower containers, pre-installed in QCOW2 |
| FL coordinator | flwr/superlink | 1.25.0 | Training coordination and aggregation |
| FL client | flwr/supernode | 1.25.0 | Local training with data privacy |
| Guest agent | one-apps | latest | Networking, SSH keys, CONTEXT variables |
| Service discovery | OneGate API | -- | SuperLink endpoint publication and discovery |
| Orchestration | OneFlow | -- | Multi-VM deployment with dependency ordering |
| TLS | OpenSSL | system | Self-signed CA and certificate generation |
| GPU | NVIDIA Container Toolkit | latest | GPU passthrough from host to container |
| GPU metrics | DCGM Exporter | 4.5.1 | GPU telemetry (utilization, memory, temperature) |
| Dashboard | FastAPI + Tailwind CSS | -- | Real-time FL monitoring at port 8080 |
| VPN (multi-site) | WireGuard | system | Encrypted cross-zone networking |

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Packaging | Docker-in-VM (QCOW2) | Native marketplace support, VM isolation, GPU passthrough compatible |
| Base OS | Ubuntu 24.04 LTS | Matches Flower base, LTS until 2029, one-apps support |
| Image strategy | Pre-baked fat images | Zero network dependency at boot -- critical for edge and air-gapped |
| Appliance model | Immutable (configure at boot) | Simple, predictable, no config drift. Redeploy to change. |
| Discovery | Dual: OneGate > static IP | OneGate for single-site, static for multi-site control |
| Reconnection | Delegate to Flower native | No custom wrappers. Flower handles gRPC reconnection. |
| TLS default | Self-signed CA, auto-generated | Zero-config security. Operator PKI as override. |
| Framework variants | Single QCOW2, all frameworks pre-baked | Instant framework selection at boot, no image proliferation |
| GPU approach | Full PCI passthrough | License-free, near-bare-metal performance, simpler than vGPU |
| Monitoring | FL Dashboard + structured logging | No external dependencies, works out of the box |
| Edge base OS | Ubuntu Minimal | one-apps compatibility, consistency with standard stack |
| Edge backoff | Exponential (10s to 300s) | WAN-friendly, avoids hammering coordinator during outages |

## Background

<details>
<summary><strong>What is Federated Learning?</strong></summary>

Traditional ML requires collecting all data in one place. Federated learning keeps data where it is -- the model travels to the data instead:

```
Traditional ML:                     Federated Learning:

  Data A --+                         Site A: Train locally on Data A
  Data B --+--> Central Server          | send only model weights
  Data C --+    trains model            v
                                     Central Server: Aggregate weights
                                        | send updated model back
                                        v
                                     Site B: Train locally on Data B
                                        ...repeat for N rounds...
```

**Key properties:**
- Raw data never leaves its source -- only model weights/gradients are transmitted
- Each participant trains on their own private data locally
- A central server coordinates training rounds and aggregates updates
- After N rounds, the global model has learned from all data without ever seeing it

**Use cases:** Hospitals training diagnostic models without sharing patient records. Telcos building fraud detection across 5G edge sites. Factories doing predictive maintenance without exposing proprietary sensor data.

</details>

<details>
<summary><strong>What is Flower?</strong></summary>

[Flower](https://flower.ai/) (flwr) is the leading open-source federated learning framework:

- **SuperLink** (server): Central coordinator. Manages training rounds, selects clients, aggregates model updates.
- **SuperNode** (client): Training participant. Receives model, trains locally, sends back updated weights.
- **Framework-agnostic**: Works with PyTorch, TensorFlow, JAX, scikit-learn, Hugging Face.
- **Docker images**: Official `flwr/superlink` and `flwr/supernode` on Docker Hub.
- **gRPC communication**: Fleet API on port 9092, optionally with TLS.

Architecture is hub-and-spoke: one SuperLink coordinates N SuperNodes. SuperNodes never communicate with each other.

</details>

<details>
<summary><strong>What is OpenNebula?</strong></summary>

[OpenNebula](https://opennebula.io/) is an open-source cloud platform for managing virtualized infrastructure.

| Concept | What It Does | How We Use It |
|---------|-------------|---------------|
| **Marketplace** | Repository of pre-built VM images | Flower appliances deployed with one click |
| **QCOW2** | VM disk image format | Appliance packaging with everything pre-installed |
| **Contextualization** | Inject config into VMs at boot via CONTEXT vars | Users configure Flower through UI variables |
| **OneFlow** | Multi-VM service orchestration | Deploys full cluster with correct startup ordering |
| **OneGate** | Service metadata API | SuperLink publishes endpoint; SuperNodes discover it |
| **Zones** | Separate deployments across datacenters | Multi-site federation across zones |

</details>

## Project Context

This integration is part of [Fact8ra](https://opennebula.io/), OpenNebula's sovereign AI platform under the EU IPCEI-CIS initiative (~3B EUR investment). Fact8ra federates GPU resources across 8 EU countries to build Europe's first federated AI-as-a-Service platform.

Current capabilities cover AI inference (LLM deployment with Mistral, EuroLLM, Hugging Face). This Flower integration adds **federated training** -- enabling privacy-preserving model training across distributed Fact8ra sites.

**Target users:** Telcos (fraud detection across 5G edge), AI factories / HPC centers (collaborative training), healthcare (diagnostics without sharing patient data), industrial IoT (predictive maintenance across factories).

**Demo target:** April 2026 -- Flower AI Summit (London) / OpenNebula OneNext (Brussels).

## Project Statistics

| Metric | Value |
|--------|-------|
| Specification documents | 15 |
| Lines of specification | ~11,500 |
| Implementation files | 23 (appliance scripts, Packer templates, Docker configs, dashboard, demo) |
| Lines of implementation | ~3,900 |
| Appliance boot steps | 12 (SuperLink) + 15 (SuperNode) |
| Contextualization variables | 48 |
| Aggregation strategies | 6 |
| Deployment topologies | 3 (single-site, multi-site, edge) |
| ML framework variants | 3 (PyTorch, TensorFlow, scikit-learn) |
| Use case templates | 3 (image classification, anomaly detection, LLM fine-tuning) |
| Specification phases | 9 |

## Project Structure

```
flower-opennebula/
  build/
    superlink/appliance.sh        # SuperLink lifecycle script (809 lines)
    supernode/appliance.sh        # SuperNode lifecycle script (971 lines)
    packer/                       # Packer templates for QCOW2 image builds
    docker/                       # Docker Compose stacks for each role
    oneflow/flower-cluster.yaml   # OneFlow service template
    Makefile                      # Build driver
  marketplace/                    # OpenNebula marketplace appliance YAML files
  dashboard/
    app.py                        # FastAPI real-time monitoring dashboard
    static/index.html             # Tailwind CSS frontend with SVG topology
  demo/
    flower_demo/                  # CIFAR-10 federated learning demo (Flower App)
    pyproject.toml                # Flower project config with federation targets
    setup/                        # Cluster verification and preparation scripts
  spec/                           # Technical specification (15 documents)
  tutorial/
    QUICKSTART.md                 # 15-minute deployment guide
    BUILD.md                      # Build from source with Packer
```

## Contributing

Contributions are welcome. Please open an issue first to discuss what you'd like to change.

## License

Apache 2.0

---

*Built by the Cloud-Edge Innovation team at OpenNebula Systems, 2026.*
