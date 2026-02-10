# Flower + OpenNebula: Federated Learning Integration Specification

**A complete technical specification for bringing privacy-preserving federated learning to the OpenNebula cloud platform.**

This document explains what this project is, why it exists, how it works, and how to navigate the specification. If you're new here, read this first.

---

## Table of Contents

1. [What Is This Project?](#1-what-is-this-project)
2. [Background: What Is Federated Learning?](#2-background-what-is-federated-learning)
3. [Background: What Is Flower?](#3-background-what-is-flower)
4. [Background: What Is OpenNebula?](#4-background-what-is-opennebula)
5. [The Integration: Flower Inside OpenNebula](#5-the-integration-flower-inside-opennebula)
6. [Architecture Overview](#6-architecture-overview)
7. [How It Works: Step by Step](#7-how-it-works-step-by-step)
8. [The 9 Phases Explained](#8-the-9-phases-explained)
9. [Deployment Topologies](#9-deployment-topologies)
10. [Technology Stack](#10-technology-stack)
11. [Contextualization Variables (Configuration)](#11-contextualization-variables-configuration)
12. [Spec Documents Reference](#12-spec-documents-reference)
13. [Key Design Decisions](#13-key-design-decisions)
14. [Building the Appliances](#14-building-the-appliances)
15. [Implementation Roadmap](#15-implementation-roadmap)
16. [Project Context](#16-project-context)

---

## 1. What Is This Project?

This repository contains a **technical specification** (not implementation code) that describes exactly how to integrate the [Flower](https://flower.ai/) federated learning framework into [OpenNebula](https://opennebula.io/)'s cloud marketplace.

The goal: **any OpenNebula tenant can deploy a complete federated learning cluster from the marketplace with zero code changes** -- just set a few configuration parameters and click deploy.

The specification covers:
- Two marketplace appliances (server and clients) packaged as QCOW2 VM images
- Automatic service discovery and TLS security
- Support for PyTorch, TensorFlow, and scikit-learn
- Single-site, multi-site, and edge deployment topologies
- GPU acceleration, monitoring, and auto-scaling
- 48 configuration variables that control everything through OpenNebula's contextualization system

**What this is NOT:** This project does not contain Dockerfiles, scripts, or runnable code. It produces markdown specification documents that an engineering team can use to build the actual appliances without ambiguity.

---

## 2. Background: What Is Federated Learning?

Traditional machine learning requires collecting all training data in one place. This creates privacy risks, regulatory problems (GDPR), and bandwidth bottlenecks when data is large or distributed.

**Federated learning (FL)** solves this by keeping data where it is. Instead of moving data to the model, you move the model to the data:

```
Traditional ML:                     Federated Learning:

  Data A ──┐                         Site A: Train locally on Data A
  Data B ──┼──> Central Server          │ send only model weights
  Data C ──┘    trains model            v
                                     Central Server: Aggregate weights
                                        │ send updated model back
                                        v
                                     Site B: Train locally on Data B
                                        │ send only model weights
                                        v
                                     Central Server: Aggregate again
                                        ...repeat for N rounds...
```

**Key properties:**
- Raw data never leaves its source -- only model weights/gradients are transmitted
- Each participant trains on their own private data locally
- A central server coordinates training rounds and aggregates the updates
- After N rounds, the global model has learned from all data without ever seeing it

**Use cases:** Hospitals training a diagnostic model without sharing patient records. Telcos building fraud detection across 5G edge sites. Factories doing predictive maintenance without exposing proprietary sensor data.

---

## 3. Background: What Is Flower?

[Flower](https://flower.ai/) (flwr) is the leading open-source federated learning framework. It provides the runtime infrastructure for FL:

- **SuperLink** (server): The central coordinator. It manages training rounds, selects which clients participate, and aggregates their model updates using a configurable strategy (FedAvg, FedProx, etc.).
- **SuperNode** (client): A training participant. It connects to the SuperLink, receives the current model, trains locally on private data, and sends back the updated weights.
- **Framework-agnostic**: Works with PyTorch, TensorFlow, JAX, scikit-learn, Hugging Face, and more.
- **Docker images**: Official images `flwr/superlink` and `flwr/supernode` available on Docker Hub.
- **gRPC communication**: SuperLink exposes a Fleet API on port 9092. SuperNodes connect to it via gRPC (optionally with TLS).

**Flower's architecture is hub-and-spoke:** one SuperLink coordinates N SuperNodes. SuperNodes never communicate with each other -- they only talk to the SuperLink.

---

## 4. Background: What Is OpenNebula?

[OpenNebula](https://opennebula.io/) is an open-source cloud platform for managing virtualized infrastructure. Think of it as a private cloud management layer.

Key OpenNebula concepts used in this integration:

| Concept | What It Does | How We Use It |
|---------|-------------|---------------|
| **Marketplace** | Repository of pre-built VM images (appliances) that users deploy with one click | We publish Flower SuperLink and SuperNode as marketplace appliances |
| **QCOW2** | VM disk image format | Our appliances are packaged as QCOW2 images with everything pre-installed |
| **Contextualization** | Mechanism to inject configuration into VMs at boot time via `CONTEXT` variables | Users configure Flower through `USER_INPUT` variables (e.g., number of training rounds, aggregation strategy) |
| **OneFlow** | Service orchestration -- deploys multi-VM services with role dependencies | Deploys a complete Flower cluster: 1 SuperLink + N SuperNodes, with correct startup ordering |
| **OneGate** | Service metadata API -- VMs can publish and query runtime information | SuperLink publishes its endpoint; SuperNodes discover it automatically |
| **Zones** | Separate OpenNebula deployments, potentially in different datacenters | Multi-site federation deploys SuperNodes across zones |

---

## 5. The Integration: Flower Inside OpenNebula

Here's what we're building:

```
                        OpenNebula Marketplace
                               |
                    +----------+----------+
                    |                     |
            +-------v-------+    +-------v-------+
            | "Flower        |    | "Flower        |
            |  SuperLink"    |    |  SuperNode"    |
            | (QCOW2 image)  |    | (QCOW2 image)  |
            +----------------+    +----------------+
                    |                     |
            User clicks "Deploy"   User clicks "Deploy"
            sets config params     sets config params
                    |                     |
                    v                     v
            +----------------+    +----------------+
            | Ubuntu 24.04   |    | Ubuntu 24.04   |
            | Docker CE      |    | Docker CE      |
            | Flower server  |    | Flower client  |
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
```

**The key idea:** Package Flower's SuperLink and SuperNode as OpenNebula marketplace appliances (QCOW2 VM images). Each image contains Ubuntu 24.04 + Docker + the Flower container, pre-pulled and ready to go. At boot time, OpenNebula's contextualization system injects configuration (number of rounds, aggregation strategy, TLS settings, etc.) and the appliance auto-configures itself.

Users never SSH into the VMs. They never write code. They deploy from the marketplace, set parameters through OpenNebula's UI, and get a running FL cluster.

---

## 6. Architecture Overview

### The Appliance Design: Docker-in-VM

Each appliance is a VM image (QCOW2) that runs a single Docker container inside:

```
+------------------------------------------+
|              VM (QCOW2)                  |
|                                          |
|  +------------+  +--------------------+  |
|  | Ubuntu     |  | Docker CE 24+      |  |
|  | 24.04 LTS  |  |                    |  |
|  +------------+  |  +---------------+ |  |
|                   |  | flwr/superlink| |  |
|  Contextualization|  | or            | |  |
|  scripts read     |  | flwr/supernode| |  |
|  CONTEXT vars --> |  +---------------+ |  |
|  configure Docker |                    |  |
|  container at     +--------------------+  |
|  boot time                               |
+------------------------------------------+
```

**Why Docker-in-VM (not bare Docker or Kubernetes)?**
- OpenNebula's marketplace natively supports QCOW2 images
- VM isolation provides strong multi-tenant security
- Docker gives us the official Flower images unchanged
- Pre-pulling the Docker image means zero network dependency at boot
- Compatible with GPU passthrough (NVIDIA Container Toolkit inside the VM)

### Communication Flow

```
                    OneGate
                  (metadata API)
                   /        \
          publishes          queries
         endpoint           endpoint
             |                  |
     +-------v--------+  +-----v----------+
     |   SuperLink    |  |   SuperNode    |
     |                |  |                |
     |  Fleet API     |<---  gRPC client  |
     |  port 9092     |  |                |
     |  (TLS optional)|  |  Trains on     |
     |                |  |  local data    |
     |  Aggregates    |  |  /app/data     |
     |  model updates |  |  (read-only)   |
     +----------------+  +----------------+
```

1. **SuperLink boots** (12-step sequence), starts Flower container, publishes its IP and port to OneGate
2. **SuperNode boots** (15-step sequence), queries OneGate to find the SuperLink, connects via gRPC
3. **Training begins**: SuperLink sends model to SuperNodes, they train locally, send back updated weights
4. **Aggregation**: SuperLink combines all updates using the selected strategy (FedAvg by default)
5. **Repeat** for N rounds (default: 3)
6. **Data privacy**: Raw data never leaves SuperNode VMs -- only model weights traverse the network

---

## 7. How It Works: Step by Step

### Deploying a Flower Cluster on OpenNebula

Here's what happens when a user deploys federated learning:

#### Step 1: Choose Appliances from Marketplace

The user selects two appliances from the OpenNebula marketplace:
- **Flower SuperLink** -- the coordinator (1 instance)
- **Flower SuperNode** -- the training clients (N instances, N >= 2)

Three SuperNode variants are available based on ML framework:
- **PyTorch** variant (~4-5 GB QCOW2) -- includes PyTorch + LLM fine-tuning dependencies
- **TensorFlow** variant (~3 GB QCOW2) -- includes TensorFlow
- **scikit-learn** variant (~2.5 GB QCOW2) -- lightweight, for classical ML

#### Step 2: Configure via Contextualization

The user sets configuration through OpenNebula's UI (USER_INPUT variables). Common parameters:

| Variable | Purpose | Default |
|----------|---------|---------|
| `FL_NUM_ROUNDS` | How many training rounds to run | 3 |
| `FL_STRATEGY` | Aggregation strategy | FedAvg |
| `FL_MIN_FIT_CLIENTS` | Minimum clients per round | 2 |
| `FL_TLS_ENABLED` | Enable encrypted communication | NO |
| `FL_GPU_ENABLED` | Enable GPU passthrough | NO |
| `FL_USE_CASE` | Pre-built template (image-classification, anomaly-detection, llm-fine-tuning) | none |

All 48 variables have sensible defaults. A user can deploy with **zero parameters changed** and get a working FL cluster running FedAvg for 3 rounds.

#### Step 3: OneFlow Orchestrates Deployment

If using OneFlow (recommended), the deployment is automated:

1. OneFlow creates the SuperLink VM first (parent role)
2. SuperLink boots through its 12-step sequence:
   - Sources CONTEXT variables
   - Validates all configuration (fail-fast)
   - Generates TLS certificates (if enabled)
   - Starts the Flower container
   - Publishes endpoint to OneGate: `FL_READY=YES`, `FL_ENDPOINT=10.0.0.5:9092`
   - Reports `READY=YES` to OneFlow
3. OneFlow sees SuperLink is ready, creates SuperNode VMs (child role)
4. Each SuperNode boots through its 15-step sequence:
   - Sources CONTEXT variables
   - Queries OneGate to discover SuperLink endpoint
   - Retrieves TLS CA certificate (if TLS enabled)
   - Detects GPU (if enabled)
   - Starts the Flower container with `--superlink 10.0.0.5:9092`
5. SuperNodes connect to SuperLink via gRPC
6. Federated training begins automatically

#### Step 4: Training Runs

Once all SuperNodes connect:

1. SuperLink starts Round 1: sends current model to selected clients
2. Each SuperNode trains locally on its private data (mounted at `/app/data`)
3. SuperNodes send updated model weights back to SuperLink
4. SuperLink aggregates updates using the configured strategy (FedAvg averages them)
5. Repeat for `FL_NUM_ROUNDS` rounds
6. Final aggregated model represents learning from all data -- without any data leaving its source

#### Step 5: Results

After training completes:
- Model checkpoints saved to persistent storage (if `FL_CHECKPOINT_ENABLED=YES`)
- Training logs available via structured JSON logging or Prometheus metrics
- Grafana dashboards show convergence curves, client health, GPU utilization

---

## 8. The 9 Phases Explained

The specification was built in 9 phases, each adding a layer of capability. Here's what each phase contributes and why it matters.

### Phase 1: Base Appliance Architecture

**What:** Defines the two core appliances -- SuperLink (server) and SuperNode (client) -- with their VM packaging, boot sequences, and all configuration parameters.

**Why it matters:** This is the foundation. Without this, nothing else works. It defines *how* Flower runs inside OpenNebula VMs and *how* users configure it.

**Key deliverables:**
- SuperLink appliance spec: 12-step boot sequence, Docker container configuration, OneGate publication contract
- SuperNode appliance spec: 15-step boot sequence, dual discovery model (OneGate + static IP), Flower reconnection delegation
- Contextualization reference: 48 variables with types, defaults, and validation rules
- Pre-baked fat image strategy: Docker images pre-pulled in QCOW2, zero network needed at boot

**Spec files:** `spec/01-superlink-appliance.md`, `spec/02-supernode-appliance.md`, `spec/03-contextualization-reference.md`

---

### Phase 2: Security and Certificate Automation

**What:** Defines automatic TLS encryption between SuperLink and SuperNodes -- certificate generation, distribution, and trust establishment.

**Why it matters:** Federated learning transmits model weights over the network. Without TLS, these weights are sent in plaintext. For production and cross-site deployments, encryption is essential.

**How it works:**
1. SuperLink generates a self-signed CA + server certificate at boot (Step 7a)
2. CA certificate is published to OneGate (base64-encoded)
3. SuperNodes retrieve the CA cert from OneGate at boot (Step 7b)
4. gRPC connection is now TLS-encrypted
5. Alternative: operators can provide their own certificates via `FL_SSL_*` variables

**Key decisions:**
- Self-signed CA by default (zero-config), operator PKI as override
- Certificate files owned by UID 49999 (Flower's container user)
- 365-day validity, no rotation (immutable appliance: redeploy to renew)
- OneGate CA distribution is best-effort; static provisioning as fallback

**Spec files:** `spec/04-tls-certificate-lifecycle.md`, `spec/05-supernode-tls-trust.md`

---

### Phase 3: ML Framework Variants and Use Cases

**What:** Defines separate QCOW2 images per ML framework and pre-built use case templates that users deploy by setting a single variable.

**Why it matters:** A single fat image containing PyTorch + TensorFlow + scikit-learn would be ~8 GB and have library conflicts. Separate variants keep images small and focused.

**Framework variants:**

| Variant | Base Docker Image | QCOW2 Size | Includes |
|---------|-------------------|------------|----------|
| PyTorch | `flower-supernode-pytorch:1.25.0` | ~4-5 GB | PyTorch, torchvision, bitsandbytes, PEFT, transformers (LLM fine-tuning) |
| TensorFlow | `flower-supernode-tensorflow:1.25.0` | ~3 GB | TensorFlow, keras |
| scikit-learn | `flower-supernode-sklearn:1.25.0` | ~2.5 GB | scikit-learn, numpy, pandas |

**Pre-built use case templates** (set `FL_USE_CASE` and deploy):
- `image-classification` -- ResNet on CIFAR-10, works with PyTorch or TensorFlow
- `anomaly-detection` -- Autoencoder on IoT sensor data, scikit-learn
- `llm-fine-tuning` -- FlowerTune with PEFT/LoRA, PyTorch only, requires pre-provisioned data

**Spec files:** `spec/06-ml-framework-variants.md`, `spec/07-use-case-templates.md`

---

### Phase 4: Single-Site Orchestration

**What:** Defines the OneFlow service template that deploys a complete Flower cluster (1 SuperLink + N SuperNodes) with automatic dependency ordering.

**Why it matters:** Without orchestration, users would manually create VMs one by one and configure them. OneFlow automates the entire deployment with correct startup ordering.

**How it works:**
- OneFlow service template defines two roles: `superlink` (parent) and `supernode` (child)
- `deployment: "straight"` ensures SuperLink deploys first
- `ready_status_gate: true` makes OneFlow wait for SuperLink's `READY=YES` before starting SuperNodes
- SuperNode cardinality: default 2, min 2, max 10
- Three-level user_inputs hierarchy: service-level (shared), SuperLink role-level, SuperNode role-level

**Key coordination protocol:**
1. OneFlow creates SuperLink VM
2. SuperLink boots, starts Flower, reports `READY=YES`
3. OneFlow sees ready signal, creates SuperNode VMs
4. SuperNodes boot, discover SuperLink via OneGate, connect
5. Shutdown is reverse: SuperNodes first, then SuperLink

**Spec file:** `spec/08-single-site-orchestration.md`

---

### Phase 5: Training Configuration

**What:** Defines how users select aggregation strategies, tune training parameters, and enable model checkpointing.

**Why it matters:** Different FL scenarios need different strategies. FedAvg works for simple cases, but heterogeneous data needs FedProx, adversarial environments need Byzantine-robust strategies, and long training runs need checkpoint recovery.

**Six supported strategies:**

| Strategy | When to Use | Key Parameter |
|----------|------------|---------------|
| **FedAvg** | Default. Homogeneous data, reliable clients. | -- |
| **FedProx** | Heterogeneous data across clients. | `FL_FEDPROX_MU` (regularization strength) |
| **FedAdam** | Adaptive learning rate, non-IID data. | `FL_FEDADAM_TAU` (adaptivity) |
| **Krum** | Byzantine-robust, up to f malicious clients. | `FL_BYZANTINE_CLIENTS` |
| **Bulyan** | Stronger Byzantine robustness. | `FL_BYZANTINE_CLIENTS` |
| **FedTrimmedAvg** | Outlier-tolerant aggregation. | `FL_TRIM_RATIO` |

**Model checkpointing:**
- Automatic save every N rounds (`FL_CHECKPOINT_INTERVAL`)
- Format: NumPy `.npz` (framework-agnostic via Flower's ArrayRecord)
- Stable path: `checkpoint_latest.npz` symlink + `checkpoint_latest.json` metadata
- Resume from checkpoint after failure (`FL_CHECKPOINT_RESUME=YES`)
- Storage is infrastructure concern (Longhorn PV, NFS, S3-compatible)

**Spec file:** `spec/09-training-configuration.md`

---

### Phase 6: GPU Acceleration

**What:** Defines the complete NVIDIA GPU passthrough stack from host BIOS configuration through VM template to container runtime.

**Why it matters:** Deep learning training is orders of magnitude faster on GPUs. For real-world FL (image classification, LLM fine-tuning), GPU support is essential.

**The 4-layer GPU stack:**

```
Layer 1: Host       IOMMU enabled, VFIO driver bound to GPU (via driverctl)
          |
Layer 2: VM         UEFI firmware, q35 machine type, PCI device passed through
          |
Layer 3: Container  NVIDIA Container Toolkit, --gpus all flag
          |
Layer 4: App        CUDA visible devices, memory management (growth vs fraction)
```

**Configuration variables:**
- `FL_GPU_ENABLED=YES` -- master switch, enables GPU detection at boot Step 9
- `FL_CUDA_VISIBLE_DEVICES` -- restrict which GPUs are visible (default: all)
- `FL_GPU_MEMORY_FRACTION` -- limit GPU memory per process (default: growth mode)

**CPU fallback:** If `FL_GPU_ENABLED=YES` but no GPU is detected, the SuperNode logs a WARNING and continues with CPU-only training. This is intentional -- a degraded SuperNode is better than a missing one.

**Spec files:** `spec/10-gpu-passthrough.md`, `spec/11-gpu-validation.md`

---

### Phase 7: Multi-Site Federation

**What:** Defines how to deploy Flower across multiple OpenNebula zones -- SuperLink in one datacenter, SuperNodes distributed across others.

**Why it matters:** The whole point of federated learning is training across distributed sites. Healthcare data stays in the hospital, telco data stays at the edge site, factory data stays in the plant.

**Architecture:**

```
     Zone A (Coordinator)          Zone B (Training Site)       Zone C (Training Site)
  +-------------------+         +-------------------+        +-------------------+
  | OneFlow Service A |         | OneFlow Service B |        | OneFlow Service C |
  | +-----------+     |         | +-----------+     |        | +-----------+     |
  | | SuperLink |<----+---------+-| SuperNode |     |        | | SuperNode |     |
  | +-----------+     |   gRPC  | +-----------+     |        | +-----------+     |
  +-------------------+  (WAN)  +-------------------+        +-------------------+
                                       |                            |
                                 Data stays here            Data stays here
```

**Key constraint:** OneGate and OneFlow are zone-local. They don't work across zones. So multi-site deployments use:
- Separate OneFlow services per zone (coordinator service + training site services)
- Static `FL_SUPERLINK_ADDRESS` on SuperNodes (no OneGate discovery cross-zone)
- Manual CA certificate distribution via `FL_SSL_CA_CERTFILE`

**Cross-zone networking options:**
1. **WireGuard VPN** (recommended): Hub-and-spoke topology, encrypted tunnel, in-kernel performance
2. **Direct public IP**: Simpler but requires TLS (mandatory), firewall rules for port 9092

**gRPC keepalive:** 60-second interval to survive firewall idle timeouts on WAN connections.

**Spec file:** `spec/12-multi-site-federation.md`

---

### Phase 8: Monitoring and Observability

**What:** Defines structured logging, Prometheus metrics, GPU telemetry, Grafana dashboards, and alerting rules.

**Why it matters:** FL training is a multi-node distributed process. Without monitoring, you're blind to convergence, client health, and GPU utilization.

**Two-tier approach:**

| Tier | What | Infrastructure Needed | Enabled By |
|------|------|----------------------|------------|
| **OBS-01: Structured Logging** | JSON-formatted logs with 12 FL event types (round_start, round_end, client_join, client_leave, etc.) | None -- just `docker logs` | `FL_LOG_FORMAT=json` |
| **OBS-02: Prometheus/Grafana** | 11 FL metrics + 8 GPU metrics, 3 pre-built dashboards, 8 alerting rules | Operator-managed Prometheus + Grafana | `FL_METRICS_ENABLED=YES` |

**Key design:** Appliances run **exporters only** (data sources). The monitoring infrastructure (Prometheus, Grafana, Alertmanager) is operator-managed. This keeps appliance images simple and lets operators use their existing monitoring stack.

**Ports:**
- 9101: FL metrics exporter (SuperLink, when `FL_METRICS_ENABLED=YES`)
- 9400: DCGM GPU metrics (SuperNode, when `FL_DCGM_ENABLED=YES`)

**Pre-built Grafana dashboards:**
1. **FL Training Overview** -- convergence curves (loss/accuracy per round), client participation, round duration
2. **GPU Health** -- utilization, memory, temperature, power, XID errors
3. **Client Health** -- connected clients, failure rates, dropout tracking

**Alerting rules:** Training stalled (no round progress in 30min), excessive client dropout (>50%), GPU memory exhaustion (>95%), GPU temperature critical (>90C), and more.

**Spec file:** `spec/13-monitoring-observability.md`

---

### Phase 9: Edge and Auto-Scaling

**What:** Defines a lightweight edge SuperNode (<2 GB) for constrained environments and OneFlow auto-scaling for dynamic client scaling during training.

**Why it matters:** Edge sites (5G towers, IoT gateways, remote factories) have limited resources and intermittent connectivity. Standard 4-5 GB appliances don't fit. And during training, the number of active clients should adapt to load.

**Edge SuperNode vs Standard:**

| Property | Standard SuperNode | Edge SuperNode |
|----------|-------------------|----------------|
| Base OS | Ubuntu 24.04 (~800 MB) | Ubuntu 24.04 Minimal (~300-400 MB) |
| Docker image | Framework-specific (PyTorch ~4-5 GB) | Base `flwr/supernode:1.25.0` only (~190 MB) |
| QCOW2 size | 2.5-5 GB | <2 GB (target 1.0-1.5 GB) |
| Resources | 4 vCPU, 8 GB RAM, 40 GB disk | 2 vCPU, 2-4 GB RAM, 10-20 GB disk |
| Connectivity | Reliable LAN | Intermittent WAN (exponential backoff) |
| Framework | Pre-baked in image | User-provided custom Docker image |

**Intermittent connectivity handling:**
- Three-layer resilience: Flower-native reconnection + OneGate discovery retry + edge-specific exponential backoff
- `FL_EDGE_BACKOFF=exponential`: starts at 10s, doubles each attempt, caps at 300s (5 min), retries indefinitely
- `FaultTolerantFedAvg` recommended: tolerates 50% client dropout per round

**OneFlow auto-scaling:**
- Elasticity policies on the SuperNode role (never on SuperLink -- it's a singleton)
- Expression-based triggers: `CPU > 80` (scale up), `CPU < 20` (scale down)
- Custom FL metrics via OneGate: `FL_CLIENT_STATUS`, `FL_TRAINING_ACTIVE`, `FL_ROUND_NUMBER`
- Cooldown periods: 300s for scale-up, 600s for scale-down (protects active training rounds)
- Constraint: `min_vms >= FL_MIN_FIT_CLIENTS` to prevent training deadlock

**Spec file:** `spec/14-edge-and-auto-scaling.md`

---

## 9. Deployment Topologies

The specification supports three deployment topologies:

### Single-Site

One OpenNebula zone. SuperLink + SuperNodes on the same network. OneFlow orchestrates everything. OneGate handles service discovery automatically.

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

**Best for:** Getting started, development, single-datacenter deployments.

### Multi-Site Federation

SuperLink in one zone, SuperNodes distributed across remote zones. Each zone has its own OneFlow service. Cross-zone networking via WireGuard VPN or direct public IP.

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

**Best for:** Cross-organization FL, data sovereignty requirements, geographically distributed training.

### Edge Deployment

Central SuperLink + lightweight edge SuperNodes on intermittent WAN. Edge nodes use exponential backoff for discovery retry and tolerate disconnections.

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

**Best for:** IoT/5G edge sites, bandwidth-constrained environments, unreliable networks.

---

## 10. Technology Stack

| Layer | Technology | Version | Purpose |
|-------|-----------|---------|---------|
| Cloud platform | OpenNebula | 7.0+ | VM management, marketplace, OneFlow, OneGate |
| VM base OS | Ubuntu 24.04 LTS | 24.04 | Matches Flower Docker image base. LTS until 2029 |
| Container runtime | Docker CE | 24+ | Runs Flower containers. Pre-installed in QCOW2 |
| FL coordinator | flwr/superlink | 1.25.0 | Flower SuperLink (training coordination, aggregation) |
| FL client | flwr/supernode | 1.25.0 | Flower SuperNode (local training, data privacy) |
| Guest agent | one-apps contextualization | latest | Networking, SSH keys, CONTEXT variables |
| Service discovery | OneGate API | (platform) | SuperLink publishes endpoint; SuperNode discovers it |
| Orchestration | OneFlow | (platform) | Multi-VM service deployment with dependency ordering |
| TLS | OpenSSL | (system) | Self-signed CA and certificate generation |
| GPU | NVIDIA Container Toolkit | latest | GPU passthrough from host to container |
| GPU metrics | DCGM Exporter | 4.5.1 | GPU telemetry (utilization, memory, temperature) |
| Monitoring | Prometheus + Grafana | (operator) | Metrics collection, dashboards, alerting |
| VPN (multi-site) | WireGuard | (system) | Encrypted cross-zone networking |

---

## 11. Contextualization Variables (Configuration)

The specification defines **48 configuration variables** organized by appliance role. All variables have sensible defaults -- you can deploy with zero changes and get a working FL cluster.

### Most Important Variables

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
| `FL_LOG_FORMAT` | Both | `text` | Log format (text or json) |
| `FL_METRICS_ENABLED` | SuperLink | `NO` | Enable Prometheus metrics exporter |
| `FL_SUPERLINK_ADDRESS` | SuperNode | _(empty)_ | Static SuperLink address (overrides OneGate) |
| `FL_CHECKPOINT_ENABLED` | SuperLink | `NO` | Enable model checkpointing |

### Variable Breakdown by Category

| Category | Count | Appliance | Phases |
|----------|-------|-----------|--------|
| Core FL parameters | 11 | SuperLink | 1 |
| SuperNode connection | 7 | SuperNode | 1 |
| TLS placeholders | 5 | Both | 2 |
| Training strategy | 8 | SuperLink | 5 |
| GPU configuration | 3 | SuperNode | 6 |
| Multi-site networking | 3 | Both | 7 |
| Monitoring | 4 | Both | 8 |
| Edge backoff | 2 | SuperNode | 9 |
| Shared infrastructure | 5 | Both | 1 |

Full reference: `spec/03-contextualization-reference.md`

---

## 12. Spec Documents Reference

All specification documents live in the `spec/` directory. Read them in this order:

| # | File | Phase | Lines | What It Covers |
|---|------|-------|-------|---------------|
| 00 | `spec/00-overview.md` | All | 295 | Start here. Architecture diagram, design principles, reading order, deployment topologies |
| 01 | `spec/01-superlink-appliance.md` | 1 | 652 | SuperLink VM: boot sequence, Docker config, OneGate contract, ports |
| 02 | `spec/02-supernode-appliance.md` | 1 | 663 | SuperNode VM: discovery, boot sequence, data mount, reconnection |
| 03 | `spec/03-contextualization-reference.md` | 1-9 | 1053 | All 48 variables: definitions, validation, interactions, cross-reference matrix |
| 04 | `spec/04-tls-certificate-lifecycle.md` | 2 | 770 | TLS cert generation on SuperLink, CA publication to OneGate |
| 05 | `spec/05-supernode-tls-trust.md` | 2 | 835 | CA retrieval on SuperNode, TLS mode detection, handshake walkthrough |
| 06 | `spec/06-ml-framework-variants.md` | 3 | 487 | PyTorch/TensorFlow/scikit-learn variant strategy and Dockerfiles |
| 07 | `spec/07-use-case-templates.md` | 3 | 978 | Image classification, anomaly detection, LLM fine-tuning templates |
| 08 | `spec/08-single-site-orchestration.md` | 4 | 977 | OneFlow service template, deployment sequence, scaling, anti-patterns |
| 09 | `spec/09-training-configuration.md` | 5 | 949 | 6 aggregation strategies, checkpointing, failure recovery |
| 10 | `spec/10-gpu-passthrough.md` | 6 | 1119 | 4-layer GPU stack: host, VM, container, application |
| 11 | `spec/11-gpu-validation.md` | 6 | -- | GPU validation scripts and procedures |
| 12 | `spec/12-multi-site-federation.md` | 7 | 952 | Cross-zone topology, WireGuard VPN, gRPC keepalive, TLS trust |
| 13 | `spec/13-monitoring-observability.md` | 8 | 1024 | JSON logging, Prometheus metrics, DCGM, Grafana dashboards, alerts |
| 14 | `spec/14-edge-and-auto-scaling.md` | 9 | 801 | Edge SuperNode variant, auto-scaling, client join/leave semantics |

**Total:** ~11,500 lines of specification across 15 documents.

---

## 13. Key Design Decisions

These decisions shape the entire architecture:

| Decision | What We Chose | Why |
|----------|--------------|-----|
| **Packaging format** | Docker-in-VM (QCOW2) | Native marketplace support, strong VM isolation, GPU passthrough compatible |
| **Base OS** | Ubuntu 24.04 LTS | Matches Flower Docker image base, LTS until 2029, one-apps support |
| **Image strategy** | Pre-baked fat images | Zero network dependency at boot -- critical for edge and air-gapped |
| **Appliance model** | Immutable (configure once at boot) | Simple, predictable. Redeploy to change config. No config drift |
| **Discovery** | Dual: OneGate (auto) > static IP (manual) | OneGate for single-site automation, static for multi-site control |
| **Reconnection** | Delegate to Flower (`--max-retries 0`) | No custom wrappers. Flower handles gRPC reconnection natively |
| **TLS default** | Self-signed CA, auto-generated | Zero-config security. Operator PKI as override |
| **Framework variants** | Separate QCOW2 per framework | Avoids fat image bloat and library conflicts |
| **GPU approach** | Full PCI passthrough (not vGPU) | License-free, near-bare-metal performance, simpler |
| **Monitoring** | Exporters only in appliances | Operators bring their own Prometheus/Grafana stack |
| **Edge base OS** | Ubuntu Minimal (not Alpine) | one-apps compatibility, consistency with standard stack |
| **Edge backoff** | Exponential (10s to 300s cap) | WAN-friendly, avoids hammering coordinator during outages |

---

## 14. Building the Appliances

The `build/` directory contains everything needed to build the QCOW2 appliance images and deploy a Flower FL cluster on OpenNebula. See **[tutorial/BUILD.md](tutorial/BUILD.md)** for complete step-by-step instructions.

### Quick Start

```bash
# Prerequisites: Packer >= 1.9, QEMU/KVM, one-apps repo, Ubuntu 22.04 base image

# Build both images
cd build
make all INPUT_DIR=./images ONE_APPS_DIR=../one-apps

# Upload to OpenNebula
oneimage create --name "Flower SuperLink" --path ./export/flower-superlink.qcow2 --datastore default
oneimage create --name "Flower SuperNode" --path ./export/flower-supernode.qcow2 --datastore default

# Deploy via OneFlow
oneflow-template create oneflow/flower-cluster.yaml
oneflow-template instantiate <template_id>
```

### Build Directory Structure

```
build/
  superlink/appliance.sh          # SuperLink lifecycle script (one-apps framework)
  supernode/appliance.sh          # SuperNode lifecycle script (one-apps framework)
  packer/
    superlink/                    # Packer template for SuperLink QCOW2
    supernode/                    # Packer template for SuperNode QCOW2
    scripts/                      # Shared provisioning scripts
  oneflow/flower-cluster.yaml     # OneFlow service template
  docker/
    superlink/docker-compose.yml  # SuperLink container stack
    supernode/docker-compose.yml  # SuperNode container stack
  Makefile                        # Build driver
```

---

## 15. Implementation Roadmap

This specification is complete and ready for implementation. Here's a suggested approach:

### Phase A: Build Base Appliances
1. Build SuperLink QCOW2 image (Ubuntu 24.04 + Docker + `flwr/superlink:1.25.0` pre-pulled)
2. Build SuperNode QCOW2 image (same + `flwr/supernode:1.25.0`)
3. Implement contextualization scripts (`configure.sh`, `bootstrap.sh`, `discover.sh`)
4. Test: deploy 1 SuperLink + 2 SuperNodes manually, verify FL training runs

### Phase B: Add Security and Orchestration
5. Implement TLS certificate generation and OneGate distribution
6. Build OneFlow service template with role dependencies
7. Test: deploy via OneFlow with TLS enabled, verify auto-discovery

### Phase C: Add Framework Variants and Use Cases
8. Build framework-specific Docker images (PyTorch, TensorFlow, scikit-learn)
9. Implement use case templates (FL App Bundles)
10. Test: deploy each use case template from marketplace

### Phase D: Advanced Features
11. Implement GPU passthrough configuration and validation
12. Build multi-site federation templates with WireGuard
13. Implement monitoring exporters and Grafana dashboards
14. Build edge QCOW2 variant and test auto-scaling policies

### Validation Items
- Verify QCOW2 image sizes against targets (especially PyTorch ~4-5 GB)
- Validate Ubuntu Minimal + one-apps contextualization compatibility for edge
- Test GPU passthrough on target hardware
- Validate gRPC keepalive behavior across WAN with real firewalls
- Test OneFlow `ready_status_gate` behavior with actual OneFlow version

---

## 16. Project Context

### The Fact8ra Initiative

This integration is part of [Fact8ra](https://opennebula.io/), OpenNebula's sovereign AI platform under the EU's IPCEI-CIS project (Investment ~3B). Fact8ra federates GPU resources across 8 EU countries to build Europe's first federated AI-as-a-Service platform.

Current capabilities cover AI inference (LLM deployment with Mistral, EuroLLM, Hugging Face). This Flower integration adds **federated training** -- enabling privacy-preserving model training across distributed Fact8ra sites.

### Target Users

- **Telcos**: Federated fraud detection and network optimization across 5G edge sites
- **AI Factories / HPC Centers**: Collaborative model training across Fact8ra federation members
- **Healthcare**: Diagnostic models trained across hospitals without sharing patient data
- **Industrial IoT**: Predictive maintenance across factories without exposing proprietary sensor data

### Timeline

Demo-ready target: **April 2026** (Flower AI Summit, London / OpenNebula OneNext, Brussels)

### Budget

Flower Labs consulting budget for integration assistance under the IPCEI-CIS project.

---

## Project Statistics

| Metric | Value |
|--------|-------|
| Specification documents | 15 |
| Total lines of specification | ~11,500 |
| Contextualization variables | 48 |
| Aggregation strategies | 6 |
| Deployment topologies | 3 (single-site, multi-site, edge) |
| ML framework variants | 3 (PyTorch, TensorFlow, scikit-learn) |
| Pre-built use case templates | 3 (image classification, anomaly detection, LLM fine-tuning) |
| Grafana dashboards | 3 |
| Alerting rules | 8 |
| Phases | 9 |
| Plans executed | 20 |
| Requirements satisfied | 15/15 |

---

*This specification was produced by the Cloud-Edge Innovation team at OpenNebula Systems, 2026.*
