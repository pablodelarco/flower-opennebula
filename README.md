# Flower + OpenNebula

> Privacy-preserving federated learning as a one-click cloud appliance.

[![Flower](https://img.shields.io/badge/Flower-1.25.0-blue)](https://flower.ai/)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-7.0+-brightgreen)](https://opennebula.io/)
[![License](https://img.shields.io/badge/License-Apache_2.0-orange)](LICENSE)

## What Is This?

Pre-built OpenNebula marketplace appliances that deploy a [Flower](https://flower.ai/) federated learning cluster. Set context variables, click deploy, run training — raw data never leaves its source VM.

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

The SuperNode image includes **PyTorch, TensorFlow, and scikit-learn** — set `ONEAPP_FL_FRAMEWORK` to select one at deployment time.

## Quick Start

Full step-by-step: [tutorial/QUICKSTART.md](tutorial/QUICKSTART.md) | Build from source: [tutorial/BUILD.md](tutorial/BUILD.md)

### Prerequisites

- OpenNebula 7.0+ with CLI access (`oneimage`, `onetemplate`, `oneflow-template`)
- Python 3.11+ on the frontend (for `flwr run`)
- SSH public key in your OpenNebula user profile
- Appliance images uploaded to a datastore ([build guide](tutorial/BUILD.md) or import from marketplace)

### Step 1: Deploy the Cluster

```bash
# Import from marketplace: Sunstone → Storage → Apps → "Flower FL 1.25.0" → Export
# Or build from source: cd build && make all

# Register and instantiate the OneFlow service
oneflow-template create build/oneflow/flower-cluster.yaml
oneflow-template instantiate <service-template-id>
```

OneFlow boots the SuperLink first, waits for `READY`, then starts SuperNodes which auto-discover the SuperLink via OneGate.

```bash
# Monitor until RUNNING
watch -n 5 oneflow show <service-id>

# Get the SuperLink IP
SUPERLINK_IP=$(oneflow show <service-id> --json | \
    jq -r '.DOCUMENT.TEMPLATE.BODY.roles[] |
    select(.name=="superlink") | .nodes[0].vm_info.VM.TEMPLATE.NIC[0].IP')
```

### Step 2: Run Federated Training

Three framework demos are included — each trains a CIFAR-10 classifier using FedAvg:

| Demo | Model | Params | Framework |
|------|-------|--------|-----------|
| `demo/pytorch/` | SimpleCNN (Conv→Conv→FC→FC) | ~878K | PyTorch 2.6.0 |
| `demo/tensorflow/` | Sequential CNN (Keras) | ~880K | TensorFlow 2.18.1 |
| `demo/sklearn/` | MLPClassifier (3072→512→10) | ~1.6M | scikit-learn 1.4+ |

Pick the framework matching your SuperNodes' `ONEAPP_FL_FRAMEWORK`:

```bash
cd demo/pytorch       # or demo/tensorflow, demo/sklearn
python3 -m venv .venv && source .venv/bin/activate
pip install -e .

# Edit pyproject.toml: set address = "<superlink-ip>:9093"
flwr run . opennebula
```

### Step 3: Monitor with Dashboard

```bash
cd dashboard && pip install fastapi uvicorn
python -m uvicorn app:app --host 0.0.0.0 --port 8080
# Open http://<frontend-ip>:8080
```

The dashboard shows an animated SVG cluster topology, per-round training metrics, node health, and dark/light mode.

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

Loss dropped **1.27 → 0.94** across 3 rounds. Only model weights (~3.5 MB/round) crossed the network — raw images never left their VMs.

## Customization

- **TLS encryption** — Set `ONEAPP_FL_TLS_ENABLED=YES`. Auto-generates self-signed CA, or bring your own PKI. See [spec/04-tls-certificate-lifecycle.md](spec/04-tls-certificate-lifecycle.md).
- **GPU passthrough** — Set `ONEAPP_FL_GPU_ENABLED=YES` on SuperNodes with PCI-passthrough GPUs. See [spec/10-gpu-passthrough.md](spec/10-gpu-passthrough.md).
- **Scaling** — `oneflow scale <service-id> supernode 5`. New nodes join automatically.
- **Aggregation strategies** — FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg. See [demo/README.md](demo/README.md).
- **Multi-site federation** — Connect SuperNodes across sites with [Tailscale](tutorial/MULTI-SITE.md) (easy) or [WireGuard](spec/12-multi-site-federation.md) (manual).
- **Edge deployment** — Lightweight SuperNodes (<2 GB) on intermittent WAN. See [spec/14-edge-and-auto-scaling.md](spec/14-edge-and-auto-scaling.md).
- **All context variables** — 48 variables with validation rules. See [spec/03-contextualization-reference.md](spec/03-contextualization-reference.md).

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
    setup/                        # Cluster verification and preparation scripts
  spec/                           # Technical specification (15 documents)
  tutorial/
    QUICKSTART.md                 # 15-minute deployment guide
    BUILD.md                      # Build from source with Packer
```

<details>
<summary><strong>Troubleshooting</strong></summary>

| Problem | Fix |
|---------|-----|
| VM stuck in `BOOT` | Check `onevm show <id>` for CONTEXT errors. Ensure `NETWORK=YES`. |
| VMs unreachable from frontend | Assign gateway IP to the bridge: `ip addr add <gw>/24 dev <bridge>` and add NAT. |
| SSH host key mismatch after rebuild | `ssh-keygen -R <vm-ip>` |
| SuperNode can't find SuperLink | Verify `FL_ENDPOINT` published: `onevm show <superlink-id> \| grep FL_ENDPOINT`. Check both VMs on same network. |
| `flwr run` connection refused | Ensure address is `<superlink-ip>:9093` in `pyproject.toml`. Check SSH tunnel if remote. |
| `bytes_sent/bytes_recv cannot be zero` | Clear state: `ssh root@<superlink> "systemctl stop flower-superlink && rm -f /opt/flower/state/state.db && systemctl start flower-superlink"`. Then restart all SuperNodes. |
| SuperNodes stuck after SuperLink restart | Must also restart SuperNodes: `ssh root@<ip> systemctl restart flower-supernode` |

Full troubleshooting: [tutorial/QUICKSTART.md](tutorial/QUICKSTART.md#troubleshooting) | [tutorial/BUILD.md](tutorial/BUILD.md#12-troubleshooting)

</details>

## Documentation

| Resource | Description |
|----------|-------------|
| [tutorial/QUICKSTART.md](tutorial/QUICKSTART.md) | Step-by-step deployment in 15 minutes |
| [tutorial/BUILD.md](tutorial/BUILD.md) | Build appliance images from source with Packer |
| [tutorial/MULTI-SITE.md](tutorial/MULTI-SITE.md) | Multi-site federation with Tailscale |
| [demo/README.md](demo/README.md) | Framework demos and aggregation strategies |
| [spec/](spec/) | Full technical specification (15 documents, ~11,500 lines) |

## License

Apache 2.0

---

*Built by the Cloud-Edge Innovation team at OpenNebula Systems, 2026.*
