# Feature Landscape: Flower Federated Learning on OpenNebula

**Domain:** Cloud marketplace appliance for federated learning (Flower framework on OpenNebula)
**Researched:** 2026-02-05
**Overall Confidence:** MEDIUM-HIGH (Flower architecture and features well-documented; marketplace appliance patterns extrapolated from OpenNebula docs and FL platform comparisons)

---

## Table Stakes

Features users expect. Missing any of these makes the integration non-functional or unserious for production use.

### TS-1: One-Click Server Deployment

| Aspect | Detail |
|---------|--------|
| **What** | Marketplace appliance that deploys a Flower SuperLink with all dependencies pre-installed |
| **Why Expected** | This is the entire point of a marketplace appliance. If deploying the server is manual, there is no value over raw Docker/Helm |
| **Complexity** | Medium |
| **Deployment Scenarios** | All (single-site, multi-site, edge, hybrid) |
| **Dependencies** | OpenNebula contextualization, Flower Docker images |
| **Notes** | SuperLink is the hub of Flower's hub-and-spoke architecture. It exposes three APIs: ServerAppIO (9091), Fleet API (9092), Control API (9093). The appliance must configure and expose all three |

### TS-2: One-Click Client Deployment

| Aspect | Detail |
|---------|--------|
| **What** | Marketplace appliance that deploys a Flower SuperNode pre-configured to connect to a specified SuperLink |
| **Why Expected** | Clients are the distributed workforce. Deploying them must be as trivial as the server |
| **Complexity** | Medium |
| **Deployment Scenarios** | All |
| **Dependencies** | TS-1 (server must exist first), network connectivity to SuperLink |
| **Notes** | SuperNode connects to SuperLink's Fleet API (9092). Must accept server address, node config (partition-id, num-partitions), and ML framework dependencies via contextualization parameters |

### TS-3: Contextualization-Driven Configuration

| Aspect | Detail |
|---------|--------|
| **What** | All critical parameters configurable at deployment time through OpenNebula contextualization (no SSH required) |
| **Why Expected** | OpenNebula tenants expect to configure appliances through the Sunstone UI or API, not by logging into VMs |
| **Complexity** | Medium |
| **Deployment Scenarios** | All |
| **Dependencies** | OpenNebula contextualization packages in appliance images |
| **Parameters (Server)** | Number of training rounds, aggregation strategy (FedAvg/FedProx/FedAdam/etc.), minimum clients required, TLS certificates path, listening ports |
| **Parameters (Client)** | SuperLink address:port, node partition config, ML framework selection (PyTorch/TensorFlow/etc.), dataset path/config, GPU enablement, TLS root certificate |
| **Notes** | OpenNebula contextualization supports custom attributes passed to boot scripts. These map naturally to Flower's CLI flags |

### TS-4: TLS Encryption

| Aspect | Detail |
|---------|--------|
| **What** | Encrypted communication between SuperLink and SuperNodes using TLS certificates |
| **Why Expected** | Model updates in transit contain information that can leak training data characteristics. Unencrypted FL is a non-starter for any regulated use case (healthcare, finance, telco) |
| **Complexity** | Medium |
| **Deployment Scenarios** | All (critical for multi-site and edge) |
| **Dependencies** | Certificate generation/distribution mechanism |
| **Implementation** | Flower natively supports TLS: SuperLink takes `--ssl-ca-certfile`, `--ssl-certfile`, `--ssl-keyfile`; SuperNode takes `--root-certificates`. The appliance must support injecting certificates via contextualization or a shared secret store |
| **Notes** | Flower docs explicitly state "real deployments require TLS." The `--insecure` flag is development-only |

### TS-5: Framework-Agnostic ML Support

| Aspect | Detail |
|---------|--------|
| **What** | Client appliances support major ML frameworks: PyTorch, TensorFlow, scikit-learn, HuggingFace Transformers, JAX, XGBoost |
| **Why Expected** | Flower's core value proposition is framework-agnosticism. Limiting to one framework defeats the purpose |
| **Complexity** | High (image size, dependency management) |
| **Deployment Scenarios** | All |
| **Dependencies** | Sufficient disk space in appliance images; potentially multiple appliance variants |
| **Notes** | Recommend offering 2-3 appliance variants rather than one bloated image: (1) PyTorch-focused, (2) TensorFlow-focused, (3) Lightweight (scikit-learn/XGBoost). Each ~5-15GB depending on GPU driver inclusion |

### TS-6: Multiple Aggregation Strategies

| Aspect | Detail |
|---------|--------|
| **What** | Support for Flower's built-in aggregation strategies selectable at deployment time |
| **Why Expected** | Different use cases require different strategies. FedAvg is basic; real workloads need FedProx (heterogeneous data), FedAdam (adaptive optimization), Byzantine-robust options (Krum, Bulyan) |
| **Complexity** | Low (Flower provides these; appliance just needs to expose the selection) |
| **Deployment Scenarios** | All |
| **Dependencies** | TS-3 (contextualization) |
| **Available Strategies** | FedAvg, FedAdam, FedAdagrad, FedAvgM, FedMedian, FedProx, FedTrimmedAvg, FedYogi, QFedAvg, Bulyan, Krum, MultiKrum, FedXgbBagging, FedXgbCyclic |
| **Notes** | Strategy selection is a server-side parameter. Expose as a dropdown/enum in contextualization with FedAvg as default |

### TS-7: Basic Monitoring and Status Reporting

| Aspect | Detail |
|---------|--------|
| **What** | Visibility into training status: current round, connected clients, convergence metrics (loss, accuracy per round) |
| **Why Expected** | FL training runs for hours/days. Operators need to know if training is progressing, stalled, or failing |
| **Complexity** | Medium |
| **Deployment Scenarios** | All |
| **Dependencies** | Flower logging configuration, log export mechanism |
| **Notes** | At minimum: structured logs from SuperLink showing round progress, client participation, aggregated metrics. Flower supports configurable logging. More advanced dashboarding is a differentiator (see D-3) |

### TS-8: OneFlow Service Template for Multi-VM Deployment

| Aspect | Detail |
|---------|--------|
| **What** | A OneFlow Service Template that orchestrates deploying 1 SuperLink + N SuperNodes as a coordinated service with correct startup ordering |
| **Why Expected** | Deploying server and clients individually is tedious and error-prone. OneFlow's multi-VM orchestration with deployment dependencies is the native OpenNebula way to handle this |
| **Complexity** | Medium |
| **Deployment Scenarios** | Single-site primarily; provides the foundation for multi-site |
| **Dependencies** | TS-1, TS-2, TS-3 |
| **Notes** | OneFlow supports deployment strategies where child roles wait for parent roles to reach RUNNING state. The SuperLink role deploys first, then SuperNode roles deploy with the SuperLink address injected via contextualization. This is a natural fit |

---

## Differentiators

Features that set this integration apart from "just use Docker Compose on a VM." These provide competitive advantage for OpenNebula marketplace positioning.

### D-1: Multi-Site Federation via OpenNebula Zones

| Aspect | Detail |
|---------|--------|
| **What** | Deploy SuperLink in one OpenNebula zone and SuperNodes across other zones, with the marketplace appliance handling cross-zone networking configuration |
| **Value Proposition** | This is the killer feature for OpenNebula. No other FL marketplace offering natively spans cloud zones. Multi-site federation is where FL delivers its core privacy value |
| **Complexity** | High |
| **Deployment Scenarios** | Multi-site, hybrid |
| **Dependencies** | TS-1, TS-2, TS-4 (TLS mandatory for cross-zone), cross-zone networking |
| **Notes** | Flower's architecture already supports this (SuperNodes connect outbound to SuperLink). The challenge is network configuration: firewall rules, DNS resolution, certificate distribution across zones. The appliance should automate or document this clearly |

### D-2: Edge-Optimized Client Appliance

| Aspect | Detail |
|---------|--------|
| **What** | Lightweight SuperNode appliance optimized for edge/constrained environments with smaller image size, lower resource requirements, and intermittent connectivity handling |
| **Value Proposition** | Directly targets the Telco Edge AI use case (priority 1). Edge nodes have limited resources and unreliable connectivity. A purpose-built edge appliance signals seriousness about this market |
| **Complexity** | High |
| **Deployment Scenarios** | Edge, hybrid |
| **Dependencies** | TS-2 |
| **Notes** | Edge-specific concerns: smaller container images, graceful handling of network interruptions (Flower SuperNodes reconnect automatically), reduced memory footprint, optional GPU passthrough for inference acceleration. Consider Alpine-based or distroless images |

### D-3: Integrated Monitoring Dashboard

| Aspect | Detail |
|---------|--------|
| **What** | Pre-configured Grafana/Prometheus stack bundled with the server appliance showing training progress, client health, resource utilization, and convergence curves |
| **Value Proposition** | Transforms FL from a black box into an observable system. Competing platforms (FEDn Studio, NVIDIA FLARE dashboard, FATE Board) all offer this. Without it, the offering looks incomplete |
| **Complexity** | Medium-High |
| **Deployment Scenarios** | All |
| **Dependencies** | TS-7 (basic monitoring), metrics export from Flower |
| **Key Metrics** | Training loss per round, validation accuracy per round, client participation rate, round duration, communication overhead (bytes transferred), per-client training time, model parameter delta (convergence indicator) |
| **Notes** | Flower supports configurable logging. Metrics can be exported via custom strategy callbacks. A lightweight Prometheus endpoint + Grafana dashboard (similar to what the kubernetes-homelab monitoring stack does) would be appropriate |

### D-4: Privacy-Preserving Features (Differential Privacy + Secure Aggregation)

| Aspect | Detail |
|---------|--------|
| **What** | Enable Flower's built-in differential privacy strategies and secure aggregation (SecAgg/SecAgg+) through appliance configuration |
| **Value Proposition** | Privacy is the raison d'etre of federated learning. Offering DP and SecAgg as checkbox features positions the platform for regulated industries (healthcare, finance) |
| **Complexity** | Medium (Flower provides the implementations; appliance exposes configuration) |
| **Deployment Scenarios** | All, especially healthcare and finance use cases |
| **Dependencies** | TS-6 (aggregation strategies) |
| **Flower DP Options** | Server-side fixed/adaptive clipping, client-side fixed/adaptive clipping. Key parameters: noise multiplier, clipping norm, number of sampled clients |
| **Flower SecAgg Options** | SecAgg and SecAgg+ protocols for semi-honest threat model, robust against client dropouts |
| **Notes** | DP parameters require careful tuning (privacy budget vs. model utility tradeoff). Provide sensible defaults with clear documentation. Do NOT make DP the default -- it degrades model quality and should be an explicit opt-in |

### D-5: GPU Passthrough Configuration

| Aspect | Detail |
|---------|--------|
| **What** | Client appliances that auto-detect and configure GPU resources (NVIDIA CUDA) for accelerated training |
| **Value Proposition** | Deep learning workloads are impractical without GPUs. Making GPU setup zero-config removes a major deployment friction point |
| **Complexity** | High (driver compatibility, CUDA versions, OpenNebula PCI passthrough) |
| **Deployment Scenarios** | All (especially single-site and edge with GPU-equipped nodes) |
| **Dependencies** | TS-2, OpenNebula GPU/PCI passthrough support, NVIDIA drivers in appliance |
| **Notes** | OpenNebula supports PCI passthrough for GPUs. The appliance needs NVIDIA Container Toolkit or bare-metal CUDA drivers pre-installed. Consider separate GPU and CPU-only appliance variants |

### D-6: Pre-Built Use Case Templates

| Aspect | Detail |
|---------|--------|
| **What** | Ready-to-deploy configurations for common FL scenarios: image classification, NLP/LLM fine-tuning, anomaly detection, predictive maintenance |
| **Value Proposition** | Reduces time-to-value from days to minutes. Users deploy a template, point it at their data, and start training. This is what separates a platform from a framework |
| **Complexity** | Medium per template (requires curating model architectures, training configs, example datasets) |
| **Deployment Scenarios** | All |
| **Dependencies** | TS-3, TS-5, TS-6 |
| **Priority Templates** | (1) Image classification with ResNet/MobileNet (simplest demo), (2) Anomaly detection for IoT sensor data (telco/industrial), (3) LLM fine-tuning with PEFT/LoRA (FlowerTune pattern -- high market interest), (4) Fraud detection tabular model (finance) |
| **Notes** | Flower already has extensive examples (FlowerTune LLM, MNIST, CIFAR, etc.) that can be packaged. The key is making them deployable via contextualization parameters rather than requiring code changes |

### D-7: Automatic Client Scaling

| Aspect | Detail |
|---------|--------|
| **What** | OneFlow elasticity rules that automatically scale SuperNode count based on training demand or schedule |
| **Value Proposition** | Cloud-native auto-scaling is a natural fit for OpenNebula. Traditional FL deployments are static -- this adds cloud elasticity |
| **Complexity** | High |
| **Deployment Scenarios** | Single-site, multi-site |
| **Dependencies** | TS-8 (OneFlow service template), OneFlow elasticity features |
| **Notes** | Flower supports dynamic client participation (min_available_nodes, fraction_train parameters control how many clients participate per round). New SuperNodes joining mid-training is supported. Auto-scaling policies could be: time-based (scale up during off-peak hours), metric-based (scale up if round duration exceeds threshold), or manual trigger |

### D-8: Model Checkpoint and Recovery

| Aspect | Detail |
|---------|--------|
| **What** | Automatic model checkpointing to persistent storage with ability to resume training from checkpoint after failure |
| **Value Proposition** | FL training runs take hours to days. Losing progress due to a server restart is unacceptable for production use. Every serious FL platform supports this |
| **Complexity** | Medium |
| **Deployment Scenarios** | All |
| **Dependencies** | Persistent storage (OpenNebula persistent disks or NFS), Flower strategy checkpoint callbacks |
| **Notes** | Flower supports saving/loading model state through strategy callbacks. The appliance should configure automatic checkpointing to a persistent volume every N rounds (configurable). Recovery means restarting SuperLink with the last checkpoint and having it continue from that round |

---

## Anti-Features

Features to deliberately NOT build. These are common mistakes, scope traps, or things that belong elsewhere in the stack.

### AF-1: Custom ML Training Framework

| Anti-Feature | Build a custom training loop, model definition language, or abstraction layer on top of Flower |
|-------------|---|
| **Why Avoid** | Flower already supports every major ML framework. Adding an abstraction layer creates maintenance burden, limits flexibility, and delays updates when Flower releases new versions. It also alienates ML engineers who want to use their familiar tools |
| **What to Do Instead** | Let users bring their own ServerApp/ClientApp code (Python). Provide templates (D-6) but never force a custom abstraction |

### AF-2: Data Management / Data Pipeline System

| Anti-Feature | Build tools for data ingestion, transformation, cleaning, labeling, or federated dataset management |
|-------------|---|
| **Why Avoid** | Data management is a massive domain unto itself. FL clients train on local data -- the entire point is that data stays local. Building data tooling creates scope creep, adds complexity, and competes with established tools (DVC, Airflow, Feast, etc.) |
| **What to Do Instead** | Document how to mount local datasets into the SuperNode appliance via OpenNebula disk attachments or NFS mounts. Let users manage their own data pipelines |

### AF-3: Custom Aggregation Server Implementation

| Anti-Feature | Reimplement the SuperLink or aggregation logic outside of Flower |
|-------------|---|
| **Why Avoid** | Flower's SuperLink is battle-tested with secure aggregation, differential privacy, and byzantine-robust strategies. Reimplementing means taking ownership of security-critical code that Flower maintains upstream |
| **What to Do Instead** | Use Flower's SuperLink directly. Extend via Flower's Strategy API if custom aggregation is needed (this is Flower's intended extension point) |

### AF-4: Web-Based IDE / Notebook Environment

| Anti-Feature | Bundle Jupyter notebooks, VS Code server, or a custom IDE into the appliance for model development |
|-------------|---|
| **Why Avoid** | Development environments belong on developer workstations, not in production FL infrastructure. Including them increases attack surface, image size, and maintenance burden. Users who want notebooks can deploy them separately |
| **What to Do Instead** | Provide clear documentation on how to develop Flower apps locally and deploy them to the appliance. Support `flwr run` from external machines connecting to the SuperLink Control API (9093) |

### AF-5: Multi-Tenant FL Orchestration

| Anti-Feature | Build a platform layer that manages multiple independent FL training jobs across different tenants on shared infrastructure |
|-------------|---|
| **Why Avoid** | This is essentially building an FL-as-a-Service platform (like Rhino FCP or FEDn Studio). It is an enormous scope that requires job scheduling, resource quotas, billing, isolation, and a management UI. OpenNebula already provides multi-tenancy at the VM level |
| **What to Do Instead** | Each tenant deploys their own appliance instances. OpenNebula's existing multi-tenancy (users, groups, ACLs, resource quotas) handles isolation. Flower's multi-run capability can be noted in docs but not built as a managed feature |

### AF-6: Blockchain-Based Audit / Incentive Layer

| Anti-Feature | Add blockchain or distributed ledger for training contribution tracking, incentive mechanisms, or audit trails |
|-------------|---|
| **Why Avoid** | Adds enormous complexity for marginal value. Real audit needs are served by structured logging + immutable storage (S3 with versioning, for example). Blockchain-based FL incentives (like FLock.io) are a separate product category |
| **What to Do Instead** | Implement structured, append-only logging with round-by-round metrics and client participation records. Export to external audit systems if needed |

### AF-7: Homomorphic Encryption

| Anti-Feature | Implement or integrate fully homomorphic encryption for model updates |
|-------------|---|
| **Why Avoid** | FHE is orders of magnitude slower than plaintext computation, making it impractical for real training workloads. Flower's secure aggregation (SecAgg/SecAgg+) provides meaningful privacy protection with acceptable overhead. FHE is a research topic, not a production feature for this integration |
| **What to Do Instead** | Use Flower's built-in SecAgg for update privacy and differential privacy for formal privacy guarantees. Document the privacy model honestly |

### AF-8: Cross-Framework Model Conversion

| Anti-Feature | Build automatic conversion between PyTorch, TensorFlow, ONNX, etc. so different clients can use different frameworks in the same federation |
|-------------|---|
| **Why Avoid** | Federated learning aggregates model *parameters*, not models. All clients in a federation must use the same model architecture. Cross-framework conversion is a research problem (and usually lossy). This is fundamentally incompatible with how FL works |
| **What to Do Instead** | Document clearly that all clients in a federation must use the same ML framework and model architecture. Offer separate appliance variants per framework (TS-5) |

---

## Feature Dependencies

```
TS-3 (Contextualization) ──────────────────┐
    |                                       |
    v                                       v
TS-1 (Server Appliance) ──> TS-8 (OneFlow) ──> D-7 (Auto-Scaling)
    |                           |
    v                           v
TS-2 (Client Appliance) ──> D-1 (Multi-Site)
    |                       D-2 (Edge Client)
    v
TS-4 (TLS) ────────────────> D-1 (Multi-Site, mandatory)
    |
TS-5 (ML Frameworks) ──────> D-6 (Use Case Templates)
    |
TS-6 (Aggregation) ────────> D-4 (DP + SecAgg)
    |
TS-7 (Basic Monitoring) ───> D-3 (Dashboard)
    |
D-5 (GPU Passthrough) ─────> D-6 (Use Case Templates, for DL templates)
    |
D-8 (Checkpointing) ───────> (standalone, no hard dependencies)
```

### Critical Path

The minimum viable feature set follows this dependency chain:

```
TS-3 (Contextualization) -> TS-1 (Server) -> TS-2 (Client) -> TS-4 (TLS) -> TS-6 (Aggregation) -> TS-7 (Monitoring) -> TS-8 (OneFlow)
```

Everything else builds on this foundation.

---

## MVP Recommendation

### Phase 1: Core Appliances (Minimum Viable)

Must ship to have anything useful:

1. **TS-1** Server appliance (SuperLink with contextualization)
2. **TS-2** Client appliance (SuperNode with contextualization)
3. **TS-3** Contextualization parameters for both
4. **TS-4** TLS encryption support
5. **TS-5** At least PyTorch variant of client appliance
6. **TS-6** Aggregation strategy selection (FedAvg, FedProx, FedAdam minimum)
7. **TS-7** Basic structured logging

### Phase 2: Orchestration and Usability

Makes it cloud-native:

1. **TS-8** OneFlow service template (server + N clients as a service)
2. **D-8** Model checkpointing
3. **D-5** GPU passthrough for client appliances
4. **D-6** 1-2 pre-built use case templates (image classification, anomaly detection)

### Phase 3: Advanced / Competitive

Makes it best-in-class:

1. **D-1** Multi-site federation
2. **D-2** Edge-optimized client
3. **D-3** Monitoring dashboard
4. **D-4** Differential privacy and secure aggregation
5. **D-6** Additional use case templates (LLM fine-tuning, fraud detection)
6. **D-7** Auto-scaling

### Defer Indefinitely

- AF-1 through AF-8: All anti-features. Resist scope creep.

---

## Competitive Landscape Context

How this feature set compares to what exists:

| Feature | Our Appliance | FEDn/Scaleout | NVIDIA FLARE | Flower (raw) | FATE |
|---------|--------------|---------------|--------------|--------------|------|
| One-click deploy | Goal (marketplace) | Studio (SaaS) | Manual | Manual | Manual |
| Cloud-native orchestration | OneFlow | Kubernetes | Kubernetes | Docker/K8s | KubeFATE |
| Multi-site | Zone-aware | Yes | Yes | Manual config | Yes |
| Edge-optimized | Planned | Limited | Limited | Manual | No |
| DP / SecAgg | Via Flower | Limited | Yes | Yes | HE focus |
| Monitoring dashboard | Planned | Studio | FLARE dashboard | None built-in | FATE Board |
| Pre-built templates | Planned | Some | Extensive | Examples only | Built-in algos |
| GPU management | Via OpenNebula | Manual | NVIDIA-native | Manual | Manual |
| Marketplace distribution | OpenNebula native | No | No | No | No |

**Our unique angle:** Native cloud marketplace distribution with infrastructure orchestration. No other FL offering provides deploy-from-marketplace-with-contextualization simplicity on an open-source cloud platform. The closest parallel is managed SaaS (FEDn Studio), but we offer self-hosted, tenant-controlled deployment.

---

## Sources

### HIGH Confidence (Official Documentation)
- [Flower Architecture](https://flower.ai/docs/framework/explanation-flower-architecture.html) - SuperLink/SuperNode/SuperExec component model
- [Flower Strategies](https://flower.ai/docs/framework/how-to-use-strategies.html) - Built-in aggregation strategies and parameters
- [Flower TLS Configuration](https://flower.ai/docs/framework/how-to-enable-tls-connections.html) - Certificate setup for production
- [Flower Docker Deployment](https://flower.ai/docs/framework/docker/tutorial-quickstart-docker.html) - Container images, ports, networking
- [Flower Differential Privacy](https://flower.ai/docs/framework/explanation-differential-privacy.html) - DP implementation details
- [Flower Helm Charts](https://flower.ai/docs/framework/helm/index.html) - Kubernetes/Helm deployment
- [Flower Deployment Engine](https://flower.ai/docs/framework/how-to-run-flower-with-deployment-engine.html) - Production deployment guide
- [OpenNebula Marketplace](https://docs.opennebula.io/7.0/product/apps-marketplace/managing_marketplaces/marketapps/) - Appliance types and management
- [OpenNebula OneFlow](https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/) - Multi-VM service orchestration

### MEDIUM Confidence (Verified Multiple Sources)
- [Flower + NVIDIA FLARE Integration](https://developer.nvidia.com/blog/supercharging-the-federated-learning-ecosystem-by-integrating-flower-and-nvidia-flare/) - Framework interoperability
- [Flower + Red Hat Collaboration](https://flower.ai/blog/2025-11-17-red-hat-flower-collaboration/) - Enterprise deployment patterns
- [Rhino + Flower Partnership](https://www.rhinofcp.com/news/rhino-flower-partnership) - Enterprise FL feature expectations
- [FEDn Platform](https://www.scaleoutsystems.com/framework) - Competing platform features
- [FL Infrastructure Guide](https://introl.com/blog/federated-learning-infrastructure-privacy-preserving-enterprise-ai-guide-2025) - Enterprise requirements

### LOW Confidence (Single Source / Extrapolated)
- Auto-scaling feature viability via OneFlow elasticity (extrapolated from OpenNebula docs, not tested with FL workloads)
- Edge appliance resource requirements (estimated from general edge computing literature, not measured)
- Image size estimates for ML framework variants (estimated from Docker Hub image sizes, will vary with CUDA inclusion)
