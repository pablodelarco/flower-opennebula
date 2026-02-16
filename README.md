# Flower + OpenNebula

> Train a shared model across multiple sites without moving raw data. One-click deploy on OpenNebula.

[![Flower](https://img.shields.io/badge/Flower-1.25.0-blue)](https://flower.ai/)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-7.0+-brightgreen)](https://opennebula.io/)
[![License](https://img.shields.io/badge/License-Apache_2.0-orange)](LICENSE)

Pre-built OpenNebula marketplace appliances that deploy a [Flower](https://flower.ai/) federated learning cluster. Each node trains on its own private data (hospital scans, factory sensors, user devices) and only shares model weight updates (~3.5 MB/round) — raw data never leaves its source VM.

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

SuperNode images include **PyTorch, TensorFlow, and scikit-learn** — set `ONEAPP_FL_FRAMEWORK` to pick one at deploy time.

**Validated:** 3 rounds of FedAvg on CIFAR-10, 2 SuperNodes (2 vCPU / 4 GB each) — loss dropped **1.27 → 0.94**. Only model weights crossed the network.

## Quick Start

**Prerequisites:** OpenNebula 7.0+ with CLI access, Python 3.11+, SSH key in your OpenNebula profile.

### Step 1: Import Appliances

**From the marketplace** (recommended): FireEdge → Storage → Apps → "Flower FL 1.25.0" → Export.

**From source**: see [Building from Source](#building-from-source) below.

### Step 2: Deploy the Cluster

```bash
# Deploy — SuperLink boots first, SuperNodes auto-discover via OneGate
oneflow-template instantiate <service-template-id>

# Monitor until RUNNING
watch -n 5 oneflow show <service-id>
```

To select a framework: `--user_inputs '{"ONEAPP_FL_FRAMEWORK": "pytorch"}'`

### Step 3: Run Federated Training

The cluster is now running but idle. The quickstart script handles the rest — finds your cluster, sets up Python, patches the config, and runs training:

```bash
bash demo/quickstart.sh
```

Options: `--skip-cluster` (local simulation only), `--superlink IP:PORT` (skip discovery), `--auto` (non-interactive). Run `--help` for details.

<details>
<summary><strong>Manual steps</strong> (if you prefer not to use the quickstart)</summary>

You need Python 3.11+ and `flwr` CLI (`pip install flwr`) on your local machine.

Three included demos, each training a CIFAR-10 classifier with FedAvg:

| Demo | Model | Framework |
|------|-------|-----------|
| `demo/pytorch/` | SimpleCNN (~878K params) | PyTorch 2.6.0 |
| `demo/tensorflow/` | Sequential CNN (~880K) | TensorFlow 2.18.1 |
| `demo/sklearn/` | MLPClassifier (~1.6M) | scikit-learn 1.4+ |

```bash
cd demo/pytorch       # or demo/tensorflow, demo/sklearn
python3 -m venv .venv && source .venv/bin/activate
pip install -e .

# Edit pyproject.toml: set address = "<superlink-ip>:9093"
flwr run . opennebula
```

`flwr run` packages your code into a FAB, uploads it to the SuperLink, which distributes it to every SuperNode. Change code and re-run — no Docker rebuild needed.

**Local simulation** (no cluster needed): `flwr run . local-sim`

</details>

## Going Further

<details>
<summary><strong>Bring your own data</strong></summary>

The demos auto-download CIFAR-10 — convenient for testing, but not production FL.

Pre-provision each SuperNode with its own data partition:

```bash
scp -r ./hospital_a_scans/ root@<supernode-1-ip>:/opt/flower/data/
scp -r ./hospital_b_scans/ root@<supernode-2-ip>:/opt/flower/data/
```

Data is mounted read-only into the container at `/app/data`. Modify your `client_app.py` to load from there:

```python
import os
from torchvision import datasets, transforms

data_dir = os.environ.get("FL_DATA_DIR", "/app/data")
train_dataset = datasets.ImageFolder(data_dir, transform=transforms.ToTensor())
```

Each SuperNode gets different data — the model learns across sites without data moving.

</details>

<details>
<summary><strong>Retrieve the trained model</strong></summary>

Training loss and accuracy print directly in `flwr run` output. For persisting checkpoints:

1. Set `ONEAPP_FL_CHECKPOINT_ENABLED=YES` on the SuperLink VM
2. After training: `scp root@<superlink-ip>:/opt/flower/checkpoints/checkpoint_latest.npz ./`

</details>

<details>
<summary><strong>Multi-site deployment (Tailscale)</strong></summary>

In production, SuperNodes sit in different organizations' LANs. [Tailscale](https://tailscale.com/) (WireGuard mesh VPN) makes cross-site connectivity trivial:

```
Hospital A                         Hospital B                      Hospital C
┌──────────────┐                   ┌──────────────┐                ┌──────────────┐
│ SuperLink    │                   │ SuperNode #1 │                │ SuperNode #2 │
│ ts: 100.x.a  │◄── tailnet ────► │ ts: 100.x.b  │◄── mesh ────► │ ts: 100.x.c  │
└──────────────┘   (encrypted)     └──────────────┘                └──────────────┘
```

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-<YOUR_KEY> --hostname=flower-superlink
```

Set `ONEAPP_FL_SUPERLINK_ADDRESS = 100.x.a:9092` on SuperNodes (OneGate is zone-local).

TLS is optional with Tailscale (traffic is already WireGuard-encrypted). For compliance: `ONEAPP_FL_TLS_ENABLED=YES` + `ONEAPP_FL_CERT_EXTRA_SAN=IP:<tailscale-ip>`.

See [spec/12-multi-site-federation.md](spec/12-multi-site-federation.md) for raw WireGuard or public IP setups.

</details>

<details>
<summary><strong>Monitoring dashboard</strong></summary>

```bash
cd dashboard && pip install fastapi uvicorn
python -m uvicorn app:app --host 0.0.0.0 --port 8080
```

Animated SVG cluster topology, per-round metrics, node health, dark/light mode.

</details>

<details>
<summary><strong>Customization</strong></summary>

- **TLS** — `ONEAPP_FL_TLS_ENABLED=YES`. Auto-generates self-signed CA, or bring your own. See [spec/04](spec/04-tls-certificate-lifecycle.md).
- **GPU passthrough** — `ONEAPP_FL_GPU_ENABLED=YES` on SuperNodes with PCI-passthrough. See [spec/10](spec/10-gpu-passthrough.md).
- **Scaling** — `oneflow scale <service-id> supernode 5`. New nodes join automatically.
- **Edge** — Lightweight SuperNodes (<2 GB) on intermittent WAN. See [spec/14](spec/14-edge-and-auto-scaling.md).
- **All 48 context variables** — [spec/03](spec/03-contextualization-reference.md).

**Aggregation strategies** — swap in `server_app.py` (no client-side changes):

| | FedAvg (default) | FedProx | FedAdam |
|---|---|---|---|
| **Best for** | IID data | Non-IID data | Large-scale |
| **Extra params** | None | `proximal_mu` | `eta`, `tau`, `beta_1`, `beta_2` |

</details>

<details>
<summary><strong>Building from source</strong></summary>

**Requires:** x86_64 with KVM, 30 GB disk, Packer >= 1.9, QEMU/KVM, genisoimage, jq, make.

```bash
cd build

# Build both images
make all INPUT_DIR=./images ONE_APPS_DIR=../../one-apps

# Or individually
make flower-superlink INPUT_DIR=./images ONE_APPS_DIR=../../one-apps   # ~15 min
make flower-supernode INPUT_DIR=./images ONE_APPS_DIR=../../one-apps   # ~20 min
```

Output: `build/export/flower-superlink.qcow2` and `build/export/flower-supernode.qcow2`

Upload to OpenNebula:

```bash
cp build/export/*.qcow2 /var/tmp/   # RESTRICTED_DIRS blocks /root

oneimage create --name "Flower SuperLink v1.25.0" \
    --path /var/tmp/flower-superlink.qcow2 --type OS --driver qcow2 --datastore default

oneimage create --name "Flower SuperNode v1.25.0" \
    --path /var/tmp/flower-supernode.qcow2 --type OS --driver qcow2 --datastore default
```

Then register the OneFlow service: `oneflow-template create build/oneflow/flower-cluster.yaml`

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

| Problem | Fix |
|---------|-----|
| VM stuck in `BOOT` | Check `onevm show <id>` for CONTEXT errors. Ensure `NETWORK=YES`. |
| VMs unreachable from frontend | Assign gateway IP to bridge + NAT rule. |
| SuperNode can't find SuperLink | Verify same network. Check `onevm show <superlink-id>`. |
| `flwr run` connection refused | Address = `<superlink-ip>:9093` in `pyproject.toml`. |
| `bytes_sent/bytes_recv cannot be zero` | Clear state: stop SuperLink, `rm /opt/flower/state/state.db`, restart all. |
| Container exit 137 | OOM — increase VM RAM. |
| Tailscale nodes don't see each other | Verify same tailnet: `tailscale status` on both. |

</details>

## Project Structure

```
build/          Packer images, Docker stacks, OneFlow template, Makefile
appliances/     OpenNebula marketplace appliance files
dashboard/      FastAPI monitoring dashboard with SVG topology
demo/           PyTorch, TensorFlow, scikit-learn CIFAR-10 demos
spec/           Technical specification (15 documents, ~11.5K lines)
```

## License

Apache 2.0. Built by the Cloud-Edge Innovation team at [OpenNebula Systems](https://opennebula.io), 2026.
