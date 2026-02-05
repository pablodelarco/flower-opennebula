# Technology Stack

**Project:** Flower-OpenNebula Integration Specification
**Researched:** 2026-02-05
**Overall Confidence:** MEDIUM -- Strong for Flower and OpenNebula individually; the integration layer is novel and requires validation.

---

## Recommended Stack

### Flower Framework (Federated Learning)

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| Flower (flwr) | 1.25.0 | Core FL framework | Latest stable release (Dec 2025). Framework-agnostic, supports PyTorch/TensorFlow/HuggingFace. Apache 2.0 open source. Hub-and-spoke architecture matches OpenNebula's centralized orchestration model. | HIGH |
| Python | >=3.10, <4.0 | Runtime for Flower | Flower 1.24.0 dropped Python 3.9. Current images default to Python 3.13 on Ubuntu 24.04. | HIGH |
| flwr/superlink | 1.25.0 | FL coordinator | Long-running central server. Forwards tasks to SuperNodes, receives results. Exposes Fleet API (:9092), ServerAppIO API (:9091), Control API (:9093). | HIGH |
| flwr/supernode | 1.25.0 | FL client node | Long-running client process. Connects to SuperLink's Fleet API. Exposes ClientAppIO API (:9094+). Supports dynamic registration via CLI since v1.23.0. | HIGH |
| flwr/superexec | 1.25.0 | Process executor | Schedules, launches, manages ServerApp/ClientApp processes. Introduced in v1.21.0. Required for subprocess isolation mode. | HIGH |

### Flower Docker Images (Primary Packaging)

| Image | Tag Pattern | Base OS | Architectures | Notes |
|-------|-------------|---------|---------------|-------|
| flwr/superlink | 1.25.0-py3.13-ubuntu24.04 | Ubuntu 24.04 | amd64, arm64v8 | Latest tag points here. Also available with py3.12, py3.11, py3.10 and Alpine variants. |
| flwr/supernode | 1.25.0-py3.13-ubuntu24.04 | Ubuntu 24.04 | amd64, arm64v8 | Same tag pattern as superlink. |
| flwr/superexec | 1.25.0 | Ubuntu 24.04 | amd64, arm64v8 | Required for process management. |

**Tag convention:** `{version}-py{python_version}-{os}` (e.g., `1.25.0-py3.13-ubuntu24.04`). Plain `1.25.0` defaults to the latest Python/OS combo.

**Confidence:** HIGH -- Verified via Docker Hub and official Flower documentation.

### OpenNebula Platform

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| OpenNebula | 7.0+ | Cloud management | Current production version. Native OneFlow, contextualization, GPU passthrough, marketplace. Supports SERVICE_TEMPLATE appliance type (since 6.0). | HIGH |
| OneFlow | (bundled) | Multi-VM orchestration | Deploys Flower server + N clients as a single service with dependency ordering ("straight" deployment). Supports scaling policies and cardinality. | HIGH |
| Contextualization | (bundled) | VM configuration | Passes CONTEXT variables (server address, FL config) into VMs at boot via ISO. Supports START_SCRIPT for custom setup, USER_INPUTS for dynamic parameters. | HIGH |
| one-apps | latest | Appliance build toolchain | Packer-based toolchain for QCOW2 image generation. Includes contextualization packages, service lifecycle (install/configure/bootstrap). Standard tooling for all official appliances. | HIGH |
| Marketplace | (bundled) | Appliance distribution | YAML metadata format. Supports IMAGE, VMTEMPLATE, and SERVICE_TEMPLATE types. Service templates reference roles pointing to other marketplace images. | HIGH |

### ML Frameworks (Client-Side, User's Choice)

| Technology | Purpose | Why | Confidence |
|------------|---------|-----|------------|
| PyTorch (>=2.0) | Default ML framework for PoC | Most common Flower example target. Best GPU support. Recommended for PoC demo. | HIGH |
| TensorFlow (>=2.18) | Alternative ML framework | Supported but note: Flower 1.24.0 upgraded to protobuf 5.x which requires TF>=2.18. | MEDIUM |
| scikit-learn | Lightweight ML for tabular data | Good for initial testing without GPU requirements. Migrated to Message API in v1.25.0. | HIGH |

### Security and Networking

| Technology | Version | Purpose | Why | Confidence |
|------------|---------|---------|-----|------------|
| gRPC + TLS | (bundled in Flower) | Component communication | All Flower inter-component communication uses gRPC. TLS configurable via --ssl-ca-certfile, --ssl-certfile, --ssl-keyfile flags. | HIGH |
| Let's Encrypt / cert-manager | latest | TLS certificate management | Flower docs explicitly recommend Let's Encrypt for production. Self-signed certs for dev only. | HIGH |
| OIDC (optional) | -- | User authentication | Flower supports OpenID Connect for Control API authentication. Enterprise feature. | MEDIUM |

### GPU Acceleration

| Technology | Purpose | Why | Confidence |
|------------|---------|-----|------------|
| NVIDIA GPU (passthrough) | Accelerated training on client nodes | OpenNebula 7.0 has dedicated NVIDIA GPU passthrough docs. Uses PCI SHORT_ADDRESS in VM template, VFIO driver binding, IOMMU, q35 machine type, UEFI firmware. | HIGH |
| CUDA/cuDNN (in Docker) | GPU compute libraries | Flower Docker images are Ubuntu 24.04 based. Custom images can extend with nvidia/cuda base for GPU workloads. | MEDIUM |
| CPU pinning + NUMA | Performance optimization | OpenNebula auto-places VMs on NUMA nodes proximate to assigned GPU when PIN_POLICY is set. Critical for FL training performance. | HIGH |

### EU-Sovereign Stack Alignment

| Requirement | Technology | Status | Notes |
|-------------|-----------|--------|-------|
| Cloud Platform | OpenNebula | Aligned | EU-headquartered (Spain), open source |
| Guest OS | openSUSE | Compatible | Flower Docker images are Ubuntu-based but run inside VMs. VM base OS can be openSUSE; Docker engine runs on any Linux. One-apps supports opensuse15. |
| Database | MariaDB | N/A for FL | Not directly needed for Flower FL workflow. Relevant for metadata/monitoring if needed. |
| GPUs | NVIDIA | Aligned | GPU passthrough configured at OpenNebula level, framework-agnostic. |
| FL Framework | Flower | Aligned | Berlin-based company (Flower Labs GmbH). Apache 2.0 licensed. |

---

## Deployment Format Analysis: Docker vs VM (QCOW2) vs Helm

This is the critical open design decision. The analysis below evaluates each option for the Flower-OpenNebula integration.

### Option A: VM Images (QCOW2) via one-apps

**How it works:** Build separate QCOW2 images for Flower server and client using one-apps/Packer. Bake in Docker, Flower, and contextualization scripts. Distribute as IMAGE appliances on marketplace. Orchestrate with OneFlow SERVICE_TEMPLATE.

| Criterion | Assessment |
|-----------|-----------|
| OpenNebula nativeness | Excellent -- native VM images, full contextualization, OneFlow orchestration, GPU passthrough |
| Multi-tenancy isolation | Excellent -- VM-level isolation, separate kernels, network namespaces |
| GPU passthrough | Excellent -- PCI passthrough to VM is OpenNebula's standard GPU pattern |
| Marketplace fit | Excellent -- standard QCOW2 IMAGE type, proven pattern (OneKE, VRouter, etc.) |
| Build complexity | Medium -- requires Packer, one-apps toolchain, appliance.sh lifecycle scripts |
| Image size | Large -- full OS + Docker + Flower deps = 2-5 GB per image |
| Update velocity | Slow -- rebuilding QCOW2 for each Flower version update |
| Edge deployment | Good -- VMs work on edge nodes with KVM |
| Flexibility | Medium -- users are locked to baked-in Flower version unless Docker-in-VM pattern is used |

**Verdict:** Best for production multi-tenant deployments. Highest isolation. Standard OpenNebula pattern.

### Option B: Docker-in-VM (Hybrid) -- RECOMMENDED

**How it works:** Build a "Flower Runner" QCOW2 base image with Docker pre-installed and contextualization scripts that pull and run the appropriate Flower Docker container at boot. The VM image is generic; the Flower version and role (server/client) are determined by contextualization variables.

| Criterion | Assessment |
|-----------|-----------|
| OpenNebula nativeness | Excellent -- still a QCOW2 VM with full contextualization |
| Multi-tenancy isolation | Excellent -- VM-level isolation |
| GPU passthrough | Excellent -- NVIDIA Container Toolkit in VM enables Docker GPU access |
| Marketplace fit | Good -- single IMAGE appliance + SERVICE_TEMPLATE, fewer images to maintain |
| Build complexity | Low-Medium -- one base image, complexity moves to contextualization scripts |
| Image size | Medium -- base OS + Docker = ~1.5-2 GB. Flower images pulled at boot. |
| Update velocity | Fast -- new Flower versions just require changing the tag in contextualization vars |
| Edge deployment | Good -- works on edge nodes with KVM |
| Flexibility | Excellent -- users choose Flower version, Python version, ML framework via context vars |

**Verdict:** Best balance of OpenNebula integration, flexibility, and maintainability. Recommended approach.

### Option C: Helm Charts on OneKE

**How it works:** Deploy a OneKE Kubernetes cluster from marketplace, then deploy Flower Helm charts (SuperLink, SuperNode) onto it.

| Criterion | Assessment |
|-----------|-----------|
| OpenNebula nativeness | Indirect -- requires OneKE as intermediary layer |
| Multi-tenancy isolation | Good -- Kubernetes namespace isolation, but weaker than VM isolation |
| GPU passthrough | Complex -- GPU passthrough to VM, then device plugin to pod. Double abstraction. |
| Marketplace fit | Poor for FL -- requires OneKE appliance first, then Helm charts separately. Not a single-click deploy. |
| Build complexity | Low -- Flower provides Helm charts. But requires Kubernetes expertise from users. |
| Image size | N/A -- containers pulled by K8s |
| Update velocity | Fast -- Helm upgrade |
| Edge deployment | Poor -- Kubernetes overhead too heavy for edge nodes |
| Flexibility | Excellent -- full Kubernetes ecosystem |

**Verdict:** Only appropriate when users already have Kubernetes. Wrong default for OpenNebula's VM-native audience. Too much operational overhead.

### Option D: Raw Docker Compose (No VM)

**How it works:** Users SSH into hosts and run Docker Compose with Flower containers directly.

| Criterion | Assessment |
|-----------|-----------|
| OpenNebula nativeness | None -- bypasses OpenNebula entirely |
| Multi-tenancy isolation | Poor -- container-level only |
| GPU passthrough | N/A -- host-direct |
| Marketplace fit | None -- cannot be distributed as marketplace appliance |
| Edge deployment | Good -- lightweight |
| Flexibility | High -- but not cloud-managed |

**Verdict:** Development/testing only. Not viable for marketplace distribution.

### RECOMMENDATION: Docker-in-VM (Option B) as Primary, with Helm as Secondary

**Primary approach (Option B):** A single "Flower Runner" QCOW2 base image that:
1. Pre-installs Docker Engine and NVIDIA Container Toolkit
2. Includes contextualization scripts that configure and start Flower containers
3. Accepts context variables: FLOWER_ROLE (server/client), FLOWER_VERSION, FLOWER_SERVER_ADDRESS, FL_CONFIG_*, TLS certs
4. Is orchestrated via OneFlow SERVICE_TEMPLATE (server role deploys first, client roles deploy after)

**Secondary approach (Option C):** Document Helm deployment for users who already have OneKE clusters. Flower provides Helm charts; we provide values files and documentation.

**Rationale:**
- Docker-in-VM gives VM-level isolation (critical for multi-tenant Fact8ra) while leveraging Flower's official Docker images
- No custom Flower fork needed -- we pull upstream images
- Version flexibility -- change Flower version without rebuilding the base image
- GPU passthrough works via OpenNebula PCI passthrough to VM + NVIDIA Container Toolkit in VM
- Matches the OpenNebula marketplace appliance wizard pattern already familiar to the team
- OneFlow handles deployment orchestration (server before clients) natively
- Contextualization maps cleanly to Flower's configuration model

---

## Flower Component Architecture (Reference for Spec)

```
                      +------------------+
                      |   flwr CLI       |
                      |  (Control API)   |
                      +--------+---------+
                               |
                               | :9093
                               v
                      +------------------+
                      |   SuperLink      |
                      | (Central Server) |
                      +--+----+----+-----+
                         |    |    |
            :9091        |    |    |       :9092
     +-------+-----------+    |    +----------+--------+
     |                        |                        |
     v                        |                        v
+----+-------+                |               +--------+------+
| SuperExec  |                |               |  SuperNode 1  |
| (ServerApp)|                |               |  (Client)     |
+------------+                |               +-------+-------+
                              |                       |
                              |              :9094    |
                              |               +-------+-------+
                              |               | SuperExec     |
                              |               | (ClientApp)   |
                              |               +---------------+
                              |
                              |       :9092
                              +----------+--------+
                                                   |
                                          +--------+------+
                                          |  SuperNode 2  |
                                          |  (Client)     |
                                          +-------+-------+
                                                  |
                                         :9095    |
                                          +-------+-------+
                                          | SuperExec     |
                                          | (ClientApp)   |
                                          +---------------+
```

**Long-running components:** SuperLink, SuperNode, SuperExec (infrastructure)
**Short-lived components:** ServerApp, ClientApp (user code, launched by SuperExec)

**Communication protocol:** gRPC on all APIs. TLS recommended for production.

**Key ports:**
- 9091: ServerAppIO API (SuperLink <-> SuperExec/ServerApp)
- 9092: Fleet API (SuperLink <-> SuperNodes)
- 9093: Control API (flwr CLI <-> SuperLink)
- 9094+: ClientAppIO API (SuperNode <-> SuperExec/ClientApp)

---

## OpenNebula Appliance Packaging Reference

### Marketplace Metadata Format (YAML)

```yaml
---
name: 'Flower FL Server'
version: '1.0.0'
publisher: 'OpenNebula Systems'
description: |
  Flower Federated Learning Server appliance for OpenNebula.
  Deploys a Flower SuperLink with Docker-in-VM pattern.
short_description: 'Flower FL Server - federated learning coordinator'
tags:
  - federated-learning
  - flower
  - ai
  - machine-learning
format: qcow2
creation_time: 1738713600    # epoch timestamp
os-id: openSUSE              # or Ubuntu
os-release: '15.6'           # or '24.04'
os-arch: x86_64
hypervisor: KVM
opennebula_version: '7.0'
opennebula_template: |
  CONTEXT=[
    NETWORK="YES",
    SSH_PUBLIC_KEY="$USER[SSH_PUBLIC_KEY]",
    FLOWER_ROLE="server",
    FLOWER_VERSION="1.25.0",
    START_SCRIPT_BASE64="<base64-encoded-startup-script>"
  ]
  CPU="2"
  VCPU="4"
  MEMORY="4096"
  USER_INPUTS=[
    FLOWER_VERSION="O|text|Flower version tag|1.25.0",
    FL_NUM_ROUNDS="O|number|Number of FL training rounds|3",
    FL_STRATEGY="O|list|Aggregation strategy|FedAvg,FedProx,FedAdam|FedAvg",
    TLS_ENABLED="O|boolean|Enable TLS|true"
  ]
images:
  - name: 'Flower Runner Base'
    url: 'https://marketplace.opennebula.io/...'
    type: OS
    dev_prefix: vd
    driver: qcow2
    size: 2147483648
    checksum:
      md5: '<hash>'
      sha256: '<hash>'
```

### OneFlow SERVICE_TEMPLATE Structure

```json
{
  "name": "Flower Federated Learning",
  "deployment": "straight",
  "description": "Flower FL cluster with server and configurable client count",
  "roles": [
    {
      "name": "flower-server",
      "cardinality": 1,
      "type": "vm",
      "template_id": "<server_template_id>",
      "template_contents": {
        "CONTEXT": {
          "FLOWER_ROLE": "server",
          "FLOWER_VERSION": "$FLOWER_VERSION"
        }
      }
    },
    {
      "name": "flower-client",
      "cardinality": 2,
      "type": "vm",
      "template_id": "<client_template_id>",
      "parents": ["flower-server"],
      "min_vms": 1,
      "max_vms": 50,
      "template_contents": {
        "CONTEXT": {
          "FLOWER_ROLE": "client",
          "FLOWER_SERVER_ADDRESS": "<dynamic-from-server-role>",
          "FLOWER_VERSION": "$FLOWER_VERSION"
        }
      },
      "elasticity_policies": [],
      "scheduled_policies": []
    }
  ],
  "networks_values": [],
  "on_hold": false
}
```

**Deployment strategy "straight"** ensures the server role reaches RUNNING before client roles deploy -- matching Flower's requirement that SuperLink must be available before SuperNodes connect.

### Contextualization Variables for Flower

| Variable | Applies To | Required | Type | Description |
|----------|-----------|----------|------|-------------|
| FLOWER_ROLE | Both | Yes | list: server,client | Determines which Flower component to start |
| FLOWER_VERSION | Both | No | text (default: 1.25.0) | Docker image tag for Flower containers |
| FLOWER_SERVER_ADDRESS | Client | Yes | text | SuperLink Fleet API address (host:9092) |
| FL_NUM_ROUNDS | Server | No | number (default: 3) | Training rounds for the FL job |
| FL_STRATEGY | Server | No | list (default: FedAvg) | Aggregation strategy |
| FL_MIN_CLIENTS | Server | No | number (default: 2) | Minimum clients before starting a round |
| TLS_ENABLED | Both | No | boolean (default: true) | Enable TLS for gRPC communication |
| TLS_CA_CERT | Both | Cond. | text (base64) | CA certificate for TLS |
| TLS_CERT | Server | Cond. | text (base64) | Server certificate |
| TLS_KEY | Server | Cond. | text (base64) | Server private key |
| GPU_ENABLED | Client | No | boolean (default: false) | Enable NVIDIA GPU support in container |
| ML_FRAMEWORK | Client | No | list: pytorch,tensorflow,sklearn | ML framework to install |
| CUSTOM_APP_REPO | Both | No | text | Git repo URL with custom ServerApp/ClientApp |

### one-apps Appliance Lifecycle

The one-apps toolchain provides a standard lifecycle for appliance scripts:

```
service.sh install   -> Downloads packages, sets up Docker, installs deps
service.sh configure -> Reads CONTEXT variables, generates config files
service.sh bootstrap -> Starts containers, runs health checks
```

Source chain: `service.sh` -> `common.sh` -> `functions.sh` -> `appliance.sh`

Logging to: `/var/log/one-appliance/`

---

## Alternatives Considered

| Category | Recommended | Alternative | Why Not Alternative |
|----------|-------------|-------------|---------------------|
| FL Framework | Flower | NVIDIA FLARE | FLARE is more complex, less portable, and Flower Labs is the consulting partner. Note: Flower+FLARE integration exists (v1.21+) but adds unnecessary complexity. |
| FL Framework | Flower | PySyft (OpenMined) | PySyft focuses on differential privacy, not production FL deployment. Smaller ecosystem. |
| FL Framework | Flower | TensorFlow Federated | TF-only. Flower is framework-agnostic. |
| Packaging | Docker-in-VM | Pure QCOW2 (baked) | Loses Flower version flexibility. Requires image rebuild for every update. |
| Packaging | Docker-in-VM | Helm on OneKE | Too much K8s overhead. Wrong fit for VM-native OpenNebula users. |
| Packaging | Docker-in-VM | Docker Compose (no VM) | Cannot distribute via marketplace. No multi-tenant isolation. |
| Base OS (VM) | openSUSE 15 or Ubuntu 24.04 | Alpine | Alpine lacks GPU toolchain maturity. Not supported by one-apps for full VM images. |
| Base OS (VM) | openSUSE 15 | Ubuntu 24.04 | openSUSE preferred for EU-sovereignty alignment. Both supported by one-apps. Ubuntu is fallback if openSUSE causes Docker/NVIDIA issues. |
| Flower Licensing | Open Source (Apache 2.0) | Flower Enterprise | Enterprise adds OIDC, RBAC, audit logs, managed TLS. Evaluate if needed post-PoC. Open source sufficient for spec and demo. |

---

## Flower Enterprise vs Open Source -- What You Need to Know

**Open Source (Apache 2.0) -- Use for PoC and Spec:**
- SuperLink, SuperNode, SuperExec -- all components
- All FL strategies (FedAvg, FedProx, FedAdam, etc.)
- Docker images on Docker Hub
- TLS support (manual cert management)
- gRPC communication
- Dynamic SuperNode management (v1.23.0+)
- Docker Compose deployment

**Enterprise (License Required) -- Evaluate Post-PoC:**
- Helm charts for Kubernetes deployment (appears to require license as of v1.20.0+)
- OpenID Connect (OIDC) authentication
- Role-Based Access Control (RBAC)
- Structured audit logging
- ISO 27001 certified infrastructure
- Managed TLS with cert-manager integration
- Professional support

**Confidence:** LOW-MEDIUM -- The boundary between open-source and enterprise features is not clearly documented publicly. The Helm charts documentation mentions "license key" requirement. This needs direct clarification with Flower Labs during the consulting engagement.

**Recommendation for the spec:** Design for open-source Flower. The Docker-in-VM approach does not require Helm charts. TLS can be manually configured. If the Fact8ra production deployment later needs OIDC/RBAC/audit, evaluate Enterprise licensing at that point. The EUR 15K consulting budget should include a licensing discussion.

---

## What NOT to Use

| Avoid | Why |
|-------|-----|
| Flower versions < 1.20.0 | Pre-SuperExec architecture. Missing critical deployment features. |
| Python 3.9 | Dropped in Flower 1.24.0. |
| Alpine-based Docker images for GPU workloads | NVIDIA CUDA toolchain has poor Alpine support. Use Ubuntu-based tags. |
| Custom Flower fork | Violates project constraint. Upstream images only. |
| --insecure flag in production | Disables TLS. Development only. |
| CSV-based SuperNode authentication | Removed in v1.23.0. Use dynamic management system. |
| protobuf < 5.x with Flower >= 1.24.0 | Breaking change. Incompatible. |
| TensorFlow < 2.18 with Flower >= 1.24.0 | protobuf 5.x incompatibility. |

---

## Version Pinning Strategy

For the PoC and spec, pin to these versions:

```
# Flower components
FLOWER_VERSION=1.25.0
FLOWER_PYTHON=3.13

# Docker image tags (specific)
SUPERLINK_IMAGE=flwr/superlink:1.25.0-py3.13-ubuntu24.04
SUPERNODE_IMAGE=flwr/supernode:1.25.0-py3.13-ubuntu24.04
SUPEREXEC_IMAGE=flwr/superexec:1.25.0

# OpenNebula
OPENNEBULA_VERSION=7.0+
ONE_APPS_BRANCH=master

# ML Framework (PoC default)
PYTORCH_VERSION=2.5
```

**Rationale:** Pin to specific tags, not `latest`. Flower releases roughly monthly (7 releases in 6 months in 2025). Pinning ensures reproducibility. The FLOWER_VERSION contextualization variable allows users to override.

---

## Sources

### HIGH Confidence (Official Documentation)
- Flower Framework Docker Documentation: https://flower.ai/docs/framework/docker/index.html
- Flower Architecture Explanation: https://flower.ai/docs/framework/explanation-flower-architecture.html
- Flower Network Communication Reference: https://flower.ai/docs/framework/ref-flower-network-communication.html
- Flower TLS Configuration: https://flower.ai/docs/framework/how-to-enable-tls-connections.html
- Flower pyproject.toml Configuration: https://flower.ai/docs/framework/how-to-configure-pyproject-toml.html
- Flower Changelog: https://flower.ai/docs/framework/ref-changelog.html
- Flower PyPI (v1.25.0, Dec 2025): https://pypi.org/project/flwr/
- OpenNebula 7.0 Marketplace Appliances: https://docs.opennebula.io/7.0/product/apps-marketplace/managing_marketplaces/marketapps/
- OpenNebula 7.0 OneFlow: https://docs.opennebula.io/7.0/product/virtual_machines_operation/multi-vm_workflows/appflow_use_cli/
- OpenNebula 7.0 Contextualization: https://docs.opennebula.io/7.0/product/virtual_machines_operation/guest_operating_systems/kvm_contextualization/
- OpenNebula 7.0 NVIDIA GPU Passthrough: https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/
- OpenNebula Marketplace Metadata Format: https://github.com/OpenNebula/marketplace/blob/master/README.md
- one-apps Toolchain: https://github.com/OpenNebula/one-apps/

### MEDIUM Confidence (Multiple Sources Agree)
- Flower Docker Hub images (flwr org): https://hub.docker.com/u/flwr
- Flower Enterprise features: https://flower.ai/enterprise/
- OpenNebula OneKE: https://docs.opennebula.io/7.0/integrations/marketplace_appliances/oneke/
- OpenNebula VM Templates / User Inputs: https://docs.opennebula.io/6.10/management_and_operations/vm_management/vm_templates.html

### LOW Confidence (Needs Validation)
- Flower Enterprise vs open-source feature boundary (not publicly documented in detail)
- Flower Helm chart licensing requirements (docs mention license key but scope unclear)
- openSUSE + NVIDIA Container Toolkit + Flower Docker compatibility (untested combo)
- OneFlow dynamic server IP propagation to client roles (mechanism needs verification)
