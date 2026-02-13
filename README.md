# Flower + OpenNebula

> Privacy-preserving federated learning as a one-click cloud appliance.

[![Flower](https://img.shields.io/badge/Flower-1.25.0-blue)](https://flower.ai/)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-7.0+-brightgreen)](https://opennebula.io/)
[![License](https://img.shields.io/badge/License-Apache_2.0-orange)](LICENSE)

## What Is This?

Pre-built OpenNebula marketplace appliances that deploy a [Flower](https://flower.ai/) federated learning cluster. Set context variables, click deploy, run training -- raw data never leaves its source VM.

## Architecture

```
  ┌─────────────────────────────────────────────────────┐
  │                 OpenNebula Cloud                     │
  │                                                     │
  │    ┌──────────────┐                                 │
  │    │  SuperLink   │  Coordinates rounds,            │
  │    │  (1 VM)      │  aggregates model weights       │
  │    │  :9092 Fleet │                                 │
  │    │  :9093 Ctrl  │                                 │
  │    └──────┬───────┘                                 │
  │           │ gRPC (weights only, ~3.5 MB/round)      │
  │     ┌─────┴─────┐                                   │
  │     │           │                                   │
  │  ┌──▼───────┐ ┌─▼────────┐                          │
  │  │SuperNode │ │SuperNode │  Train locally on        │
  │  │  VM #1   │ │  VM #2   │  private data            │
  │  │ [data]   │ │ [data]   │                          │
  │  └──────────┘ └──────────┘                          │
  └─────────────────────────────────────────────────────┘
```

Each appliance is a QCOW2 image: Ubuntu 24.04 + Docker + pre-pulled Flower containers. At boot, OpenNebula contextualization injects config and the appliance self-configures. SuperNodes discover the SuperLink automatically via OneGate.

The SuperNode image includes **PyTorch, TensorFlow, and scikit-learn** -- set `ONEAPP_FL_FRAMEWORK` to select one at deployment time.

## Quick Start

### Prerequisites

- OpenNebula 7.0+ with CLI access (`oneimage`, `onetemplate`, `oneflow-template`)
- Python 3.11+ on the frontend (for `flwr run`)
- SSH public key in your OpenNebula user profile
- Appliance images in a datastore (import from marketplace or [build from source](#building-from-source))

### Step 1: Import Appliances

**From the marketplace** (recommended): Sunstone -> Storage -> Apps -> "Flower FL 1.25.0" -> Export. This imports images, VM templates, and the OneFlow service template automatically.

**From source**: see [Building from Source](#building-from-source) below.

### Step 2: Deploy the Cluster

```bash
# Register the OneFlow service template (if built from source)
oneflow-template create build/oneflow/flower-cluster.yaml

# Deploy -- SuperLink boots first, then SuperNodes auto-discover via OneGate
oneflow-template instantiate <service-template-id>

# Monitor until RUNNING
watch -n 5 oneflow show <service-id>

# Get the SuperLink IP
SUPERLINK_IP=$(oneflow show <service-id> --json | \
    jq -r '.DOCUMENT.TEMPLATE.BODY.roles[] |
    select(.name=="superlink") | .nodes[0].vm_info.VM.TEMPLATE.NIC[0].IP')
```

To select a framework at deployment: `--user_inputs '{"ONEAPP_FL_ML_FRAMEWORK": "pytorch"}'`

### Step 3: Run Federated Training

Three framework demos are included, each training a CIFAR-10 classifier with FedAvg:

| Demo | Model | Params | Framework |
|------|-------|--------|-----------|
| `demo/pytorch/` | SimpleCNN (Conv->Conv->FC->FC) | ~878K | PyTorch 2.6.0 |
| `demo/tensorflow/` | Sequential CNN (Keras) | ~880K | TensorFlow 2.18.1 |
| `demo/sklearn/` | MLPClassifier (3072->512->10) | ~1.6M | scikit-learn 1.4+ |

Pick the framework matching your SuperNodes' `ONEAPP_FL_FRAMEWORK`:

```bash
cd demo/pytorch       # or demo/tensorflow, demo/sklearn
python3 -m venv .venv && source .venv/bin/activate
pip install -e .

# Edit pyproject.toml: set address = "<superlink-ip>:9093"
flwr run . opennebula
```

`flwr run` ships code as a FAB bundle to the SuperLink, which distributes it to SuperNodes. Change Python code and re-run -- no Docker rebuild needed.

**Local simulation** (no cluster needed): `flwr run . local-sim`

### Step 4: Monitor with Dashboard

```bash
cd dashboard && pip install fastapi uvicorn
python -m uvicorn app:app --host 0.0.0.0 --port 8080
# Open http://<frontend-ip>:8080
```

Animated SVG cluster topology, per-round training metrics, node health, dark/light mode.

## Validated Results

3 rounds of FedAvg on CIFAR-10, 1 SuperLink + 2 SuperNodes (2 vCPU / 4 GB each):

```
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

Loss dropped **1.27 -> 0.94** across 3 rounds. Only model weights (~3.5 MB/round) crossed the network -- raw images never left their VMs.

## Multi-Site Deployment

In production, each SuperNode sits in a different organization's LAN. [Tailscale](https://tailscale.com/) makes cross-site connectivity trivial -- it's a mesh VPN built on WireGuard with automatic NAT traversal.

```
Hospital A                         Hospital B                      Hospital C
┌──────────────┐                   ┌──────────────┐                ┌──────────────┐
│ SuperLink    │                   │ SuperNode #1 │                │ SuperNode #2 │
│ ts: 100.x.a  │◄── tailnet ────► │ ts: 100.x.b  │◄── mesh ────► │ ts: 100.x.c  │
└──────────────┘   (encrypted)     └──────────────┘                └──────────────┘
```

**Setup on each VM:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-<YOUR_KEY> --hostname=flower-superlink  # or flower-supernode-N
tailscale ip -4   # note the 100.x.y.z IP
```

**Configure SuperNodes** to use the SuperLink's Tailscale IP (OneGate is zone-local, can't do cross-site discovery):

```
ONEAPP_FL_SUPERLINK_ADDRESS = 100.x.a:9092
```

**TLS is optional** with Tailscale -- traffic is already WireGuard-encrypted. For compliance, set `ONEAPP_FL_TLS_ENABLED=YES` and add `ONEAPP_FL_CERT_EXTRA_SAN=IP:<tailscale-ip>` on the SuperLink.

**Tailscale ACLs** for production:

```bash
tailscale up --authkey=tskey-auth-<KEY> --advertise-tags=tag:superlink   # on SuperLink
tailscale up --authkey=tskey-auth-<KEY> --advertise-tags=tag:supernode   # on SuperNodes
```

Then restrict access in the Tailscale admin console so only `tag:supernode` can reach `tag:superlink:9092,9093`.

> For raw WireGuard or public IP setups, see [spec/12-multi-site-federation.md](spec/12-multi-site-federation.md).

## Customization

- **TLS encryption** -- `ONEAPP_FL_TLS_ENABLED=YES`. Auto-generates self-signed CA, or bring your own. See [spec/04-tls-certificate-lifecycle.md](spec/04-tls-certificate-lifecycle.md).
- **GPU passthrough** -- `ONEAPP_FL_GPU_ENABLED=YES` on SuperNodes with PCI-passthrough GPUs. Requires host IOMMU. See [spec/10-gpu-passthrough.md](spec/10-gpu-passthrough.md).
- **Scaling** -- `oneflow scale <service-id> supernode 5`. New nodes join automatically.
- **Aggregation strategies** -- FedAvg (default), FedProx, FedAdam, and more. See [Aggregation Strategies](#aggregation-strategies) below.
- **Edge deployment** -- Lightweight SuperNodes (<2 GB) on intermittent WAN. See [spec/14-edge-and-auto-scaling.md](spec/14-edge-and-auto-scaling.md).
- **All context variables** -- 48 variables with validation rules. See [spec/03-contextualization-reference.md](spec/03-contextualization-reference.md).

<details>
<summary><strong>Aggregation Strategies</strong></summary>

All demos use **FedAvg** by default. Swap strategies in `server_app.py` by changing one import -- no client-side changes needed.

**FedAvg** -- Weighted average of client weights proportional to dataset size. Simple, fast, works well with IID data.

```python
from flwr.server.strategy import FedAvg
strategy = FedAvg(fraction_fit=1.0, min_fit_clients=2, min_available_clients=2)
```

**FedProx** -- Adds a proximal term penalizing divergence from the global model. Better with non-IID data.

```python
from flwr.server.strategy import FedProx
strategy = FedProx(fraction_fit=1.0, min_fit_clients=2, min_available_clients=2, proximal_mu=0.1)
```

**FedAdam** -- Server-side Adam optimizer on aggregated updates. Faster convergence, more hyperparameters.

```python
from flwr.server.strategy import FedAdam
strategy = FedAdam(fraction_fit=1.0, min_fit_clients=2, min_available_clients=2,
                   eta=0.01, tau=0.1, beta_1=0.9, beta_2=0.99)
```

| | FedAvg | FedProx | FedAdam |
|---|---|---|---|
| **Best for** | IID data, simple setups | Non-IID data, stragglers | Large-scale, many rounds |
| **Extra hyperparams** | None | `mu` | `eta`, `tau`, `beta_1`, `beta_2` |
| **Complexity** | Lowest | Low | Medium |

</details>

## Building from Source

<details>
<summary><strong>Build QCOW2 images with Packer</strong></summary>

### Prerequisites

- x86_64 with KVM support, 30 GB free disk, 4 GB RAM
- Packer >= 1.9, QEMU/KVM, genisoimage, jq, make
- [one-apps](https://github.com/OpenNebula/one-apps) framework checkout
- Ubuntu 24.04 base QCOW2 image

```bash
# Install build tools
sudo apt-get install packer qemu-system-x86 qemu-utils genisoimage jq make

# Clone one-apps
git clone https://github.com/OpenNebula/one-apps.git
```

### Build

```bash
cd build

# Build both images
make all INPUT_DIR=./images ONE_APPS_DIR=../../one-apps

# Or individually
make flower-superlink INPUT_DIR=./images ONE_APPS_DIR=../../one-apps   # ~15 min, 10 GB disk
make flower-supernode INPUT_DIR=./images ONE_APPS_DIR=../../one-apps   # ~20 min, 20 GB disk

# Validate scripts before building
make validate
```

Output: `build/export/flower-superlink.qcow2` and `build/export/flower-supernode.qcow2`

> The SuperNode image uses custom Docker images from `python:3.12-slim` (not the upstream Alpine image) because PyTorch requires glibc. Three images are built: pytorch, tensorflow, sklearn. All pin `numpy==1.26.4` and `flwr==1.25.0`.

### Upload to OpenNebula

```bash
# Copy to /var/tmp (RESTRICTED_DIRS blocks /root)
cp build/export/*.qcow2 /var/tmp/

oneimage create --name "Flower SuperLink v1.25.0" \
    --path /var/tmp/flower-superlink.qcow2 --type OS --driver qcow2 --datastore default

oneimage create --name "Flower SuperNode v1.25.0" \
    --path /var/tmp/flower-supernode.qcow2 --type OS --driver qcow2 --datastore default

# Wait for READY
watch -n 5 'oneimage list | grep Flower'
```

### Create VM Templates

```bash
cat > /tmp/superlink.tmpl <<'EOF'
NAME = "Flower SuperLink"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperLink v1.25.0" ]
NIC = [ NETWORK = "<your-vnet-name>" ]
CONTEXT = [
  TOKEN = "YES", NETWORK = "YES", REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
onetemplate create /tmp/superlink.tmpl

cat > /tmp/supernode.tmpl <<'EOF'
NAME = "Flower SuperNode"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperNode v1.25.0" ]
NIC = [ NETWORK = "<your-vnet-name>" ]
CONTEXT = [
  TOKEN = "YES", NETWORK = "YES", REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
onetemplate create /tmp/supernode.tmpl
```

Then register the OneFlow service template: `oneflow-template create build/oneflow/flower-cluster.yaml`

</details>

## Project Structure

```
flower-opennebula/
  build/
    superlink/appliance.sh        # SuperLink lifecycle script
    supernode/appliance.sh        # SuperNode lifecycle script
    packer/                       # Packer templates for QCOW2 image builds
    docker/                       # Docker Compose stacks for each role
    oneflow/flower-cluster.yaml   # OneFlow service template
    Makefile                      # Build driver
  marketplace/                    # OpenNebula marketplace appliance YAML files
  dashboard/
    app.py                        # FastAPI real-time monitoring dashboard
    static/index.html             # Tailwind CSS frontend with SVG topology
  demo/
    pytorch/                      # PyTorch CIFAR-10 demo (Flower App)
    tensorflow/                   # TensorFlow CIFAR-10 demo (Flower App)
    sklearn/                      # scikit-learn CIFAR-10 demo (Flower App)
  spec/                           # Technical specification (15 documents)
```

<details>
<summary><strong>Troubleshooting</strong></summary>

### Deployment

| Problem | Fix |
|---------|-----|
| VM stuck in `BOOT` | Check `onevm show <id>` for CONTEXT errors. Ensure `NETWORK=YES`. |
| VMs unreachable from frontend | Assign gateway IP to bridge: `ip addr add <gw>/24 dev <bridge>` + NAT rule. |
| SSH host key mismatch | `ssh-keygen -R <vm-ip>` (normal after image rebuild). |
| Image upload fails | `RESTRICTED_DIRS` blocks `/root`. Copy to `/var/tmp/` first. |

### Cluster

| Problem | Fix |
|---------|-----|
| SuperNode can't find SuperLink | Check `onevm show <superlink-id> \| grep FL_ENDPOINT`. Verify same network. |
| `flwr run` connection refused | Address should be `<superlink-ip>:9093` in `pyproject.toml`. Check SSH tunnel if remote. |
| `bytes_sent/bytes_recv cannot be zero` | Clear state: `ssh root@<superlink> "systemctl stop flower-superlink && rm -f /opt/flower/state/state.db && systemctl start flower-superlink"`. Restart all SuperNodes after. |
| SuperNodes stuck after SuperLink restart | Must restart SuperNodes too: `ssh root@<ip> systemctl restart flower-supernode` |
| Container keeps restarting (exit 137) | OOM -- increase VM RAM. |

### Multi-Site (Tailscale)

| Problem | Fix |
|---------|-----|
| `tailscale up` hangs | Needs HTTPS outbound to coordination servers. |
| Nodes don't see each other | Verify same tailnet: `tailscale status` on both. |
| High latency | `tailscale netcheck` -- open UDP 41641 for direct connections. |
| TLS SAN mismatch | `ONEAPP_FL_CERT_EXTRA_SAN=IP:<tailscale-ip>` on SuperLink, or skip TLS. |

</details>

## Spec Documents

The `spec/` directory contains the full technical specification (15 documents, ~11,500 lines) covering every design decision:

| Spec | Content |
|------|---------|
| [00-overview](spec/00-overview.md) | Architecture, design principles |
| [01-superlink-appliance](spec/01-superlink-appliance.md) | SuperLink boot sequence, Docker config |
| [02-supernode-appliance](spec/02-supernode-appliance.md) | SuperNode discovery, GPU detection |
| [03-contextualization-reference](spec/03-contextualization-reference.md) | All 48 context variables |
| [04-tls-certificate-lifecycle](spec/04-tls-certificate-lifecycle.md) | CA generation, cert signing |
| [06-ml-framework-variants](spec/06-ml-framework-variants.md) | PyTorch, TensorFlow, scikit-learn |
| [08-single-site-orchestration](spec/08-single-site-orchestration.md) | OneFlow template, scaling |
| [10-gpu-passthrough](spec/10-gpu-passthrough.md) | NVIDIA GPU four-layer stack |
| [12-multi-site-federation](spec/12-multi-site-federation.md) | Cross-zone WireGuard, gRPC keepalive |

## License

Apache 2.0

---

*Built by the Cloud-Edge Innovation team at OpenNebula Systems, 2026.*
