# Flower + OpenNebula

> Train one shared model across many sites without moving the data. Deploy a [Flower](https://flower.ai/) federated learning cluster on OpenNebula in a few clicks.

[![Flower](https://img.shields.io/badge/Flower-1.31.0-blue)](https://flower.ai/)
[![OpenNebula](https://img.shields.io/badge/OpenNebula-6.8+-brightgreen)](https://opennebula.io/)
[![License](https://img.shields.io/badge/License-Apache_2.0-orange)](LICENSE)

Each node trains on its own private data (hospital scans, factory sensors, user devices) and shares only model weight updates. Raw data never leaves the VM it lives on. This repo ships two OpenNebula marketplace appliances and a OneFlow service that wire a Flower cluster together for you, hardened and TLS-encrypted by default.

```
                       OpenNebula  (one shared private network)

                        ┌──────────────────────────┐
                        │        SuperLink          │   coordinates rounds,
                        │   1 VM · 4 GB · 2 vCPU     │   aggregates weights
                        │                           │
                        │   :9092  Fleet API ───────┼──► SuperNodes connect in
                        │   :9093  Control API      │    (private NIC, TLS)
                        │          (localhost only) │
                        └─────────────┬─────────────┘
                          weights only │  (a few MB / round)
                    ┌─────────────────┴─────────────────┐
                    │                                   │
           ┌────────▼─────────┐               ┌─────────▼────────┐
           │    SuperNode     │               │    SuperNode     │
           │  8 GB · 2 vCPU   │      ...       │  8 GB · 2 vCPU   │   2-10 nodes,
           │  trains locally  │               │  trains locally  │   auto-scaling
           │  [private data]  │               │  [private data]  │
           └──────────────────┘               └──────────────────┘
```

The **SuperLink** boots first, generates its TLS certificate, and announces itself through OneGate. The **SuperNodes** boot next, auto-discover the SuperLink, fetch its CA certificate, and connect. You then push training code with `flwr run`; the SuperLink distributes it to every SuperNode. No data ever crosses the wire, only model weights.

## What you get

| Component | Version | Notes |
|-----------|---------|-------|
| Flower | 1.31.0 | `flwr/superlink` container, managed by systemd |
| PyTorch | 2.5.1 (CPU) | Pre-baked into the SuperNode image |
| TensorFlow | 2.18.1 (CPU) | Built on first boot when selected |
| scikit-learn | 1.5.2 | Built on first boot when selected |
| Ubuntu | 24.04 LTS | |
| Docker CE | 27+ | |

Pick the framework at deploy time with `ONEAPP_FL_FRAMEWORK`. Only PyTorch is pre-baked; TensorFlow and scikit-learn build automatically on the first boot of a SuperNode that selects them (this keeps the image small enough for marketplace certification). The aggregation strategy and round count are **not** appliance settings; you choose them per run in your Flower App Bundle.

## Quick start

**You need:** OpenNebula 6.8+ with OneFlow and OneGate, your SSH key in your OpenNebula user profile, and Python 3.11+ with the `flwr` CLI (`pip install flwr`) on your own machine.

### 1. Import the appliance

From the OpenNebula Community Marketplace (FireEdge → Storage → Apps → "Service Flower FL 1.31.0" → Export), or from the CLI:

```bash
onemarketapp export 'Service Flower FL 1.31.0' 'Service Flower FL' --datastore default
```

This imports the OneFlow service template plus the SuperLink and SuperNode VM templates and OS-disk images. To build the images yourself instead, see [Build from source](#build-from-source).

### 2. Deploy the cluster

Instantiate the service, choosing a **private network** that every cluster VM will share. Optionally set the framework and TLS in the deploy form.

```bash
oneflow-template instantiate 'Service Flower FL'

# Watch it come up: SuperLink first, then SuperNodes auto-discover it
watch -n 5 oneflow show <service-id>
```

When the service reaches `RUNNING`, the cluster is up and idle, waiting for training code.

### 3. Run a training

TLS is on by default, and the Control API (`9093`) is bound to `localhost` on the SuperLink so it is never exposed to the network. So you do two things a plain Flower tutorial skips: tunnel to the Control API, and trust the SuperLink's CA.

```bash
# Find the SuperLink IP
oneflow show <service-id>

# Copy into the demo dir the CA the SuperLink generated (your SSH key is already trusted)
cd demo/pytorch        # or demo/tensorflow, demo/sklearn
scp root@<superlink-ip>:/opt/flower/certs/ca.crt ./ca.crt

# Open a tunnel to the localhost-bound Control API, and leave it running
ssh -L 9093:127.0.0.1:9093 root@<superlink-ip>
```

The demos are already configured for this (the `opennebula` federation points at `127.0.0.1:9093` with `root-certificates = "ca.crt"`), so once the CA is in place and the tunnel is up, just run:

```bash
flwr run . opennebula
```

`flwr run` packages your code into a Flower App Bundle, uploads it to the SuperLink, and the SuperLink distributes it to every SuperNode. Change your code and re-run; no image rebuild needed. Per-round loss and accuracy print in the output.

> Prefer one command? `bash demo/quickstart.sh` does all of the above (discovery, CA, tunnel, run) for you. For a quick local test with no cluster at all, `bash demo/quickstart.sh --skip-cluster` runs a Flower simulation with 2 virtual nodes. If you deployed with `ONEAPP_FL_TLS_ENABLED=NO`, replace `root-certificates = "ca.crt"` with `insecure = true` in the demo's `pyproject.toml`.

In our testing, 3 rounds of FedAvg on CIFAR-10 with 2 SuperNodes brought distributed loss from **~1.30 to ~0.92**, with only model weights crossing the network.

## Configuration

Two settings appear in the service deploy form:

| Parameter | Values | Default | Applies to |
|-----------|--------|---------|------------|
| `ONEAPP_FL_FRAMEWORK` | `pytorch`, `tensorflow`, `sklearn` | `pytorch` | SuperNodes |
| `ONEAPP_FL_TLS_ENABLED` | `YES`, `NO` | `YES` | Both roles |

Each role's VM template exposes a few more advanced context variables (edit the template, or set them in FireEdge before instantiating):

| Variable | Default | Purpose |
|----------|---------|---------|
| `ONEAPP_FLOWER_VERSION` | `1.31.0` | Flower image tag (images are pre-baked at 1.31.0) |
| `ONEAPP_FL_LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `ONEAPP_FL_ISOLATION` | `subprocess` | Flower app isolation: `subprocess` or `process` |
| `ONEAPP_FL_DATABASE` | `state/state.db` | SuperLink state DB path (SuperLink only) |
| `ONEAPP_FL_SUPERLINK_ADDRESS` | _(auto)_ | SuperNode only. `host:port` for a static SuperLink; empty means auto-discover via OneGate |
| `ONEAPP_FL_NODE_CONFIG` | _(auto)_ | SuperNode only. `key=value …`; empty auto-computes `partition-id` / `num-partitions` |
| `ONEAPP_FL_MAX_RETRIES` | `0` | SuperNode reconnect attempts (`0` = unlimited) |
| `ONEAPP_FL_MAX_WAIT_TIME` | `0` | SuperNode connect timeout, seconds (`0` = unlimited) |

Strategy and round count live in your App Bundle, not here. Override them per run without redeploying:

```bash
flwr run . opennebula --run-config "num-server-rounds=10 strategy=FedProx"
```

## Security

The appliance is hardened by default so it cannot be turned into an attack platform even if a training workload is compromised.

- **TLS on by default.** The SuperLink generates its own CA and server certificate, publishes the CA over OneGate, and SuperNodes fetch and trust it automatically. No manual certificate handling. If the CA cannot be retrieved, a SuperNode fails closed rather than falling back to plaintext.
- **No Flower port on `0.0.0.0`.** The Fleet API (`9092`) binds the private NIC, the Control API (`9093`) binds `127.0.0.1` only (it runs the code you submit, so reach it through the SSH tunnel above), and the internal ServerAppIo port (`9091`) is never published.
- **Default-deny host firewall.** UFW allows only inbound SSH; `DOCKER-USER` iptables rules restrict the Flower ports to the cluster's private subnet.
- **Outbound SMTP blocked.** Ports 25/465/587 are rejected on the host and container, IPv4 and IPv6, so a node can never send mail.
- **No injection surface.** Containers run as a non-root user and are launched from an argument array (never `eval`), so values like `ONEAPP_FL_NODE_CONFIG` can't smuggle in shell commands.

The SuperLink reuses its certificate across reboots so SuperNodes keep trusting the same CA. There is currently no hook to supply your own certificates; the CA is always self-generated.

## The demos

Each demo is a self-contained Flower app that trains a CIFAR-10 classifier with FedAvg (`num-server-rounds = 3`, 2 clients) and runs unchanged against the cluster or in local simulation.

| Demo | Model | Framework |
|------|-------|-----------|
| `demo/pytorch/` | Small CNN (~1.2M params) | PyTorch |
| `demo/tensorflow/` | Small CNN (~2.2M params) | TensorFlow |
| `demo/sklearn/` | MLPClassifier (~1.6M params) | scikit-learn |
| `demo/llm/` | Qwen2-0.5B + LoRA | PyTorch + transformers |

Run any of the first three against your cluster with the [Quick start](#3-run-a-training) flow, or in simulation with `flwr run . local-sim`. The **LLM demo is local-simulation only**: the deployed appliance builds PyTorch/TensorFlow/scikit-learn images, not the LLM image, so run it with `flwr run . local-sim`.

## Going further

<details>
<summary><strong>Bring your own data</strong></summary>

The demos auto-download CIFAR-10, which is fine for testing but not real FL. Pre-stage each SuperNode with its own partition:

```bash
scp -r ./hospital_a_scans/ root@<supernode-1-ip>:/opt/flower/data/
scp -r ./hospital_b_scans/ root@<supernode-2-ip>:/opt/flower/data/
```

The host's `/opt/flower/data` is mounted read-only into the container at `/app/data`. Load it in your `client_app.py`:

```python
from torchvision import datasets, transforms

dataset = datasets.ImageFolder("/app/data", transform=transforms.ToTensor())
```

Each SuperNode sees only its own data; the model learns across all sites.

</details>

<details>
<summary><strong>Scale the cluster</strong></summary>

The SuperNode role auto-scales between 2 and 10 nodes. Add nodes at any time; they boot, discover the SuperLink, and join automatically:

```bash
oneflow scale <service-id> supernode 5
```

</details>

<details>
<summary><strong>Multi-site deployment with Tailscale</strong></summary>

In production, SuperNodes sit in different organizations' networks. [Tailscale](https://tailscale.com/) (a WireGuard mesh VPN) makes cross-site connectivity simple:

```bash
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-<YOUR_KEY> --hostname=flower-superlink
```

OneGate discovery is zone-local, so point remote SuperNodes at the SuperLink's tailnet address explicitly:

```
ONEAPP_FL_SUPERLINK_ADDRESS = 100.x.a:9092
```

The auto-generated certificate only covers the SuperLink's local IPs, not its Tailscale IP, so TLS will not validate over the tailnet as shipped. Since WireGuard already encrypts every hop, run cross-site clusters with `ONEAPP_FL_TLS_ENABLED=NO` and rely on the tunnel for confidentiality.

</details>

<details>
<summary><strong>Monitoring dashboard</strong></summary>

A FastAPI dashboard (animated cluster topology, per-round metrics, node health, start/stop training) lives in `dashboard/`. Run it on the OpenNebula frontend, where it has the `onevm` CLI and SSH access to the VMs:

```bash
cd dashboard && pip install fastapi uvicorn
python -m uvicorn app:app --host 0.0.0.0 --port 8080
```

</details>

<details>
<summary><strong>Get the trained model out</strong></summary>

There is no checkpoint appliance setting. `flwr run` prints per-round loss and accuracy live. To persist the aggregated global model, save it in your `server_app.py` strategy, the standard Flower pattern, for example by subclassing `FedAvg` and writing the parameters in `aggregate_fit`. The model is yours to handle in your own app code.

</details>

<details>
<summary><strong>Build from source</strong></summary>

**Requires:** x86_64 with KVM, ~30 GB disk, Packer ≥ 1.9, QEMU/KVM, `genisoimage`, `jq`, `make`, and the one-apps `ubuntu2404.qcow2` base image.

```bash
cd build
make all INPUT_DIR=./images ONE_APPS_DIR=../../one-apps   # both images
# or individually:
make flower-superlink INPUT_DIR=./images ONE_APPS_DIR=../../one-apps
make flower-supernode INPUT_DIR=./images ONE_APPS_DIR=../../one-apps
```

Output: `build/export/flower-superlink.qcow2` and `build/export/flower-supernode.qcow2`. Upload them and register the templates:

```bash
cp build/export/*.qcow2 /var/tmp/        # RESTRICTED_DIRS blocks /root

oneimage create --name "Flower SuperLink 1.31.0" \
    --path /var/tmp/flower-superlink.qcow2 --type OS --driver qcow2 --datastore default
oneimage create --name "Flower SuperNode 1.31.0" \
    --path /var/tmp/flower-supernode.qcow2 --type OS --driver qcow2 --datastore default
```

For the OneFlow service, the marketplace YAMLs in `appliances/flower_service/` are the canonical definitions. The reference template at `build/oneflow/flower-cluster.yaml` is a starting point: convert it to JSON and fill in your real VM template IDs (it ships with `vm_template: 0` placeholders) before `oneflow-template create`.

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

| Symptom | Fix |
|---------|-----|
| `flwr run` connection refused | The Control API is `127.0.0.1:9093`. Open the SSH tunnel and target `127.0.0.1:9093`. |
| TLS handshake fails | Trust the SuperLink CA: `root-certificates = "ca.crt"` from `/opt/flower/certs/ca.crt`, not `insecure = true`. |
| SuperNode can't find SuperLink | Same private network? Check `onevm show <superlink-id>` for `FL_ENDPOINT`, or set `ONEAPP_FL_SUPERLINK_ADDRESS`. |
| Container `exit 137` | Out of memory. PyTorch needs the 8 GB SuperNode default; raise RAM for heavier models. |
| `bytes_sent/bytes_recv cannot be zero` | Stale state. Stop the SuperLink, `rm /opt/flower/state/state.db`, restart. |
| Service stuck in `DEPLOYING` | SuperNodes need OneGate. Ensure guests can reach the host's OneGate (port 5030) and that `ONEGATE_ENDPOINT` is an IP, not a hostname. |
| VM stuck in `BOOT` | Check `onevm show <id>` for CONTEXT errors; ensure the template has `NETWORK=YES`. |

</details>

## Project structure

```
appliances/   OpenNebula marketplace appliance definitions (the published artifact)
apps-code/    Packer build for the two marketplace images
build/        Local image build (Makefile, Packer, OneFlow reference template)
demo/         PyTorch, TensorFlow, scikit-learn, plus a local-simulation LLM app
dashboard/    FastAPI monitoring and control dashboard
```

## License

Apache 2.0. Built by the Cloud-Edge Innovation team at [OpenNebula Systems](https://opennebula.io), 2026.
