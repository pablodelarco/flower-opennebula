# Building and Deploying Flower-OpenNebula Appliances

> Complete guide to building QCOW2 appliance images and deploying a Flower federated learning cluster on OpenNebula.

This tutorial targets OpenNebula administrators familiar with Packer and VM management.
For a quick-start walkthrough, see [QUICKSTART.md](./QUICKSTART.md).

---

## Table of Contents

| Section | Time Estimate |
|---------|---------------|
| [1. Overview](#1-overview) | -- |
| [2. Prerequisites](#2-prerequisites) | 10 min |
| [3. Building the SuperLink Image](#3-building-the-superlink-image) | ~15 min |
| [4. Building the SuperNode Image](#4-building-the-supernode-image) | ~20 min |
| [5. Uploading to OpenNebula](#5-uploading-to-opennebula) | ~5 min |
| [6. Creating the OneFlow Service Template](#6-creating-the-oneflow-service-template) | 5 min |
| [7. Deploying a Flower Cluster](#7-deploying-a-flower-cluster) | 2-5 min |
| [8. Verifying the Deployment](#8-verifying-the-deployment) | 5 min |
| [9. Verifying FL Communication](#9-verifying-fl-communication) | 5 min |
| [10. Submitting a Training Run](#10-submitting-a-training-run) | varies |
| [11. Customization](#11-customization) | -- |
| [12. Troubleshooting](#12-troubleshooting) | -- |
| [13. Known Issues and Workarounds](#13-known-issues-and-workarounds) | -- |
| [Appendix A: Manual Deployment](#appendix-a-manual-deployment-without-packer) | 30-45 min |

---

## 1. Overview

This build system produces two QCOW2 virtual machine images for the OpenNebula marketplace:

| Image | Role | Description |
|-------|------|-------------|
| **SuperLink** | Coordinator | Orchestrates training rounds, aggregates model updates, persists state |
| **SuperNode** | Client | Trains a local model on private data, sends weight updates to SuperLink |

Both images use a **Docker-in-VM** architecture: a single Flower container runs inside a dedicated Ubuntu 24.04 VM, managed by systemd. The [one-apps](https://github.com/OpenNebula/one-apps) contextualization framework handles boot-time configuration from OpenNebula CONTEXT variables.

> **Tip:** Training data never leaves the SuperNode VM. Only model weights and gradients are transmitted over the network.

### Architecture

```
                        OneFlow Service
    +-----------------------------------------------------------+
    |                                                           |
    |   +-------------------+       +-------------------+      |
    |   |   SuperLink VM    |       |  SuperNode VM #1  |      |
    |   |                   |       |                   |      |
    |   |  flwr/superlink   |<------+  custom supernode |      |
    |   |   :9091 SrvAppIo  | gRPC  |  (python:3.12-   |      |
    |   |   :9092 Fleet API | :9092 |   slim + flwr +   |      |
    |   |   :9093 Ctrl API  |       |   torch)          |      |
    |   +-------------------+       +-------------------+      |
    |          |                                                |
    |          | OneGate PUT        +-------------------+       |
    |          v                    |  SuperNode VM #2  |       |
    |   +--------------+            |                   |       |
    |   |   OneGate    |<-----------+  custom supernode |       |
    |   |   Service    | OneGate GET|                   |       |
    |   +--------------+            +-------------------+       |
    |                                                           |
    +-----------------------------------------------------------+
```

### Data Flow

1. SuperLink boots, starts the Flower container, publishes its endpoint to OneGate (`FL_ENDPOINT=<ip>:9092`).
2. SuperNode boots, discovers the SuperLink via OneGate (or a static address), connects to the Fleet API on port 9092 over gRPC.
3. The SuperLink assigns training rounds. SuperNodes train locally and report model weight updates.
4. Model weights and gradients are the only data transmitted. Training data stays on each SuperNode VM.

### Port Reference

| Port | Protocol | Service | Component | Description |
|------|----------|---------|-----------|-------------|
| 9091 | gRPC | ServerAppIo | SuperLink | Internal API for subprocess-managed ServerApp |
| 9092 | gRPC | Fleet API | SuperLink | SuperNode connections (primary data plane) |
| 9093 | gRPC | Control API | SuperLink | CLI management and run submission |
| 9400 | HTTP | DCGM Metrics | SuperNode | GPU metrics via DCGM exporter (optional) |

### Orchestration Model

OneFlow deploys the SuperLink role first. Once the SuperLink reports `READY=YES` via `REPORT_READY`, OneFlow starts the SuperNode role. Each SuperNode discovers the SuperLink endpoint through OneGate and connects automatically. No manual IP configuration is needed for single-site deployments.

See [`spec/08-single-site-orchestration.md`](../spec/08-single-site-orchestration.md).

---

## 2. Prerequisites

### Hardware

- [ ] x86_64 (amd64) architecture
- [ ] KVM support enabled (`kvm-ok` or `grep -c vmx /proc/cpuinfo`)
- [ ] 30 GB free disk space for build artifacts
- [ ] 4 GB available RAM for the build VM

### Software

| Tool | Version | Purpose |
|------|---------|---------|
| Packer | >= 1.9 | Image build orchestration |
| QEMU/KVM | any recent | VM execution during build |
| mkisofs or genisoimage | any | Contextualization ISO creation |
| jq | any | JSON processing for verification |
| make | any | Build driver |

```bash
# Packer (HashiCorp APT repository)
curl -fsSL https://apt.releases.hashicorp.com/gpg \
  | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install packer

# QEMU/KVM and other tools
sudo apt-get install qemu-system-x86 qemu-utils genisoimage jq make
```

### one-apps Framework

The build depends on the OpenNebula [one-apps](https://github.com/OpenNebula/one-apps) framework for contextualization scripts and the service lifecycle manager.

```bash
cd /path/to/workspace
git clone https://github.com/OpenNebula/one-apps.git
```

### Base Image

You need an Ubuntu 24.04 QCOW2 base image, either exported from one-apps or downloaded from the OpenNebula marketplace.

```bash
# Option A: Build from one-apps
cd one-apps && make ubuntu2404

# Option B: Download a pre-built image from OpenNebula marketplace
# Place it as ubuntu2404.qcow2
```

> **Warning:** The Ubuntu 24.04 marketplace image ships with a 3.5 GB root disk. This is insufficient for Docker images. The Packer templates handle disk sizing automatically, but if you use [Appendix A (manual deployment)](#appendix-a-manual-deployment-without-packer), resize to at least 10 GB before provisioning.

### Expected File Layout

```
workspace/
    one-apps/                              # one-apps framework checkout
        appliances/
            service.sh                     # Service lifecycle manager
            lib/common.sh
            lib/functions.sh
            scripts/
                net-90-service-appliance
                net-99-report-ready
    flower-opennebula/
        build/
            images/
                ubuntu2404.qcow2           # Base image (you provide this)
            Makefile
            superlink/
                appliance.sh               # SuperLink lifecycle script
            supernode/
                appliance.sh               # SuperNode lifecycle script
            packer/
                superlink/                 # SuperLink Packer template
                supernode/                 # SuperNode Packer template
                scripts/                   # Shared Packer provisioners
            oneflow/
                flower-cluster.yaml        # OneFlow service template
```

---

## 3. Building the SuperLink Image

**Time estimate:** ~15 minutes

### Build Command

```bash
cd /path/to/flower-opennebula/build

make flower-superlink \
    INPUT_DIR=./images \
    ONE_APPS_DIR=../../one-apps
```

### What Happens During the Build

Packer launches a temporary QEMU VM from the Ubuntu 24.04 base image and runs these provisioning steps:

| Step | Action | Details |
|------|--------|---------|
| 1 | SSH hardening | Reverts the insecure build-time SSH settings used for Packer access |
| 2 | one-apps install | Copies service lifecycle manager, shared libraries, and contextualization hooks |
| 3 | Appliance script | Places `superlink/appliance.sh` at `/etc/one-appliance/service.d/appliance.sh` |
| 4 | Context hooks | Configures `net-90-service-appliance` and `net-99-report-ready` |
| 5 | `service_install()` | Installs Docker CE, pulls `flwr/superlink:1.25.0`, installs OpenSSL/jq/netcat, creates `/opt/flower/` tree (UID 49999), records `PREBAKED_VERSION` |
| 6 | Cloud cleanup | Truncates `machine-id`, runs `cloud-init clean` for image reuse |

### Build Output

```
build/export/flower-superlink.qcow2
```

| Property | Value |
|----------|-------|
| Virtual disk | 10 GB (QCOW2, sparse) |
| Compressed size | ~2-3 GB |
| Base OS | Ubuntu 24.04 |
| Flower version | 1.25.0 |

### Verify the Build

```bash
ls -lh build/export/flower-superlink.qcow2
qemu-img info build/export/flower-superlink.qcow2
```

You should see a valid QCOW2 image with a 10 GB virtual size.

See [`spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md).

---

## 4. Building the SuperNode Image

**Time estimate:** ~20 minutes (longer due to PyTorch bake-in)

### Build Command

```bash
cd /path/to/flower-opennebula/build

make flower-supernode \
    INPUT_DIR=./images \
    ONE_APPS_DIR=../../one-apps
```

### Differences from SuperLink Build

| Aspect | SuperLink | SuperNode |
|--------|-----------|-----------|
| Disk size | 10 GB | 20 GB |
| Docker image | `flwr/superlink:1.25.0` | Custom image built from `python:3.12-slim` |
| ML frameworks | None | PyTorch + torchvision baked in |
| NVIDIA toolkit | No | Best-effort install (skips if no GPU hardware) |
| Data directory | No | `/opt/flower/data/` (UID 49999) |

> **Note:** The SuperNode image uses a custom Docker image built from `python:3.12-slim` (not the upstream `flwr/supernode:1.25.0` Alpine image). This is because PyTorch manylinux wheels require glibc, and the Alpine-based upstream image uses musl. The custom image installs `flwr==1.25.0`, `torch`, `torchvision`, and `numpy==1.26.4`.

> **Warning:** NumPy 2.x requires the x86_v2 instruction set (SSE4.1). KVM VMs with basic CPU models may lack these instructions. Pin `numpy==1.26.4` to avoid runtime crashes. This is already handled in the build, but be aware if customizing.

### Build Output

```
build/export/flower-supernode.qcow2
```

| Property | Value |
|----------|-------|
| Virtual disk | 20 GB (QCOW2, sparse) |
| Compressed size | ~3-4 GB (includes PyTorch) |
| Base OS | Ubuntu 24.04 |
| Flower version | 1.25.0 |

### Build Both Images

```bash
make all INPUT_DIR=./images ONE_APPS_DIR=../../one-apps
```

### Validate Before Building

```bash
make validate
```

Runs `bash -n` on all shell scripts and `packer validate -syntax-only` on both templates.

See [`spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md).

---

## 5. Uploading to OpenNebula

**Time estimate:** ~5 minutes (depends on network speed)

### Upload the Images

```bash
# Upload SuperLink image
oneimage create \
    --name "Flower SuperLink v1.25.0" \
    --path /var/tmp/flower-superlink.qcow2 \
    --type OS \
    --driver qcow2 \
    --datastore default

# Upload SuperNode image
oneimage create \
    --name "Flower SuperNode v1.25.0" \
    --path /var/tmp/flower-supernode.qcow2 \
    --type OS \
    --driver qcow2 \
    --datastore default
```

> **Warning:** OpenNebula's `RESTRICTED_DIRS` blocks image uploads from `/root`. Copy images to `/var/tmp` before uploading. See [Known Issue 13j](#13j-opennebula-restricted_dirs-blocks-upload-from-root).

Wait for both images to reach the `READY` state:

```bash
oneimage list | grep "Flower"
```

Expected output:

```
  38 oneadmin   Flower SuperLink v1.25.0   ...   rdy
  39 oneadmin   Flower SuperNode v1.25.0   ...   rdy
```

### Create VM Templates

**SuperLink VM Template:**

```bash
onetemplate create <<'EOF'
NAME = "Flower SuperLink"
CPU = 2
VCPU = 2
MEMORY = 4096

DISK = [
    IMAGE = "Flower SuperLink v1.25.0"
]

CONTEXT = [
    TOKEN = "YES",
    NETWORK = "YES",
    REPORT_READY = "YES",
    READY_SCRIPT_PATH = "/opt/flower/scripts/health-check.sh",
    SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
```

**SuperNode VM Template:**

```bash
onetemplate create <<'EOF'
NAME = "Flower SuperNode"
CPU = 2
VCPU = 2
MEMORY = 4096

DISK = [
    IMAGE = "Flower SuperNode v1.25.0"
]

CONTEXT = [
    TOKEN = "YES",
    NETWORK = "YES",
    REPORT_READY = "YES",
    READY_SCRIPT_PATH = "/opt/flower/scripts/health-check.sh",
    SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
```

Record the template IDs from the output. You need them for the OneFlow service template.

### Minimum Resources

| Role | vCPU | RAM | Disk | Notes |
|------|------|-----|------|-------|
| SuperLink | 2 | 4 GB | 10 GB | Aggregation is CPU-bound |
| SuperNode | 2 | 4 GB | 20 GB | Model training + data storage |

> **Tip:** For production workloads, increase SuperLink RAM proportionally to model size and client count. SuperNode resources depend on the ML workload -- LLM fine-tuning may require 16+ GB RAM and GPU passthrough.

See [`spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md) Section 5 and [`spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md) Section 5.

---

## 6. Creating the OneFlow Service Template

### Register the Template

The service template lives at `build/oneflow/flower-cluster.yaml`. Before registering, update the VM template IDs and network ID.

**1. Find your IDs:**

```bash
onetemplate list | grep "Flower"
onevnet list
```

**2. Edit `build/oneflow/flower-cluster.yaml`:**

```yaml
roles:
  - name: 'superlink'
    vm_template: <YOUR_SUPERLINK_TEMPLATE_ID>   # Replace with actual ID
    # ...

  - name: 'supernode'
    vm_template: <YOUR_SUPERNODE_TEMPLATE_ID>    # Replace with actual ID
    # ...
```

The `$Private` network reference in `vm_template_contents` resolves from the `networks` section at the top of the template. Set it to your private network for FL cluster communication.

**3. Register:**

```bash
oneflow-template create build/oneflow/flower-cluster.yaml
```

Record the service template ID from the output.

### Configuration Reference

The service template uses a three-level configuration hierarchy.

**Service-level variables** (apply to all roles):

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_FLOWER_VERSION` | `1.25.0` | Flower version (must match both roles) |
| `ONEAPP_FL_TLS_ENABLED` | `NO` | Enable TLS encryption |
| `ONEAPP_FL_LOG_LEVEL` | `INFO` | Log verbosity |
| `ONEAPP_FL_LOG_FORMAT` | `text` | Log format (`text` or `json`) |

**SuperLink role variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_FL_NUM_ROUNDS` | `3` | Number of training rounds |
| `ONEAPP_FL_STRATEGY` | `FedAvg` | Aggregation strategy |
| `ONEAPP_FL_MIN_FIT_CLIENTS` | `2` | Min clients per training round |
| `ONEAPP_FL_MIN_EVALUATE_CLIENTS` | `2` | Min clients for evaluation |
| `ONEAPP_FL_MIN_AVAILABLE_CLIENTS` | `2` | Min connected clients to start |
| `ONEAPP_FL_CHECKPOINT_ENABLED` | `NO` | Enable model checkpointing |
| `ONEAPP_FL_METRICS_ENABLED` | `NO` | Enable Prometheus metrics |

**SuperNode role variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `ONEAPP_FL_NODE_CONFIG` | (empty) | key=value pairs for ClientApp |
| `ONEAPP_FL_GPU_ENABLED` | `NO` | Enable GPU passthrough |
| `ONEAPP_FL_CUDA_VISIBLE_DEVICES` | `all` | GPU device selection |
| `ONEAPP_FL_DCGM_ENABLED` | `NO` | Enable DCGM GPU metrics |

For the full variable reference (48 variables with validation rules), see [`spec/03-contextualization-reference.md`](../spec/03-contextualization-reference.md).

---

## 7. Deploying a Flower Cluster

### Instantiate the Service

```bash
oneflow-template instantiate <service_template_id>
```

You can also instantiate from the Sunstone web UI, where service-level and role-level variables appear as form fields.

### Deployment Sequence

```
Phase 1: SuperLink Deployment
    OneFlow creates SuperLink VM
        |-- OS boots, contextualization runs
        |-- configure.sh: validate config, generate env file, systemd unit
        |-- bootstrap.sh: wait for Docker, start container
        |-- health-check.sh: wait for port 9092 (TCP)
        |-- Publish FL_ENDPOINT to OneGate
        |-- REPORT_READY -> READY=YES
        |
Phase 2: SuperNode Deployment (starts after SuperLink is READY)
    OneFlow creates SuperNode VMs (default: 2)
        |-- OS boots, contextualization runs
        |-- configure.sh: validate config, discover SuperLink via OneGate
        |-- bootstrap.sh: wait for Docker, detect GPU, start container
        |-- Container connects to SuperLink Fleet API on port 9092
        |-- REPORT_READY -> READY=YES
```

> **Note:** SuperNode discovery uses a retry loop (30 attempts, 10s interval, 5 min timeout). In practice, the SuperLink reports READY within 30-90 seconds.

### Monitor Deployment

```bash
# Watch service status (refreshes every 5 seconds)
watch -n 5 oneflow show <service_id>

# Check individual VM status
onevm list | grep flower
```

**Service states:**

| State | Meaning |
|-------|---------|
| `PENDING` | Service is being created |
| `DEPLOYING` | VMs are being created and booted |
| `RUNNING` | All roles are READY, cluster is operational |
| `FAILED` | One or more VMs failed to reach READY |

### Custom Parameters at Instantiation

```bash
# Example: 5 training rounds, FedProx strategy, 4 SuperNodes
oneflow-template instantiate <template_id> \
    --user_inputs '{
        "ONEAPP_FL_NUM_ROUNDS": "5",
        "ONEAPP_FL_STRATEGY": "FedProx"
    }' \
    --role supernode --cardinality 4
```

---

## 8. Verifying the Deployment

Once the service reaches `RUNNING` state, verify each component.

### SuperLink

```bash
SUPERLINK_IP=$(onevm show <superlink_vm_id> --json | jq -r '.VM.TEMPLATE.NIC[0].IP')

# Check container status
ssh root@${SUPERLINK_IP} 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

# Check logs
ssh root@${SUPERLINK_IP} 'docker logs flower-superlink --tail 20'

# Verify Fleet API is listening
ssh root@${SUPERLINK_IP} 'nc -z localhost 9092 && echo "Fleet API OK" || echo "Fleet API FAILED"'
```

Expected log output:

```
INFO :      Starting Flower server...
INFO :      Flower ECE: gRPC server running ...
```

### SuperNode(s)

```bash
SUPERNODE_IP=$(onevm show <supernode_vm_id> --json | jq -r '.VM.TEMPLATE.NIC[0].IP')

# Check container status
ssh root@${SUPERNODE_IP} 'docker ps --format "table {{.Names}}\t{{.Status}}"'

# Check logs
ssh root@${SUPERNODE_IP} 'docker logs flower-supernode --tail 20'
```

Expected log output:

```
INFO :      Opened insecure gRPC connection
```

### OneGate State

```bash
# SuperLink should have published:
onevm show <superlink_vm_id> | grep FL_
#   FL_READY=YES
#   FL_ENDPOINT=<ip>:9092
#   FL_VERSION=1.25.0
#   FL_ROLE=superlink

# SuperNode should have published:
onevm show <supernode_vm_id> | grep FL_
#   FL_NODE_READY=YES
#   FL_VERSION=1.25.0
```

### External Health Check

```bash
nc -z ${SUPERLINK_IP} 9092 && echo "Fleet API reachable" || echo "Fleet API unreachable"
nc -z ${SUPERLINK_IP} 9093 && echo "Control API reachable" || echo "Control API unreachable"
```

### OneFlow Service Status

```bash
oneflow show <service_id>
# All roles should show state: RUNNING
# superlink: 1/1 VMs running
# supernode: 2/2 VMs running
```

---

## 9. Verifying FL Communication

After confirming containers are running (Section 8), verify that SuperNodes have established active gRPC connections.

### SuperLink: Check for Node Activations

```bash
ssh root@${SUPERLINK_IP} 'docker logs flower-superlink 2>&1 | grep -i activate'
```

Expected output (one line per connected SuperNode):

```
INFO :      ActivateNode: node_id=<id>
INFO :      ActivateNode: node_id=<id>
```

### SuperNode: Check for Connection

```bash
ssh root@${SUPERNODE_IP} 'docker logs flower-supernode 2>&1 | head -20'
```

Expected output:

```
INFO :      Starting Flower SuperNode
INFO :      Opened insecure gRPC connection (no certificates were passed)
INFO :      Waiting for message from SuperLink...
```

> **Note:** If TLS is enabled, this reads `Opened secure gRPC connection` instead.

### Port Connectivity Check

From any VM in the same network:

```bash
nc -z ${SUPERLINK_IP} 9092 && echo "Fleet API: OK" || echo "Fleet API: UNREACHABLE"
nc -z ${SUPERLINK_IP} 9093 && echo "Control API: OK" || echo "Control API: UNREACHABLE"
```

### gRPC Polling Proof

SuperNodes continuously poll the SuperLink for tasks:

```bash
# On the SuperLink -- watch for periodic GetRun requests
ssh root@${SUPERLINK_IP} 'docker logs -f flower-superlink 2>&1' &

# On a SuperNode -- confirm it is polling
ssh root@${SUPERNODE_IP} 'docker logs -f flower-supernode 2>&1' &
```

> **Tip:** Set `ONEAPP_FL_LOG_LEVEL=DEBUG` to see periodic `PullTaskIns` / `GetRun` messages. At `INFO` level, the SuperNode shows "Waiting for message from SuperLink..." and stays connected.

If the SuperNode disconnects and reconnects (visible as repeated "Opened gRPC connection" lines), check network stability and gRPC keepalive settings (`ONEAPP_FL_GRPC_KEEPALIVE_TIME`).

---

## 10. Submitting a Training Run

Once the cluster is running, submit a Flower App Bundle (FAB) containing your ServerApp and ClientApp code.

### Using the Flower CLI

From a machine with the Flower CLI installed (`pip install flwr`):

```bash
flwr run --superlink ${SUPERLINK_IP}:9093
```

This command:

1. Connects to the SuperLink's Control API on port 9093.
2. Uploads the FAB (ServerApp + ClientApp code).
3. The SuperLink distributes the ClientApp to connected SuperNodes.
4. Training rounds execute: SuperNodes train locally, SuperLink aggregates.

> **Tip:** `flwr run` ships code as a FAB bundle -- no need to rebuild Docker images for code changes.

### Monitoring Training Progress

```bash
ssh root@${SUPERLINK_IP} 'docker logs -f flower-superlink'
```

Expected output during training:

```
INFO :      [ROUND 1]
INFO :      fit: strategy FedAvg, 2 clients
INFO :      fit: received 2 results and 0 failures
INFO :      evaluate: strategy FedAvg, 2 clients
...
INFO :      [ROUND 3]
...
INFO :      [SUMMARY]
```

> **Note:** Training 25K images (CIFAR-10, 1 epoch) on a single vCPU takes approximately 5 minutes per round. Plan timing accordingly.

### Training Data

SuperNodes read training data from `/opt/flower/data/` inside the VM (mounted as `/app/data` in the container, read-only).

```bash
# Push data to SuperNode
scp -r ./my-training-data/ root@${SUPERNODE_IP}:/opt/flower/data/

# Set ownership for the container user
ssh root@${SUPERNODE_IP} 'chown -R 49999:49999 /opt/flower/data/'
```

The ClientApp code references data at the container path `/app/data`. Use `ONEAPP_FL_NODE_CONFIG` to pass partition information:

```
partition-id=0 num-partitions=2
```

> **Tip:** When `ONEAPP_FL_NODE_CONFIG` is empty and the VMs are part of a OneFlow service, the appliance auto-computes `partition-id` from the VM's index in the supernode role.

---

## 11. Customization

### 11a. Enabling TLS

TLS encrypts gRPC communication between SuperLink and SuperNodes, protecting model weights and gradients in transit.

**Auto-generated certificates (simplest):**

Set `ONEAPP_FL_TLS_ENABLED=YES` at the service level in the OneFlow template. At boot:

1. **SuperLink** generates a self-signed CA + server certificate (with VM IP as SAN), publishes `FL_CA_CERT` to OneGate, starts with `--ssl-*` flags.
2. **SuperNodes** retrieve `FL_CA_CERT` from OneGate, start with `--root-certificates`.

No manual certificate distribution required.

**Operator-provided certificates:**

Base64-encode your certificates and set them on the SuperLink role:

```bash
ONEAPP_FL_SSL_CA_CERTFILE=$(base64 -w0 < your-ca.crt)
ONEAPP_FL_SSL_CERTFILE=$(base64 -w0 < your-server.pem)
ONEAPP_FL_SSL_KEYFILE=$(base64 -w0 < your-server.key)
```

On SuperNodes, set `ONEAPP_FL_SSL_CA_CERTFILE` to supply your CA directly (bypasses OneGate retrieval).

**Verification:**

```bash
# Verify TLS is active
ssh root@${SUPERLINK_IP} \
  'openssl s_client -connect localhost:9092 </dev/null 2>/dev/null | head -5'

# Check certificate SAN
ssh root@${SUPERLINK_IP} \
  'openssl s_client -connect localhost:9092 </dev/null 2>/dev/null \
   | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"'
```

See [`spec/04-tls-certificate-lifecycle.md`](../spec/04-tls-certificate-lifecycle.md) and [`spec/05-supernode-tls-trust.md`](../spec/05-supernode-tls-trust.md).

### 11b. Enabling GPU Passthrough

GPU passthrough allows SuperNode containers to use NVIDIA GPUs for accelerated training. This requires a four-layer configuration.

**Layer 1: Host prerequisites** (infrastructure team, one-time)

```bash
# Enable IOMMU (add to GRUB_CMDLINE_LINUX)
# Intel: intel_iommu=on iommu=pt
# AMD:   amd_iommu=on iommu=pt
sudo update-grub && sudo reboot

# Bind GPU to vfio-pci
lspci -nn | grep -i nvidia
# Example: 01:00.0 3D controller [0302]: NVIDIA ... [10de:2204]
echo "10de 2204" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
```

**Layer 2: VM template** (OpenNebula admin)

```
PCI = [
    TYPE = "GPU",
    DEVICE = "0x2204",
    VENDOR = "0x10de",
    CLASS = "0x0302"
]
OS = [
    FIRMWARE = "/usr/share/OVMF/OVMF_CODE.fd",
    MACHINE = "q35"
]
CPU_MODEL = [
    MODEL = "host-passthrough"
]
```

**Layer 3: Container runtime** -- pre-installed in the QCOW2 image. No action needed.

**Layer 4: Enable at deployment**

```
ONEAPP_FL_GPU_ENABLED=YES
ONEAPP_FL_CUDA_VISIBLE_DEVICES=all        # or "0" or "0,1"
ONEAPP_FL_GPU_MEMORY_FRACTION=0.8         # PyTorch memory limit (0.0-1.0)
```

**Verification:**

```bash
ssh root@${SUPERNODE_IP} 'docker exec flower-supernode nvidia-smi'
ssh root@${SUPERNODE_IP} 'grep -i gpu /var/log/one-appliance/*.log'
```

> **Note:** If `ONEAPP_FL_GPU_ENABLED=YES` but no GPU is detected at boot, the appliance logs a WARNING and continues with CPU-only training. Training will be slower but the SuperNode remains functional.

See [`spec/10-gpu-passthrough.md`](../spec/10-gpu-passthrough.md).

### 11c. Monitoring and Observability

The monitoring stack provides multiple tiers of observability.

**Tier 1: Structured JSON logging** (zero infrastructure)

```
ONEAPP_FL_LOG_FORMAT=json
```

All Flower log output becomes single-line JSON objects with structured FL event data. Use with Docker's `json-file` log driver and query with `docker logs` or forward to any log aggregation system.

**Tier 2: Prometheus, Grafana, and FL Dashboard**

The monitoring stack runs as Docker containers on the OpenNebula frontend (not inside appliance VMs):

| Service | Port | URL | Description |
|---------|------|-----|-------------|
| FL Dashboard | 8080 | `http://<frontend>:8080` | Real-time cluster topology, training progress, node health |
| Prometheus | 9090 | `http://<frontend>:9090` | Metrics collection with 30-day retention |
| Grafana | 3000 | `http://<frontend>:3000` | Pre-built "FL Training Overview" dashboard (login: `admin` / `changeme123`) |

Prometheus is pre-configured to scrape SuperLink metrics at `:9101` with a 5-second interval. Grafana ships with a provisioned Prometheus datasource and an "FL Training Overview" dashboard containing 10 panels:

- Current round, connected clients, fit/evaluate round duration
- Training rounds over time, connected clients over time
- Raw metrics explorer

```bash
# Deploy the monitoring stack
cd /path/to/monitoring
docker compose up -d
```

> **Note:** The `ONEAPP_FL_METRICS_ENABLED` context variable and port 9101 are reserved for Flower's native metric export. To add custom FL metrics today, instrument your ServerApp strategy with `prometheus_client` gauges and expose them on the SuperLink VM.

**Tier 3: GPU metrics** (for GPU-enabled SuperNodes)

```
ONEAPP_FL_DCGM_ENABLED=YES
```

Starts a DCGM exporter sidecar exposing GPU metrics on port 9400.

See [`spec/13-monitoring-observability.md`](../spec/13-monitoring-observability.md).

### 11d. Scaling the SuperNode Role

OneFlow supports runtime scaling of the supernode role.

```bash
# Scale up -- new SuperNodes auto-discover and connect
oneflow scale <service_id> supernode 5

# Scale down -- SuperLink adjusts participant pool
oneflow scale <service_id> supernode 3
```

**Cardinality constraints** (defined in the service template):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `min_vms` | 2 | Minimum SuperNode count |
| `max_vms` | 10 | Maximum SuperNode count |
| `cardinality` | 2 | Initial SuperNode count at deployment |

---

## 12. Troubleshooting

### Boot Hangs or VM Never Reports READY

**Symptoms:** OneFlow shows the role stuck in `DEPLOYING`. The VM is `RUNNING` in OpenNebula but the service does not progress.

```bash
ssh root@<vm_ip> 'cat /var/log/one-appliance/*.log'
```

| Log message | Cause | Fix |
|-------------|-------|-----|
| `Docker daemon not available after 60s` | Docker failed to start | `systemctl status docker`, `journalctl -u docker` |
| `Configuration validation failed` | Invalid context variable | Check the specific variable in error message |
| `SuperLink health check timed out` | Container started but gRPC not listening | `docker logs flower-superlink` |
| No log files at all | Contextualization did not run | Check CONTEXT has `TOKEN=YES` |

### SuperNode Cannot Find SuperLink

**Symptoms:** SuperNode logs show `SuperLink discovery timed out after 30 attempts`.

```bash
# 1. Verify OneGate connectivity from SuperNode
ssh root@<supernode_ip> 'curl -s http://169.254.16.9:5030/vm \
    -H "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
    -H "X-ONEGATE-VMID: $(source /run/one-context/one_env && echo $VMID)"'

# 2. Verify SuperLink published FL_ENDPOINT
onevm show <superlink_vm_id> | grep FL_ENDPOINT

# 3. For static addressing (bypass OneGate):
# Set ONEAPP_FL_SUPERLINK_ADDRESS=<superlink_ip>:9092 on the SuperNode
```

### TLS Errors

**Symptoms:** `SSL handshake failed` or `UNAVAILABLE: Connection reset`.

```bash
# Verify certificate SAN includes SuperLink IP
ssh root@<superlink_ip> \
  'openssl x509 -in /opt/flower/certs/server.pem -noout -text \
   | grep -A5 "Subject Alternative Name"'

# Verify CA fingerprints match
ssh root@<supernode_ip> 'openssl x509 -in /opt/flower/certs/ca.crt -noout -fingerprint'
ssh root@<superlink_ip> 'openssl x509 -in /opt/flower/certs/ca.crt -noout -fingerprint'
```

| Issue | Cause | Fix |
|-------|-------|-----|
| CA fingerprint mismatch | Stale CA from OneGate | Redeploy SuperNode |
| SAN missing VM IP | IP changed after cert gen | Redeploy SuperLink |
| Mixed insecure/TLS | Inconsistent config | Set `ONEAPP_FL_TLS_ENABLED` at service level |

### GPU Not Detected

**Symptoms:** SuperNode logs show `FL_GPU_ENABLED=YES but GPU not available`.

```bash
ssh root@<supernode_ip> 'lspci | grep -i nvidia'        # Empty = not passed through
ssh root@<supernode_ip> 'lsmod | grep nvidia'            # Empty = driver not loaded
ssh root@<supernode_ip> 'nvidia-smi'                     # "No devices" = PCI config wrong
```

### Docker Issues

```bash
ssh root@<vm_ip> 'systemctl status docker'
ssh root@<vm_ip> 'journalctl -u docker --no-pager -n 50'
ssh root@<vm_ip> 'df -h /'                              # Check disk space
ssh root@<vm_ip> 'docker images | grep flwr'             # Verify images exist
ssh root@<vm_ip> 'docker system prune -f'                # Clean unused resources
```

### Container Keeps Restarting

```bash
ssh root@<vm_ip> 'systemctl status flower-superlink'     # or flower-supernode
ssh root@<vm_ip> 'docker inspect flower-superlink --format "{{.State.ExitCode}} {{.State.Error}}"'
ssh root@<vm_ip> 'docker logs flower-superlink --tail 50'
```

| Exit code | Cause | Fix |
|-----------|-------|-----|
| 137 | OOM killed | Increase VM RAM |
| 1 | Application error | Check container logs |
| 126 | Permission denied on volume | `chown 49999:49999` on mounted paths |

---

## 13. Known Issues and Workarounds

Issues discovered during real-world deployment that require operator awareness.

### 13a. Ubuntu 24.04 Marketplace Image Disk Size

The marketplace image ships with a 3.5 GB root disk -- insufficient for Docker.

```bash
# Resize in datastore
oneimage resize <image_id> 10240

# Or resize a running VM's disk
onevm disk-resize <vm_id> 0 10240

# After boot, extend the filesystem
growpart /dev/vda 1
resize2fs /dev/vda1
```

### 13b. `unattended-upgrades` Blocks apt on First Boot

Ubuntu 24.04 runs `unattended-upgrades` on first boot, holding the apt lock.

```bash
systemctl stop unattended-upgrades
systemctl disable unattended-upgrades
apt-get remove -y unattended-upgrades
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
```

### 13c. GPG `--batch` Flag for Non-Interactive Environments

`gpg --dearmor` requires a TTY by default. In Packer provisioners or cloud-init:

```bash
curl -fsSL https://example.com/key.gpg | gpg --batch --yes --dearmor -o /path/to/keyring.gpg
```

The appliance scripts already include `--batch --yes` on all `gpg` invocations.

### 13d. Status File Must Be `install_success`

The one-apps framework checks for `install_success` (not `install_done`):

```bash
echo "install_success" > /etc/one-appliance/status
```

### 13e. Systemd Unit Empty-Line Bug

Empty `${var:+...}` conditionals in the generated systemd unit produce empty lines that break backslash continuations.

**Fix:** The SuperLink appliance script builds `ExecStart` as an array, including only non-empty flags. See `build/superlink/appliance.sh`, function `generate_systemd_unit()`.

### 13f. SuperNode Cross-Function Variable Scoping

`service_configure()` and `service_bootstrap()` run as separate process invocations. Variables from `configure` are not available in `bootstrap`.

**Fix:** The SuperNode appliance script persists variables to `/opt/flower/config/configure.state` and sources them in `bootstrap`.

### 13g. OneFlow `vm_template_contents` CONTEXT Block Parsing

Nested CONTEXT blocks in OneFlow's `vm_template_contents` JSON may fail to parse nested quotes.

**Workaround:** Set context variables at the VM template level (`onetemplate update`) rather than through `vm_template_contents`. Simple key-value overrides work correctly.

### 13h. Powered-Off VMs Still Count Toward Host Allocation

VMs in `POWEROFF` state still consume host memory/CPU allocation.

**Workaround:** Use `onevm undeploy <vm_id>` instead of `onevm poweroff`. Disk state is preserved and can be resumed with `onevm resume`.

### 13i. `service_cleanup()` Destroys Containers After Bootstrap

The one-appliance framework calls `service_cleanup()` **after** `service_bootstrap()`. Since bootstrap creates the Docker container, cleanup destroys it immediately.

**Fix:** Both `build/superlink/appliance.sh` and `build/supernode/appliance.sh` override `service_cleanup()` as a no-op:

```bash
service_cleanup() {
    # Intentionally empty. The framework calls cleanup after bootstrap,
    # which would destroy the container we just started.
    return 0
}
```

> **Warning:** If you write a custom appliance.sh, you must include this override. Without it, your Flower container will be created and immediately destroyed on every boot.

### 13j. OpenNebula `RESTRICTED_DIRS` Blocks Upload from `/root`

`oneimage create` fails when `--path` points to a file under `/root/` due to the `RESTRICTED_DIRS` security setting.

**Workaround:**

```bash
cp /root/build/export/flower-superlink.qcow2 /var/tmp/
oneimage create --name "Flower SuperLink v1.25.0" \
    --path /var/tmp/flower-superlink.qcow2 \
    --type OS --driver qcow2 --datastore default
```

### 13k. After SuperLink Restart, Restart All SuperNodes

When the SuperLink is restarted (VM reboot, container restart, or `systemctl restart flower-superlink`), all existing SuperNode connections become invalid. The SuperLink issues new node IDs on startup, and SuperNodes holding old IDs will fail to communicate.

**Fix:** After any SuperLink restart, restart all SuperNode VMs or their containers:

```bash
# Restart SuperNode containers
ssh root@<supernode_ip> 'systemctl restart flower-supernode'
```

### 13l. gRPC "bytes_sent/bytes_recv Cannot Be Zero"

This error occurs when the SuperLink's state database (`/opt/flower/state/state.db`) contains stale connection records from a previous session.

**Fix:**

```bash
# On the SuperLink VM
ssh root@${SUPERLINK_IP} 'systemctl stop flower-superlink'
ssh root@${SUPERLINK_IP} 'rm -f /opt/flower/state/state.db'
ssh root@${SUPERLINK_IP} 'systemctl start flower-superlink'

# Then restart all SuperNodes (see 13k)
```

### 13m. Streaming Docker Images to Disk-Constrained VMs

When the OpenNebula frontend or build host has limited disk space, avoid writing Docker image tarballs to disk. Stream directly:

```bash
docker save <image> | gzip | ssh root@<vm_ip> 'gunzip | docker load'
```

This avoids writing a temporary `.tar.gz` file, which can be 2-4 GB for images with PyTorch baked in.

---

<details>
<summary><strong>File Reference</strong></summary>

### Build Directory

| File | Purpose | Spec |
|------|---------|------|
| `build/Makefile` | Build driver: targets for superlink, supernode, clean | -- |
| `build/superlink/appliance.sh` | SuperLink one-apps lifecycle script | [01-superlink-appliance.md](../spec/01-superlink-appliance.md) |
| `build/supernode/appliance.sh` | SuperNode one-apps lifecycle script | [02-supernode-appliance.md](../spec/02-supernode-appliance.md) |
| `build/packer/superlink/superlink.pkr.hcl` | Packer template for SuperLink QCOW2 image | [01-superlink-appliance.md](../spec/01-superlink-appliance.md) |
| `build/packer/superlink/variables.pkr.hcl` | Packer variables for SuperLink build | -- |
| `build/packer/superlink/gen_context` | Generates contextualization ISO for Packer SSH access | -- |
| `build/packer/supernode/supernode.pkr.hcl` | Packer template for SuperNode QCOW2 image (20 GB) | [02-supernode-appliance.md](../spec/02-supernode-appliance.md) |
| `build/packer/supernode/variables.pkr.hcl` | Packer variables for SuperNode build | -- |
| `build/packer/supernode/gen_context` | Generates contextualization ISO for Packer SSH access | -- |
| `build/packer/scripts/81-configure-ssh.sh` | SSH hardening provisioner | -- |
| `build/packer/scripts/82-configure-context.sh` | Installs one-apps contextualization hooks | -- |
| `build/oneflow/flower-cluster.yaml` | OneFlow service template | [08-single-site-orchestration.md](../spec/08-single-site-orchestration.md) |
| `build/docker/superlink/docker-compose.yml` | Docker Compose for SuperLink with optional monitoring | [13-monitoring-observability.md](../spec/13-monitoring-observability.md) |
| `build/docker/supernode/docker-compose.yml` | Docker Compose for SuperNode | -- |

### VM Internal Paths (After Boot)

| Path | Component | Purpose |
|------|-----------|---------|
| `/etc/one-appliance/service` | Both | one-apps lifecycle dispatcher |
| `/etc/one-appliance/service.d/appliance.sh` | Both | Flower appliance lifecycle script |
| `/opt/flower/scripts/health-check.sh` | Both | Readiness probe for REPORT_READY |
| `/opt/flower/config/superlink.env` | SuperLink | Generated Docker environment file |
| `/opt/flower/config/supernode.env` | SuperNode | Generated Docker environment file |
| `/opt/flower/config/configure.state` | SuperNode | Persisted variables from configure |
| `/opt/flower/state/` | SuperLink | SQLite state database |
| `/opt/flower/certs/` | Both | TLS certificates (when enabled) |
| `/opt/flower/data/` | SuperNode | Local training data mount point |
| `/opt/flower/PREBAKED_VERSION` | Both | Pre-baked version for override detection |
| `/etc/systemd/system/flower-superlink.service` | SuperLink | Systemd unit for container lifecycle |
| `/etc/systemd/system/flower-supernode.service` | SuperNode | Systemd unit for container lifecycle |
| `/var/log/one-appliance/flower-configure.log` | Both | Boot-time configuration log |
| `/var/log/one-appliance/flower-bootstrap.log` | Both | Boot-time bootstrap log |
| `/run/one-context/one_env` | Both | OpenNebula context variables |
| `/run/one-context/token.txt` | Both | OneGate authentication token |

</details>

<details>
<summary><strong>Spec Documents</strong></summary>

| File | Content |
|------|---------|
| [`spec/00-overview.md`](../spec/00-overview.md) | Architecture overview, design principles, roadmap |
| [`spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md) | SuperLink: boot sequence, Docker config, OneGate |
| [`spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md) | SuperNode: discovery model, GPU detection, health |
| [`spec/03-contextualization-reference.md`](../spec/03-contextualization-reference.md) | All 48 context variables with validation rules |
| [`spec/04-tls-certificate-lifecycle.md`](../spec/04-tls-certificate-lifecycle.md) | TLS: CA generation, cert signing, OneGate publish |
| [`spec/05-supernode-tls-trust.md`](../spec/05-supernode-tls-trust.md) | TLS: CA retrieval, trust modes, handshake walkthrough |
| [`spec/06-ml-framework-variants.md`](../spec/06-ml-framework-variants.md) | PyTorch, TensorFlow, scikit-learn image variants |
| [`spec/07-use-case-templates.md`](../spec/07-use-case-templates.md) | Pre-built Flower App Bundles |
| [`spec/08-single-site-orchestration.md`](../spec/08-single-site-orchestration.md) | OneFlow template, deployment sequencing, scaling |
| [`spec/09-training-configuration.md`](../spec/09-training-configuration.md) | Aggregation strategies, checkpointing, failure recovery |
| [`spec/10-gpu-passthrough.md`](../spec/10-gpu-passthrough.md) | NVIDIA GPU passthrough four-layer stack |
| [`spec/12-multi-site-federation.md`](../spec/12-multi-site-federation.md) | Cross-zone deployment, WireGuard, gRPC keepalive |
| [`spec/13-monitoring-observability.md`](../spec/13-monitoring-observability.md) | JSON logging, Prometheus metrics, Grafana dashboards |
| [`spec/14-edge-and-auto-scaling.md`](../spec/14-edge-and-auto-scaling.md) | Edge SuperNode variant, OneFlow elasticity policies |

</details>

---

## Appendix A: Manual Deployment (Without Packer)

When Packer is not practical (resource-constrained hosts, marketplace image base, or environments without KVM nesting), build appliance images manually using a "builder VM" approach.

**Time estimate:** 30-45 minutes

### A.1. Overview

Instead of Packer launching a temporary QEMU VM, you:

1. Import a base Ubuntu 24.04 image from the OpenNebula marketplace.
2. Resize the disk to accommodate Docker.
3. Boot a "builder" VM from that image.
4. SSH in and run the appliance provisioning commands.
5. Save the VM's disk as a new image.
6. Create VM templates from the saved images.

### A.2. Import and Resize the Base Image

```bash
# Export Ubuntu 24.04 from the marketplace
onemarketapp export <ubuntu2404_app_id> "Ubuntu 24.04 Base" -d <datastore_id>

# Wait for READY
oneimage list | grep "Ubuntu 24.04"

# Resize to 10 GB (marketplace image is only 3.5 GB)
oneimage resize <image_id> 10240
```

### A.3. Boot the Builder VM

```bash
onetemplate create <<'EOF'
NAME = "Flower Builder"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE_ID = <image_id> ]
NIC = [ NETWORK_ID = <your_network_id> ]
CONTEXT = [
    TOKEN = "YES",
    NETWORK = "YES",
    SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF

onetemplate instantiate <template_id>
```

Wait for `RUNNING` state, then SSH in.

### A.4. Prepare the System

```bash
ssh root@<builder_ip>

# Extend filesystem to full 10 GB
growpart /dev/vda 1
resize2fs /dev/vda1

# Disable unattended-upgrades (see Known Issue 13b)
systemctl stop unattended-upgrades
systemctl disable unattended-upgrades
apt-get remove -y unattended-upgrades
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 1; done
```

### A.5. Install the one-apps Framework

```bash
apt-get update && apt-get install -y git
git clone https://github.com/OpenNebula/one-apps.git /tmp/one-apps

# Install service manager and libraries
mkdir -p /etc/one-appliance/service.d
cp /tmp/one-apps/appliances/service.sh /etc/one-appliance/service
chmod +x /etc/one-appliance/service
mkdir -p /etc/one-appliance/lib
cp /tmp/one-apps/appliances/lib/common.sh /etc/one-appliance/lib/
cp /tmp/one-apps/appliances/lib/functions.sh /etc/one-appliance/lib/

# Install contextualization hooks
cp /tmp/one-apps/appliances/scripts/net-90-service-appliance \
   /etc/one-context.d/net-90-service-appliance
cp /tmp/one-apps/appliances/scripts/net-99-report-ready \
   /etc/one-context.d/net-99-report-ready
chmod +x /etc/one-context.d/net-90-service-appliance
chmod +x /etc/one-context.d/net-99-report-ready

rm -rf /tmp/one-apps
```

### A.6. Provision the SuperLink

```bash
# Copy the appliance script (from your workstation)
scp build/superlink/appliance.sh root@<builder_ip>:/etc/one-appliance/service.d/appliance.sh

# SSH in and run install
ssh root@<builder_ip>
source /etc/one-appliance/service
source /etc/one-appliance/service.d/appliance.sh

service_install

# Mark as successful (must be exactly 'install_success' -- see Known Issue 13d)
echo "install_success" > /etc/one-appliance/status

# Stop Docker before saving (layers persist in /var/lib/docker/)
systemctl stop docker

# Clean up for image reuse
cloud-init clean 2>/dev/null || true
truncate -s 0 /etc/machine-id
rm -rf /tmp/* /var/tmp/*
```

> **Warning:** Ensure your `appliance.sh` includes the `service_cleanup()` no-op override (see [Known Issue 13i](#13i-service_cleanup-destroys-containers-after-bootstrap)). Without it, the Flower container will be destroyed immediately after creation on every boot.

### A.7. Save the SuperLink Image

```bash
# From your OpenNebula frontend (not inside the VM)
onevm poweroff <builder_vm_id>
onevm disk-saveas <builder_vm_id> 0 "Flower SuperLink v1.25.0"
oneimage list | grep "Flower SuperLink"
```

### A.8. Provision the SuperNode

Boot a fresh builder VM from the original base image (not the SuperLink image). Repeat steps A.3 through A.5, then:

```bash
# Copy the SuperNode appliance script
scp build/supernode/appliance.sh root@<builder_ip>:/etc/one-appliance/service.d/appliance.sh

# SSH in and run install
ssh root@<builder_ip>
source /etc/one-appliance/service
source /etc/one-appliance/service.d/appliance.sh

service_install

echo "install_success" > /etc/one-appliance/status
systemctl stop docker
cloud-init clean 2>/dev/null || true
truncate -s 0 /etc/machine-id
rm -rf /tmp/* /var/tmp/*
```

Save as "Flower SuperNode v1.25.0" using the same `disk-saveas` procedure from A.7.

### A.9. Create Templates and Deploy

You already have the images. Skip the upload in Section 5 and create VM templates directly:

```bash
onetemplate create <<'EOF'
NAME = "Flower SuperLink"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperLink v1.25.0" ]
NIC = [ NETWORK_ID = <your_network_id> ]
CONTEXT = [
    TOKEN = "YES",
    NETWORK = "YES",
    REPORT_READY = "YES",
    SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
    ONEAPP_FL_FLEET_API_ADDRESS = "0.0.0.0:9092"
]
EOF

onetemplate create <<'EOF'
NAME = "Flower SuperNode"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperNode v1.25.0" ]
NIC = [ NETWORK_ID = <your_network_id> ]
CONTEXT = [
    TOKEN = "YES",
    NETWORK = "YES",
    REPORT_READY = "YES",
    SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
    ONEAPP_FL_SUPERLINK_ADDRESS = "<superlink_ip>:9092"
]
EOF
```

> **Note:** For manual deployment without OneFlow, set `ONEAPP_FL_SUPERLINK_ADDRESS` directly on the SuperNode template instead of relying on OneGate discovery.

### A.10. Verification

After deploying VMs from the saved images, verify the cluster using [Section 8](#8-verifying-the-deployment) and [Section 9](#9-verifying-fl-communication).
