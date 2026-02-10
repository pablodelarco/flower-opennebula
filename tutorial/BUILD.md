# Building and Deploying Flower-OpenNebula Appliances

A step-by-step guide for building Flower federated learning QCOW2 appliance
images and deploying a Flower cluster on OpenNebula. This tutorial targets
OpenNebula administrators familiar with Packer and VM management.

**Spec references:** This tutorial implements the architecture defined in
[`../spec/00-overview.md`](../spec/00-overview.md). Individual spec files are
referenced throughout for deeper detail.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Building the SuperLink Image](#3-building-the-superlink-image)
4. [Building the SuperNode Image](#4-building-the-supernode-image)
5. [Uploading to OpenNebula](#5-uploading-to-opennebula)
6. [Creating the OneFlow Service Template](#6-creating-the-oneflow-service-template)
7. [Deploying a Flower Cluster](#7-deploying-a-flower-cluster)
8. [Verifying the Deployment](#8-verifying-the-deployment)
9. [Submitting a Training Run](#9-submitting-a-training-run)
10. [Customization Options](#10-customization-options)
11. [Troubleshooting](#11-troubleshooting)
12. [File Reference](#12-file-reference)

---

## 1. Overview

This build system produces two QCOW2 virtual machine images for the
OpenNebula marketplace:

- **SuperLink** -- The Flower federated learning coordinator. Orchestrates
  training rounds, aggregates model updates from clients, and persists state.
- **SuperNode** -- The Flower federated learning client. Trains a local model
  on private data and sends weight updates to the SuperLink. Data never leaves
  the VM.

Both images follow a Docker-in-VM architecture: a single Flower container runs
inside a dedicated Ubuntu 24.04 VM, managed by systemd. The one-apps
contextualization framework handles boot-time configuration from OpenNebula
CONTEXT variables.

### Architecture

```
                        OneFlow Service
    +-----------------------------------------------------------+
    |                                                           |
    |   +-------------------+       +-------------------+      |
    |   |   SuperLink VM    |       |  SuperNode VM #1  |      |
    |   |                   |       |                   |      |
    |   |  flwr/superlink   |<------+  flwr/supernode   |      |
    |   |   :9091 SrvAppIo  | gRPC  |                   |      |
    |   |   :9092 Fleet API | :9092 |  (no inbound)     |      |
    |   |   :9093 Ctrl API  |       |                   |      |
    |   |   :9101 Metrics*  |       +-------------------+      |
    |   +-------------------+                                   |
    |          |                    +-------------------+       |
    |          | OneGate PUT        |  SuperNode VM #2  |       |
    |          v                    |                   |       |
    |   +--------------+            |  flwr/supernode   |       |
    |   |   OneGate    |<-----------+                   |       |
    |   |   Service    | OneGate GET|                   |       |
    |   +--------------+            +-------------------+       |
    |                                                           |
    +-----------------------------------------------------------+
```

**Data flow:**

1. SuperLink boots, starts the Flower container, publishes its endpoint to
   OneGate (`FL_ENDPOINT=<ip>:9092`).
2. SuperNode boots, discovers the SuperLink via OneGate (or a static address),
   connects to the Fleet API on port 9092 over gRPC.
3. The SuperLink assigns training rounds. SuperNodes train locally and report
   model weight updates.
4. Model weights and gradients are the only data transmitted. Training data
   stays on each SuperNode VM.

### Port Summary

| Port | Protocol | Service      | Component   | Description                         |
|------|----------|------------- |-------------|-------------------------------------|
| 9091 | gRPC     | ServerAppIo  | SuperLink   | Internal API for subprocess-managed ServerApp |
| 9092 | gRPC     | Fleet API    | SuperLink   | SuperNode connections (primary data plane)    |
| 9093 | gRPC     | Control API  | SuperLink   | CLI management and run submission             |
| 9101 | HTTP     | FL Metrics   | SuperLink   | Prometheus metrics endpoint (optional)        |
| 9400 | HTTP     | DCGM Metrics | SuperNode   | GPU metrics via DCGM exporter (optional)      |

### Orchestration Model

OneFlow deploys the SuperLink role first. Once the SuperLink reports
`READY=YES` via `REPORT_READY`, OneFlow starts the SuperNode role. Each
SuperNode discovers the SuperLink endpoint through OneGate and connects
automatically. No manual IP configuration is needed for single-site
deployments.

**Spec:** [`../spec/08-single-site-orchestration.md`](../spec/08-single-site-orchestration.md)

---

## 2. Prerequisites

### Hardware

- **Architecture:** x86_64 (amd64)
- **Virtualization:** KVM support enabled (check with `kvm-ok` or
  `grep -c vmx /proc/cpuinfo`)
- **Disk:** At least 30 GB free for build artifacts
- **RAM:** 4 GB minimum available for the build VM

### Software

| Tool             | Version    | Purpose                                     |
|------------------|------------|---------------------------------------------|
| Packer           | >= 1.9     | Image build orchestration                   |
| QEMU/KVM         | any recent | VM execution during build                   |
| mkisofs or genisoimage | any  | Contextualization ISO creation              |
| jq               | any        | JSON processing for verification            |
| make             | any        | Build driver                                |

Install on Ubuntu/Debian:

```bash
# Packer (HashiCorp APT repository)
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt-get update && sudo apt-get install packer

# QEMU/KVM and other tools
sudo apt-get install qemu-system-x86 qemu-utils genisoimage jq make
```

### one-apps Framework

The build depends on the OpenNebula one-apps framework for contextualization
scripts and the service lifecycle manager. Clone it adjacent to the project:

```bash
cd /path/to/workspace
git clone https://github.com/OpenNebula/one-apps.git
```

### Base Image

You need an Ubuntu 22.04 QCOW2 base image, either exported from the one-apps
build system or downloaded from the OpenNebula marketplace.

```bash
# Option A: Build from one-apps
cd one-apps
make ubuntu2204

# Option B: Download a pre-built image from OpenNebula marketplace
# Place it as ubuntu2204.qcow2
```

### Expected File Layout

Before building, your workspace should look like this:

```
workspace/
    one-apps/                          # one-apps framework checkout
        appliances/
            service.sh                 # Service lifecycle manager
            lib/common.sh              # Shared library
            lib/functions.sh           # Helper functions
            scripts/
                net-90-service-appliance
                net-99-report-ready
    flower-opennebula/
        build/
            images/
                ubuntu2204.qcow2      # Base image (you provide this)
            Makefile                   # Build driver
            superlink/
                appliance.sh           # SuperLink lifecycle script
            supernode/
                appliance.sh           # SuperNode lifecycle script
            packer/
                superlink/             # SuperLink Packer template
                supernode/             # SuperNode Packer template
                scripts/               # Shared Packer provisioners
            oneflow/
                flower-cluster.yaml    # OneFlow service template
```

---

## 3. Building the SuperLink Image

### Build Command

```bash
cd /path/to/flower-opennebula/build

make flower-superlink \
    INPUT_DIR=./images \
    ONE_APPS_DIR=../../one-apps
```

### What Happens During the Build

Packer launches a temporary QEMU VM from the Ubuntu 22.04 base image and runs
these provisioning steps:

1. **SSH hardening** -- Reverts the insecure build-time SSH settings used for
   Packer access.
2. **one-apps framework install** -- Copies the service lifecycle manager,
   shared libraries, and contextualization hooks into the VM.
3. **Appliance script install** -- Places `superlink/appliance.sh` at
   `/etc/one-appliance/service.d/appliance.sh` inside the VM.
4. **Context hooks** -- Configures the one-apps contextualization hooks
   (`net-90-service-appliance`, `net-99-report-ready`).
5. **`service install` execution** -- Runs the appliance's `service_install()`
   function, which:
   - Installs Docker CE from the official APT repository.
   - Pulls `flwr/superlink:1.25.0` into the local Docker image cache.
   - Installs OpenSSL (for TLS certificate generation), jq, and netcat.
   - Creates the `/opt/flower/` directory tree with correct UID 49999
     ownership.
   - Records the pre-baked version in `/opt/flower/PREBAKED_VERSION`.
   - Stops Docker (image layers persist in `/var/lib/docker/`).
6. **Cloud cleanup** -- Truncates `machine-id`, clears temp files, runs
   `cloud-init clean` so the image is reusable.

### Build Output

```
build/export/flower-superlink.qcow2
```

**Disk configuration:** 10 GB virtual disk (QCOW2 format, sparse allocation).
The compressed image size is approximately 2-3 GB depending on Docker layer
compression.

### Verifying the Build

```bash
# Check that the output file exists and has a reasonable size
ls -lh build/export/flower-superlink.qcow2

# Inspect the QCOW2 header
qemu-img info build/export/flower-superlink.qcow2
```

**Spec:** [`../spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md)

---

## 4. Building the SuperNode Image

### Build Command

```bash
cd /path/to/flower-opennebula/build

make flower-supernode \
    INPUT_DIR=./images \
    ONE_APPS_DIR=../../one-apps
```

### What Happens During the Build

The SuperNode build follows the same Packer workflow as the SuperLink, with
these differences:

- **Larger disk:** 20 GB virtual disk (vs. 10 GB for SuperLink) to accommodate
  ML framework Docker images and training data.
- **Different Docker image:** Pulls `flwr/supernode:1.25.0` instead of
  `flwr/superlink:1.25.0`.
- **NVIDIA Container Toolkit:** Best-effort install of the NVIDIA Container
  Toolkit. This enables `docker run --gpus all` at runtime when GPU passthrough
  is configured. Skips silently if no GPU hardware is detected on the build
  host.
- **Data directory:** Creates `/opt/flower/data/` (owned by UID 49999) as the
  mount point for local training data.

### Build Output

```
build/export/flower-supernode.qcow2
```

**Disk configuration:** 20 GB virtual disk. The compressed image is
approximately 2-3 GB for the base variant (no ML framework images pre-pulled).
Framework-specific variants (PyTorch, TensorFlow) are larger due to
pre-pulled framework images.

### Building Both Images

```bash
cd /path/to/flower-opennebula/build

make all INPUT_DIR=./images ONE_APPS_DIR=../../one-apps
```

This builds both `flower-superlink.qcow2` and `flower-supernode.qcow2`
sequentially.

### Validation

Before building, you can validate the shell scripts and Packer templates:

```bash
make validate
```

This runs `bash -n` on all shell scripts and `packer validate -syntax-only` on
both Packer templates.

**Spec:** [`../spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md)

---

## 5. Uploading to OpenNebula

### Upload the Images

```bash
# Upload SuperLink image
oneimage create \
    --name "Flower SuperLink v1.25.0" \
    --path /path/to/build/export/flower-superlink.qcow2 \
    --type OS \
    --driver qcow2 \
    --datastore default

# Upload SuperNode image
oneimage create \
    --name "Flower SuperNode v1.25.0" \
    --path /path/to/build/export/flower-supernode.qcow2 \
    --type OS \
    --driver qcow2 \
    --datastore default
```

Wait for both images to reach the `READY` state:

```bash
oneimage list | grep "Flower"
```

### Create VM Templates

Create a VM template for each appliance role. These templates define the
hardware resources that OneFlow will use when instantiating the cluster.

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

Record the template IDs (shown in the output of `onetemplate create`). You
will need them for the OneFlow service template.

### Minimum Resources

| Role       | Min vCPU | Min RAM  | Min Disk | Notes                            |
|------------|----------|----------|----------|----------------------------------|
| SuperLink  | 2        | 4 GB     | 10 GB    | Aggregation is CPU-bound         |
| SuperNode  | 2        | 4 GB     | 20 GB    | Model training, data storage     |

For production workloads, increase SuperLink RAM proportionally to the model
size and number of clients. SuperNode resources depend on the ML workload:
LLM fine-tuning may require 16+ GB RAM and GPU passthrough.

**Spec:** [`../spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md) Section 5,
[`../spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md) Section 5

---

## 6. Creating the OneFlow Service Template

### Register the Template

The service template is provided as a YAML file at
`build/oneflow/flower-cluster.yaml`. Before registering it, edit the file to
set your actual VM template IDs and network ID.

```bash
# Find your template IDs
onetemplate list | grep "Flower"

# Find your network ID
onevnet list
```

Edit `build/oneflow/flower-cluster.yaml`:

```yaml
roles:
  - name: 'superlink'
    vm_template: <YOUR_SUPERLINK_TEMPLATE_ID>   # Replace 0
    # ...

  - name: 'supernode'
    vm_template: <YOUR_SUPERNODE_TEMPLATE_ID>    # Replace 0
    # ...
```

The `$Private` network reference in `vm_template_contents` is resolved from the
`networks` section at the top of the template. Set this to your private
network for FL cluster communication.

Register the template:

```bash
oneflow-template create build/oneflow/flower-cluster.yaml
```

Record the service template ID from the output.

### Template Configuration Overview

The service template uses a three-level configuration hierarchy:

**Service-level variables** (apply to all roles):

| Variable                    | Default   | Description                              |
|-----------------------------|-----------|------------------------------------------|
| `ONEAPP_FLOWER_VERSION`     | `1.25.0`  | Flower version (must match both roles)   |
| `ONEAPP_FL_TLS_ENABLED`     | `NO`      | Enable TLS encryption                    |
| `ONEAPP_FL_LOG_LEVEL`       | `INFO`    | Log verbosity                            |
| `ONEAPP_FL_LOG_FORMAT`      | `text`    | Log format (`text` or `json`)            |

**SuperLink role variables:**

| Variable                            | Default       | Description                    |
|-------------------------------------|---------------|--------------------------------|
| `ONEAPP_FL_NUM_ROUNDS`              | `3`           | Number of training rounds      |
| `ONEAPP_FL_STRATEGY`                | `FedAvg`      | Aggregation strategy           |
| `ONEAPP_FL_MIN_FIT_CLIENTS`         | `2`           | Min clients per training round |
| `ONEAPP_FL_MIN_EVALUATE_CLIENTS`    | `2`           | Min clients for evaluation     |
| `ONEAPP_FL_MIN_AVAILABLE_CLIENTS`   | `2`           | Min connected clients to start |
| `ONEAPP_FL_CHECKPOINT_ENABLED`      | `NO`          | Enable model checkpointing     |
| `ONEAPP_FL_METRICS_ENABLED`         | `NO`          | Enable Prometheus metrics      |

**SuperNode role variables:**

| Variable                           | Default  | Description                           |
|------------------------------------|----------|---------------------------------------|
| `ONEAPP_FL_NODE_CONFIG`            | (empty)  | key=value pairs for ClientApp         |
| `ONEAPP_FL_GPU_ENABLED`            | `NO`     | Enable GPU passthrough                |
| `ONEAPP_FL_CUDA_VISIBLE_DEVICES`   | `all`    | GPU device selection                  |
| `ONEAPP_FL_DCGM_ENABLED`           | `NO`     | Enable DCGM GPU metrics               |

For the full variable reference, see
[`../spec/03-contextualization-reference.md`](../spec/03-contextualization-reference.md).

**Spec:** [`../spec/08-single-site-orchestration.md`](../spec/08-single-site-orchestration.md)

---

## 7. Deploying a Flower Cluster

### Instantiate the Service

```bash
oneflow-template instantiate <service_template_id>
```

You can also instantiate from the Sunstone web UI, where the service-level
and role-level variables appear as form fields.

### What Happens During Deployment

The deployment follows a strict sequence managed by OneFlow:

```
Phase 1: SuperLink Deployment
    OneFlow creates SuperLink VM
        |
        +-- OS boots, contextualization runs
        +-- configure.sh: validate config, generate env file, systemd unit
        +-- bootstrap.sh: wait for Docker, start container
        +-- health-check.sh: wait for port 9092 to accept TCP connections
        +-- Publish FL_ENDPOINT to OneGate
        +-- REPORT_READY -> READY=YES
        |
Phase 2: SuperNode Deployment (starts after SuperLink is READY)
    OneFlow creates SuperNode VMs (default: 2)
        |
        +-- OS boots, contextualization runs
        +-- configure.sh: validate config, discover SuperLink via OneGate
        +-- bootstrap.sh: wait for Docker, detect GPU, start container
        +-- Container connects to SuperLink Fleet API on port 9092
        +-- REPORT_READY -> READY=YES
```

**Key timing:** SuperNode discovery uses a retry loop (30 attempts, 10s
interval, 5 min total) to handle the timing gap where SuperLink may still be
booting. In practice, the SuperLink reports READY within 30-90 seconds.

### Monitor Deployment Progress

```bash
# Watch service status (refreshes every 5 seconds)
watch -n 5 oneflow show <service_id>

# Check individual VM status
onevm list | grep flower
```

**Service states to watch for:**

| State         | Meaning                                              |
|---------------|------------------------------------------------------|
| `PENDING`     | Service is being created                             |
| `DEPLOYING`   | VMs are being created and booted                     |
| `RUNNING`     | All roles are READY, cluster is operational          |
| `FAILED`      | One or more VMs failed to reach READY                |

### Passing Custom Parameters at Instantiation

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

### Check SuperLink

```bash
# Get the SuperLink VM IP
SUPERLINK_IP=$(onevm show <superlink_vm_id> --json | jq -r '.VM.TEMPLATE.NIC[0].IP')

# SSH into the SuperLink VM and check the container
ssh root@${SUPERLINK_IP} 'docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"'

# Check container logs
ssh root@${SUPERLINK_IP} 'docker logs flower-superlink --tail 20'

# Verify the Fleet API is listening
ssh root@${SUPERLINK_IP} 'nc -z localhost 9092 && echo "Fleet API OK" || echo "Fleet API FAILED"'
```

Expected output from `docker logs`:

```
INFO :      Starting Flower server...
INFO :      Flower ECE: gRPC server running ...
```

### Check SuperNode(s)

```bash
# Get SuperNode VM IPs
SUPERNODE_IP=$(onevm show <supernode_vm_id> --json | jq -r '.VM.TEMPLATE.NIC[0].IP')

# Check container status
ssh root@${SUPERNODE_IP} 'docker ps --format "table {{.Names}}\t{{.Status}}"'

# Check container logs
ssh root@${SUPERNODE_IP} 'docker logs flower-supernode --tail 20'
```

Expected output from `docker logs`:

```
INFO :      Opened insecure gRPC connection
```

### Check OneGate State

```bash
# Verify SuperLink published its endpoint
onevm show <superlink_vm_id> | grep FL_

# Expected output:
#   FL_READY=YES
#   FL_ENDPOINT=<ip>:9092
#   FL_VERSION=1.25.0
#   FL_ROLE=superlink

# Verify SuperNode published its status
onevm show <supernode_vm_id> | grep FL_

# Expected output:
#   FL_NODE_READY=YES
#   FL_VERSION=1.25.0
```

### Health Check from Outside

```bash
# Test Fleet API port connectivity
nc -z ${SUPERLINK_IP} 9092 && echo "Fleet API reachable" || echo "Fleet API unreachable"

# Test Control API port
nc -z ${SUPERLINK_IP} 9093 && echo "Control API reachable" || echo "Control API unreachable"
```

### Verify OneFlow Service Status

```bash
oneflow show <service_id>

# All roles should show state: RUNNING
# superlink: 1/1 VMs running
# supernode: 2/2 VMs running (or however many you configured)
```

---

## 9. Submitting a Training Run

Once the cluster is running, submit a Flower App Bundle (FAB) containing
your ServerApp and ClientApp code.

### Using the Flower CLI

From a machine with the Flower CLI installed (`pip install flwr`):

```bash
# Submit a training run to the SuperLink Control API
flwr run --superlink ${SUPERLINK_IP}:9093
```

This command:

1. Connects to the SuperLink's Control API on port 9093.
2. Uploads the FAB (ServerApp + ClientApp code).
3. The SuperLink distributes the ClientApp to connected SuperNodes.
4. Training rounds execute: SuperNodes train locally, SuperLink aggregates.

### Monitoring Training Progress

```bash
# Watch SuperLink logs for round progress
ssh root@${SUPERLINK_IP} 'docker logs -f flower-superlink'

# Expected output during training:
#   INFO :      [ROUND 1]
#   INFO :      fit: strategy FedAvg, 2 clients
#   INFO :      fit: received 2 results and 0 failures
#   INFO :      evaluate: strategy FedAvg, 2 clients
#   ...
#   INFO :      [ROUND 3]
#   ...
#   INFO :      [SUMMARY]
```

### Training Data

SuperNodes read training data from `/opt/flower/data/` inside the VM (mounted
as `/app/data` in the container, read-only). Provision data before starting a
training run:

```bash
# Push data to SuperNode via SCP
scp -r ./my-training-data/ root@${SUPERNODE_IP}:/opt/flower/data/

# Set ownership for the container user
ssh root@${SUPERNODE_IP} 'chown -R 49999:49999 /opt/flower/data/'
```

The ClientApp code references data at the container path `/app/data`. Use the
`--node-config` parameter (via `ONEAPP_FL_NODE_CONFIG`) to pass partition
information so each SuperNode knows which data subset to use:

```
partition-id=0 num-partitions=2
```

When `ONEAPP_FL_NODE_CONFIG` is empty and the VMs are part of a OneFlow
service, the appliance auto-computes `partition-id` from the VM's index in the
supernode role.

---

## 10. Customization Options

### 10a. Enabling TLS

TLS encrypts the gRPC communication between SuperLink and SuperNodes,
protecting model weights and gradients in transit.

**Auto-generated certificates (simplest):**

Set `ONEAPP_FL_TLS_ENABLED=YES` at the service level in the OneFlow template.
At boot, the SuperLink will:

1. Generate a self-signed CA certificate and private key.
2. Generate a server certificate signed by the CA, with the VM's IP as SAN.
3. Publish the CA certificate (base64-encoded) to OneGate as `FL_CA_CERT`.
4. Start the Flower container with `--ssl-ca-certfile`, `--ssl-certfile`,
   `--ssl-keyfile` instead of `--insecure`.

Each SuperNode will:

1. Detect `FL_TLS=YES` from the SuperLink's OneGate publication.
2. Retrieve `FL_CA_CERT` from OneGate.
3. Decode and validate the CA certificate.
4. Start the Flower container with `--root-certificates` pointing to the
   CA cert instead of `--insecure`.

No manual certificate distribution is needed.

**Operator-provided certificates:**

If you have your own PKI, base64-encode your certificates and set them in the
SuperLink role context:

```bash
ONEAPP_FL_SSL_CA_CERTFILE=$(base64 -w0 < your-ca.crt)
ONEAPP_FL_SSL_CERTFILE=$(base64 -w0 < your-server.pem)
ONEAPP_FL_SSL_KEYFILE=$(base64 -w0 < your-server.key)
```

The SuperLink will decode and validate the certificate chain at boot. On the
SuperNode side, set `ONEAPP_FL_SSL_CA_CERTFILE` to supply your CA certificate
directly (instead of retrieving it from OneGate).

**Verification:**

```bash
# Verify TLS is active on the SuperLink
ssh root@${SUPERLINK_IP} 'openssl s_client -connect localhost:9092 </dev/null 2>/dev/null | head -5'

# Check certificate details
ssh root@${SUPERLINK_IP} 'openssl s_client -connect localhost:9092 </dev/null 2>/dev/null | openssl x509 -noout -text | grep -A2 "Subject Alternative Name"'
```

**Spec:** [`../spec/04-tls-certificate-lifecycle.md`](../spec/04-tls-certificate-lifecycle.md),
[`../spec/05-supernode-tls-trust.md`](../spec/05-supernode-tls-trust.md)

### 10b. Enabling GPU Passthrough

GPU passthrough allows SuperNode containers to use NVIDIA GPUs for accelerated
training. This requires a four-layer configuration.

**Layer 1: Host prerequisites (infrastructure team, one-time)**

```bash
# Enable IOMMU in kernel (add to GRUB_CMDLINE_LINUX)
# For Intel CPUs:
GRUB_CMDLINE_LINUX="intel_iommu=on iommu=pt"

# For AMD CPUs:
GRUB_CMDLINE_LINUX="amd_iommu=on iommu=pt"

# Update GRUB and reboot
sudo update-grub && sudo reboot

# Bind GPU to vfio-pci driver
# Identify the GPU PCI ID
lspci -nn | grep -i nvidia
# Example output: 01:00.0 3D controller [0302]: NVIDIA ... [10de:2204]

# Bind to vfio-pci
echo "10de 2204" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id
```

**Layer 2: VM template (OpenNebula admin)**

Add PCI passthrough to the SuperNode VM template:

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

FEATURES = [
    IOTHREADS = "YES"
]
```

**Layer 3: Container runtime (built into the QCOW2 image)**

The NVIDIA Container Toolkit is pre-installed during image build. No
additional configuration is needed.

**Layer 4: Enable at deployment time**

Set these variables in the SuperNode role of the OneFlow template:

```
ONEAPP_FL_GPU_ENABLED=YES
ONEAPP_FL_CUDA_VISIBLE_DEVICES=all        # or "0" or "0,1"
ONEAPP_FL_GPU_MEMORY_FRACTION=0.8         # PyTorch memory limit (0.0-1.0)
```

**Verification:**

```bash
# Check GPU visibility inside the container
ssh root@${SUPERNODE_IP} 'docker exec flower-supernode nvidia-smi'

# Check boot log for GPU detection
ssh root@${SUPERNODE_IP} 'grep -i gpu /var/log/one-appliance/*.log'
```

**CPU fallback:** If `ONEAPP_FL_GPU_ENABLED=YES` but no GPU is detected at
boot (module not loaded, passthrough not configured), the appliance logs a
WARNING and continues with CPU-only training. Training will be slower but the
SuperNode remains functional.

**Spec:** [`../spec/10-gpu-passthrough.md`](../spec/10-gpu-passthrough.md)

### 10c. Enabling Monitoring

The monitoring stack provides two tiers of observability.

**Tier 1: Structured JSON Logging (zero infrastructure)**

Set at the service level:

```
ONEAPP_FL_LOG_FORMAT=json
```

All Flower log output becomes single-line JSON objects with structured
FL event data. Use with Docker's default `json-file` log driver and query
with `docker logs` or forward to any log aggregation system.

**Tier 2: Prometheus Metrics (requires monitoring infrastructure)**

Set on the SuperLink role:

```
ONEAPP_FL_METRICS_ENABLED=YES
ONEAPP_FL_METRICS_PORT=9101
```

The SuperLink exposes 11 FL training metrics on port 9101 (`/metrics`
endpoint). Configure your external Prometheus server to scrape this endpoint.

For GPU SuperNodes, enable the DCGM exporter:

```
ONEAPP_FL_DCGM_ENABLED=YES
```

This starts a sidecar container exposing 8 GPU metrics on port 9400.

**Quick test using the SuperLink's compose-based monitoring:**

The SuperLink image includes a Docker Compose file with optional Prometheus
and Grafana services:

```bash
ssh root@${SUPERLINK_IP}

# Start the monitoring stack alongside the existing SuperLink container
cd /opt/flower
docker compose -f /path/to/docker-compose.yml --profile flower-metrics up -d
```

This starts:
- Prometheus on port 9090 (scrapes the FL metrics exporter)
- Grafana on port 3000 (pre-configured dashboards)

**Spec:** [`../spec/13-monitoring-observability.md`](../spec/13-monitoring-observability.md)

### 10d. Scaling the SuperNode Role

OneFlow supports runtime scaling of the supernode role.

**Scale up:**

```bash
# Add more SuperNodes to a running cluster
oneflow scale <service_id> supernode 5
```

New SuperNodes boot, discover the SuperLink via OneGate, and connect
automatically. They participate in the next training round.

**Scale down:**

```bash
# Reduce SuperNode count
oneflow scale <service_id> supernode 3
```

OneFlow terminates the excess SuperNode VMs. The SuperLink detects the
disconnections and adjusts the participant pool for the next round.

**Cardinality constraints** (defined in the service template):

| Parameter   | Default | Description                            |
|-------------|---------|----------------------------------------|
| `min_vms`   | 2       | Minimum SuperNode count                |
| `max_vms`   | 10      | Maximum SuperNode count                |
| `cardinality` | 2     | Initial SuperNode count at deployment  |

Edit these in `flower-cluster.yaml` before registering the template.

---

## 11. Troubleshooting

### Boot Hangs or VM Never Reports READY

**Symptoms:** OneFlow shows the role stuck in `DEPLOYING`. The VM is
`RUNNING` in OpenNebula but the service does not progress.

**Check the boot logs:**

```bash
ssh root@<vm_ip> 'cat /var/log/one-appliance/*.log'
```

**Common causes:**

| Log message                              | Cause                               | Fix                                          |
|------------------------------------------|-------------------------------------|----------------------------------------------|
| `Docker daemon not available after 60s`  | Docker failed to start              | `systemctl status docker`, `journalctl -u docker` |
| `Configuration validation failed`        | Invalid context variable            | Check the specific variable in the error message |
| `SuperLink health check timed out`       | Container started but gRPC not listening | `docker logs flower-superlink`            |
| No log files at all                      | Contextualization did not run       | Check VM template CONTEXT section has `TOKEN=YES` |

### SuperNode Cannot Find SuperLink

**Symptoms:** SuperNode logs show `SuperLink discovery timed out after 30 attempts`.

**Checks:**

```bash
# 1. Verify OneGate connectivity from SuperNode VM
ssh root@<supernode_ip> 'curl -s http://169.254.16.9:5030/vm \
    -H "X-ONEGATE-TOKEN: $(cat /run/one-context/token.txt)" \
    -H "X-ONEGATE-VMID: $(source /run/one-context/one_env && echo $VMID)"'

# 2. Verify SuperLink published FL_ENDPOINT
onevm show <superlink_vm_id> | grep FL_ENDPOINT

# 3. Check that TOKEN=YES is in both VM template CONTEXT sections

# 4. For static addressing (bypass OneGate):
# Set ONEAPP_FL_SUPERLINK_ADDRESS=<superlink_ip>:9092 on the SuperNode
```

### TLS Errors

**Symptoms:** SuperNode logs show `SSL handshake failed` or
`UNAVAILABLE: Connection reset`.

**Checks:**

```bash
# Verify the SuperLink's certificate SAN includes its IP
ssh root@<superlink_ip> 'openssl x509 -in /opt/flower/certs/server.pem -noout -text | grep -A5 "Subject Alternative Name"'

# Verify the CA cert on SuperNode matches the SuperLink's CA
ssh root@<supernode_ip> 'openssl x509 -in /opt/flower/certs/ca.crt -noout -fingerprint'
ssh root@<superlink_ip> 'openssl x509 -in /opt/flower/certs/ca.crt -noout -fingerprint'
# Fingerprints must match

# Check both sides agree on TLS mode
ssh root@<superlink_ip> 'grep -i tls /var/log/one-appliance/*.log'
ssh root@<supernode_ip> 'grep -i tls /var/log/one-appliance/*.log'
```

**Common TLS issues:**

| Issue                             | Cause                                    | Fix                                          |
|-----------------------------------|------------------------------------------|----------------------------------------------|
| CA fingerprint mismatch           | SuperNode retrieved stale CA from OneGate | Redeploy the SuperNode VM                    |
| SAN does not contain VM IP        | SuperLink IP changed after cert generation | Redeploy SuperLink (certs are generated at boot) |
| One side insecure, other TLS      | `FL_TLS_ENABLED` not set at service level | Set `ONEAPP_FL_TLS_ENABLED` at service level |

### GPU Not Detected

**Symptoms:** SuperNode logs show `FL_GPU_ENABLED=YES but GPU not available`.

```bash
# Check host-level PCI passthrough
ssh root@<supernode_ip> 'lspci | grep -i nvidia'
# If empty: GPU not passed through to VM. Check VM template PCI section.

# Check NVIDIA driver
ssh root@<supernode_ip> 'lsmod | grep nvidia'
# If empty: NVIDIA driver not loaded. Check NVIDIA Container Toolkit install.

# Check nvidia-smi
ssh root@<supernode_ip> 'nvidia-smi'
# If "command not found": NVIDIA drivers not installed in VM image.
# If "No devices were found": PCI passthrough not configured correctly.

# Check vfio-pci binding on the host
lspci -k -s <gpu_pci_id>
# Kernel driver in use should be "vfio-pci"
```

### Docker Issues

```bash
# Check Docker daemon status
ssh root@<vm_ip> 'systemctl status docker'

# Check Docker logs
ssh root@<vm_ip> 'journalctl -u docker --no-pager -n 50'

# Check disk space (Docker needs space for layers)
ssh root@<vm_ip> 'df -h /'

# List Docker images (verify Flower images are present)
ssh root@<vm_ip> 'docker images | grep flwr'

# Clean up unused Docker resources
ssh root@<vm_ip> 'docker system prune -f'
```

### Container Keeps Restarting

```bash
# Check the systemd service status
ssh root@<vm_ip> 'systemctl status flower-superlink'
# or
ssh root@<vm_ip> 'systemctl status flower-supernode'

# Check container exit reason
ssh root@<vm_ip> 'docker inspect flower-superlink --format "{{.State.ExitCode}} {{.State.Error}}"'

# View recent container logs
ssh root@<vm_ip> 'docker logs flower-superlink --tail 50'
```

**Common restart causes:**

| Exit code | Cause                                  | Fix                                    |
|-----------|----------------------------------------|----------------------------------------|
| 137       | OOM killed (out of memory)             | Increase VM RAM                        |
| 1         | Application error                      | Check container logs for the error     |
| 126       | Permission denied on mounted volume    | Fix ownership: `chown 49999:49999`     |

---

## 12. File Reference

### Build Directory

| File                                       | Purpose                                              | Spec Reference                                         |
|--------------------------------------------|------------------------------------------------------|--------------------------------------------------------|
| `build/Makefile`                           | Build driver: targets for superlink, supernode, clean | --                                                     |
| `build/superlink/appliance.sh`             | SuperLink one-apps lifecycle script (install, configure, bootstrap) | [`../spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md) |
| `build/supernode/appliance.sh`             | SuperNode one-apps lifecycle script (install, configure, bootstrap) | [`../spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md) |
| `build/packer/superlink/superlink.pkr.hcl` | Packer template for SuperLink QCOW2 image           | [`../spec/01-superlink-appliance.md`](../spec/01-superlink-appliance.md) |
| `build/packer/superlink/variables.pkr.hcl` | Packer variables for SuperLink build                 | --                                                     |
| `build/packer/superlink/gen_context`       | Generates contextualization ISO for Packer SSH access | --                                                     |
| `build/packer/supernode/supernode.pkr.hcl` | Packer template for SuperNode QCOW2 image (20 GB disk) | [`../spec/02-supernode-appliance.md`](../spec/02-supernode-appliance.md) |
| `build/packer/supernode/variables.pkr.hcl` | Packer variables for SuperNode build                 | --                                                     |
| `build/packer/supernode/gen_context`       | Generates contextualization ISO for Packer SSH access | --                                                     |
| `build/packer/scripts/81-configure-ssh.sh` | SSH hardening provisioner (reverts build-time settings) | --                                                     |
| `build/packer/scripts/82-configure-context.sh` | Installs one-apps contextualization hooks         | --                                                     |
| `build/oneflow/flower-cluster.yaml`        | OneFlow service template (SuperLink + SuperNode roles) | [`../spec/08-single-site-orchestration.md`](../spec/08-single-site-orchestration.md) |
| `build/docker/superlink/docker-compose.yml` | Docker Compose for SuperLink with optional monitoring | [`../spec/13-monitoring-observability.md`](../spec/13-monitoring-observability.md) |
| `build/docker/supernode/docker-compose.yml` | Docker Compose for SuperNode                        | --                                                     |

### VM Internal Paths (After Boot)

| Path                                            | Component   | Purpose                                      |
|-------------------------------------------------|-------------|----------------------------------------------|
| `/etc/one-appliance/service`                    | Both        | one-apps lifecycle dispatcher                |
| `/etc/one-appliance/service.d/appliance.sh`     | Both        | Flower appliance lifecycle script            |
| `/opt/flower/scripts/health-check.sh`           | Both        | Readiness probe for REPORT_READY gating      |
| `/opt/flower/config/superlink.env`              | SuperLink   | Generated Docker environment file            |
| `/opt/flower/config/supernode.env`              | SuperNode   | Generated Docker environment file            |
| `/opt/flower/state/`                            | SuperLink   | SQLite state database (persists across restarts) |
| `/opt/flower/certs/`                            | Both        | TLS certificates (when TLS enabled)          |
| `/opt/flower/data/`                             | SuperNode   | Local training data mount point              |
| `/opt/flower/PREBAKED_VERSION`                  | Both        | Pre-baked Flower version for override detection |
| `/etc/systemd/system/flower-superlink.service`  | SuperLink   | Systemd unit for container lifecycle         |
| `/etc/systemd/system/flower-supernode.service`  | SuperNode   | Systemd unit for container lifecycle         |
| `/var/log/one-appliance/flower-configure.log`   | Both        | Boot-time configuration log                  |
| `/var/log/one-appliance/flower-bootstrap.log`   | Both        | Boot-time bootstrap log                      |
| `/run/one-context/one_env`                      | Both        | OpenNebula context variables                 |
| `/run/one-context/token.txt`                    | Both        | OneGate authentication token                 |

### Spec Documents

| File                                        | Content                                              |
|---------------------------------------------|------------------------------------------------------|
| `spec/00-overview.md`                       | Architecture overview, design principles, roadmap    |
| `spec/01-superlink-appliance.md`            | SuperLink: boot sequence, Docker config, OneGate     |
| `spec/02-supernode-appliance.md`            | SuperNode: discovery model, GPU detection, health    |
| `spec/03-contextualization-reference.md`    | All 48 context variables with validation rules       |
| `spec/04-tls-certificate-lifecycle.md`      | TLS: CA generation, cert signing, OneGate publish    |
| `spec/05-supernode-tls-trust.md`            | TLS: CA retrieval, trust modes, handshake walkthrough |
| `spec/06-ml-framework-variants.md`          | PyTorch, TensorFlow, scikit-learn image variants     |
| `spec/07-use-case-templates.md`             | Pre-built Flower App Bundles                         |
| `spec/08-single-site-orchestration.md`      | OneFlow template, deployment sequencing, scaling     |
| `spec/09-training-configuration.md`         | Aggregation strategies, checkpointing, failure recovery |
| `spec/10-gpu-passthrough.md`                | NVIDIA GPU passthrough four-layer stack              |
| `spec/12-multi-site-federation.md`          | Cross-zone deployment, WireGuard, gRPC keepalive     |
| `spec/13-monitoring-observability.md`       | JSON logging, Prometheus metrics, Grafana dashboards |
| `spec/14-edge-and-auto-scaling.md`          | Edge SuperNode variant, OneFlow elasticity policies  |
