# Privacy-Preserving Image Classification with Flower FL on OpenNebula

Two hospitals want to collaboratively train an image classifier — but patient
privacy regulations (HIPAA, GDPR) prohibit sharing raw data. Federated Learning
solves this: each hospital trains locally, and only model weights cross the
network. Raw images never leave the premises.

This demo runs that scenario on a real OpenNebula cluster using the
[Flower](https://flower.ai) framework.

## The Privacy Problem

```
  Hospital A                              Hospital B
 ┌──────────────┐                        ┌──────────────┐
 │  Patient      │       PROHIBITED       │  Patient      │
 │  Images       │ ──────── X ──────────> │  Images       │
 │  (CIFAR-10)   │    raw data cannot     │  (CIFAR-10)   │
 │               │    cross the wire      │               │
 │  HIPAA/GDPR   │                        │  HIPAA/GDPR   │
 └──────────────┘                        └──────────────┘
```

## The Federated Learning Solution

```
                    ┌─────────────────┐
                    │   SuperLink     │
                    │   (Coordinator) │
                    │                 │
                    │   FedAvg        │
                    │   Aggregation   │
                    └────────┬────────┘
                   ▲         │         ▲
          weights  │         │ global  │  weights
          only     │         │ model   │  only
          (~3.5MB) │         │         │  (~3.5MB)
                   │         ▼         │
         ┌─────────┴──┐          ┌─────┴──────────┐
         │ SuperNode 1 │          │ SuperNode 2     │
         │ (Hospital A)│          │ (Hospital B)    │
         │             │          │                 │
         │ ┌─────────┐ │          │ ┌─────────┐    │
         │ │ Training │ │          │ │ Training │    │
         │ │ Data     │ │          │ │ Data     │    │
         │ │ [locked] │ │          │ │ [locked] │    │
         │ └─────────┘ │          │ └─────────┘    │
         └─────────────┘          └────────────────┘

         Raw images NEVER leave the SuperNode VM.
```

## OpenNebula Architecture

```
  Your Workstation                  OpenNebula Frontend (51.158.111.100)
 ┌─────────────────┐               ┌────────────────────────────────────────┐
 │                  │   SSH tunnel  │  KVM Host                              │
 │  flwr run .     │───────────────│─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ │
 │  (Control API)  │  :9093 ────>  │                                        │
 │                  │               │  ┌──────────┐ ┌──────────┐ ┌────────┐ │
 └─────────────────┘               │  │ VM 74    │ │ VM 75    │ │ VM 76  │ │
                                   │  │ SuperLink│ │ SuperNode│ │ SNode  │ │
                                   │  │ .100.3   │ │ .100.4   │ │ .100.5 │ │
                                   │  │          │ │          │ │        │ │
                                   │  │ ┌──────┐ │ │ ┌──────┐ │ │┌──────┐│ │
                                   │  │ │Docker│ │ │ │Docker│ │ ││Docker││ │
                                   │  │ │flwr/ │ │ │ │+torch│ │ ││+torch││ │
                                   │  │ │super │ │ │ │      │ │ ││      ││ │
                                   │  │ │link  │ │ │ │      │ │ ││      ││ │
                                   │  │ └──────┘ │ │ └──────┘ │ │└──────┘│ │
                                   │  └──────────┘ └──────────┘ └────────┘ │
                                   │       :9092 ◄─── Fleet API ──►        │
                                   └────────────────────────────────────────┘
                                        Private network: 172.16.100.0/24
```

## Training Round Sequence

```
  Round 1                Round 2                Round 3
  ────────────────       ────────────────       ────────────────
  Select clients         Select clients         Select clients
       │                      │                      │
       ▼                      ▼                      ▼
  Send model             Send model             Send model
  (random init)          (round 1 avg)          (round 2 avg)
       │                      │                      │
       ├──► Node 1 train      ├──► Node 1 train      ├──► Node 1 train
       ├──► Node 2 train      ├──► Node 2 train      ├──► Node 2 train
       │                      │                      │
       ▼                      ▼                      ▼
  Collect weights        Collect weights        Collect weights
       │                      │                      │
       ▼                      ▼                      ▼
  FedAvg aggregate       FedAvg aggregate       FedAvg aggregate
       │                      │                      │
       ▼                      ▼                      ▼
  Accuracy: ~35%         Accuracy: ~45%         Accuracy: ~50%
```

## What Crosses the Wire

```
  ┌─ Model Weights ─────────────────────┐    ┌─ Raw Data ────────────────────┐
  │                                     │    │                               │
  │  878K parameters × 4 bytes = 3.5 MB │    │  25,000 images × 3×32×32      │
  │  ▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │    │  = ~100 MB per partition       │
  │  ^^^^ this crosses the network      │    │  ████████████████████████████  │
  │                                     │    │  XXXX NEVER TRANSMITTED XXXX   │
  └─────────────────────────────────────┘    └───────────────────────────────┘
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Python | 3.11+ | For `flwr run` on your workstation |
| pip | latest | `pip install --upgrade pip` |
| SSH access | — | To `root@51.158.111.100` (OpenNebula frontend) |
| Docker | 20.10+ | Only needed if rebuilding the SuperNode image |

## Quick Start

Six commands from zero to federated training:

```bash
# 1. Open SSH tunnel to SuperLink Control API (run in a separate terminal)
ssh -L 9093:172.16.100.3:9093 root@51.158.111.100

# 2. Install the demo project locally
cd demo
pip install -e .

# 3. (Optional) Rebuild and deploy PyTorch SuperNode image
bash setup/prepare-cluster.sh

# 4. Verify the cluster is healthy
bash setup/verify-cluster.sh

# 5. Run federated training on the real cluster
flwr run . opennebula

# 6. (Alternative) Run locally in simulation mode
flwr run . local-sim
```

---

## Understanding the Code

### `flower_demo/model.py` — The Neural Network

A lightweight CNN (~878K parameters) for CIFAR-10 classification:

```
Input (3×32×32) → Conv(32) → Pool → Conv(64) → Pool → FC(512) → FC(10)
```

Key functions:
- **`train(net, trainloader, epochs, device)`** — SGD with lr=0.01, momentum=0.9
- **`test(net, testloader, device)`** — Returns `(loss, accuracy)`
- **`get_weights(net)`** / **`set_weights(net, params)`** — Serialize model for Flower
- **`apply_transforms(batch)`** — Normalize CIFAR-10 images to [-1, 1]

### `flower_demo/client_app.py` — Local Training (SuperNodes)

Each SuperNode runs a `FlowerClient` that:
1. Receives global model weights from the SuperLink
2. Trains on its local CIFAR-10 partition for `local-epochs` epochs
3. Returns updated weights and dataset size (for weighted averaging)
4. Evaluates the global model on local test data

**Partition assignment**: In OneFlow deployments, `partition-id` is auto-assigned
by the appliance. For manual deployments (like this cluster), the client falls
back to `hash(node_id) % num_partitions` for deterministic assignment.

### `flower_demo/server_app.py` — Aggregation Strategy (SuperLink)

The ServerApp configures FedAvg with:
- `fraction_fit=1.0` — All clients participate in every round
- `min_fit_clients=2` — Wait for both hospitals
- No `initial_parameters` — First client's weights initialize the global model

**Critical constraint**: This file must NOT import `torch`. The SuperLink
container (`flwr/superlink:1.25.0`) has no ML frameworks installed.

### `pyproject.toml` — Flower App Bundle

Defines two federation targets:
- **`opennebula`** — Real cluster via SSH tunnel (`127.0.0.1:9093`)
- **`local-sim`** — Simulation with 2 virtual SuperNodes (no cluster needed)

---

## Step-by-Step Walkthrough

### 1. Set Up SSH Tunnel

The cluster runs on a private network (`172.16.100.0/24`). Your workstation
needs to reach the SuperLink's Control API (port 9093) via an SSH tunnel:

```bash
ssh -L 9093:172.16.100.3:9093 -N root@51.158.111.100
```

The `-N` flag keeps the tunnel open without starting a shell. Leave this
running in a dedicated terminal.

### 2. Install the Demo

```bash
cd demo
pip install -e .
```

This installs the `flower_demo` package and all dependencies (Flower, PyTorch,
torchvision, flwr-datasets) into your local environment.

### 3. Prepare the Cluster (If Needed)

The SuperNode VMs need PyTorch inside their Docker containers. If the
`flower-supernode-pytorch:demo` image isn't already deployed:

```bash
bash setup/prepare-cluster.sh
```

This builds the image locally, transfers it to each SuperNode VM, and restarts
the containers. Takes ~5 minutes (PyTorch CPU is ~800 MB).

### 4. Verify Cluster Health

```bash
bash setup/verify-cluster.sh
```

Expected output:
```
Flower FL Demo — Cluster Verification
======================================

[Local Machine]
  PASS  SSH tunnel active (127.0.0.1:9093)
  PASS  flwr CLI installed

[SuperLink — 172.16.100.3]
  PASS  SSH reachable
  PASS  Docker running
  PASS  SuperLink container up

[SuperNode — 172.16.100.4]
  PASS  SSH reachable
  PASS  Docker running
  PASS  SuperNode container up
  PASS  PyTorch importable
  PASS  flwr-datasets importable

[SuperNode — 172.16.100.5]
  PASS  SSH reachable
  PASS  Docker running
  PASS  SuperNode container up
  PASS  PyTorch importable
  PASS  flwr-datasets importable

======================================
Results: 13 passed, 0 failed

All checks passed. Ready to run:
  cd demo && flwr run . opennebula
```

### 5. Run Federated Training

```bash
flwr run . opennebula
```

Flower pushes the `flower_demo` package to the SuperLink, which distributes the
ServerApp and ClientApp to the appropriate containers via subprocess isolation.

**First run note**: Each SuperNode downloads CIFAR-10 (~170 MB) on first
execution. Subsequent runs use the cached dataset.

### 6. Interpret the Logs

You'll see output like:

```
INFO : Starting Flower ServerApp
INFO : [ROUND 1]
INFO : configure_fit: strategy sampled 2 clients (out of 2)
INFO : aggregate_fit: received 2 results and 0 failures
INFO : configure_evaluate: strategy sampled 2 clients (out of 2)
INFO : [ROUND 1] fit loss (avg): 1.8234, accuracy (avg): 0.3512
INFO : [ROUND 2]
...
INFO : [ROUND 3] fit loss (avg): 1.2456, accuracy (avg): 0.5123
INFO : Flower ServerApp finished
```

After 3 rounds with 1 local epoch each, expect ~45-55% accuracy. Increase
`num-server-rounds` or `local-epochs` in `pyproject.toml` for better results.

---

## Proving Data Privacy

### 1. Network Traffic Analysis

On any SuperNode VM, capture traffic during training:

```bash
# On SuperNode VM (via SSH through frontend)
tcpdump -i eth0 -w /tmp/flower-traffic.pcap &
# ... run training ...
kill %1

# Analyze: you'll see gRPC frames (serialized weights), never raw image data
tcpdump -r /tmp/flower-traffic.pcap -A | grep -c "JFIF\|PNG\|CIFAR"
# Output: 0  (no image data in network traffic)
```

### 2. Filesystem Inspection

```bash
# CIFAR-10 data exists ONLY on the SuperNode where it was downloaded
ssh root@51.158.111.100 "ssh root@172.16.100.4 \
    docker exec flower-supernode find / -name '*.pkl' -o -name 'cifar*' 2>/dev/null"
# Shows local dataset cache

# SuperLink has NO training data
ssh root@51.158.111.100 "ssh root@172.16.100.3 \
    docker exec flower-superlink find / -name '*.pkl' -o -name 'cifar*' 2>/dev/null"
# Empty output
```

### 3. Log Audit

```bash
# SuperLink logs show only aggregation events, never data content
ssh root@51.158.111.100 "ssh root@172.16.100.3 \
    docker logs flower-superlink 2>&1 | tail -20"
```

---

## Experiments

### More Training Rounds

Edit `pyproject.toml`:

```toml
[tool.flwr.app.config]
num-server-rounds = 10
local-epochs = 2
```

Expected: ~65-70% accuracy after 10 rounds.

### Local Simulation

Test changes without touching the cluster:

```bash
flwr run . local-sim
```

### Non-IID Data Partitioning

Replace `IidPartitioner` in `client_app.py` with a Dirichlet partitioner
to simulate hospitals with different patient populations:

```python
from flwr_datasets.partitioner import DirichletPartitioner

fds = FederatedDataset(
    dataset="uoft-cs/cifar10",
    partitioners={"train": DirichletPartitioner(
        num_partitions=num_partitions, partition_by="label", alpha=0.5
    )},
)
```

Lower `alpha` = more heterogeneous data (harder for FL).

### Try FedProx

Replace `FedAvg` in `server_app.py` for better convergence with non-IID data:

```python
from flwr.server.strategy import FedProx

strategy = FedProx(
    fraction_fit=1.0,
    min_fit_clients=2,
    min_available_clients=2,
    proximal_mu=0.1,
)
```

---

## How It Works Under the Hood

### gRPC Communication

Flower uses gRPC for all communication:
- **Fleet API** (port 9092): SuperNodes connect to the SuperLink and poll for tasks
- **Control API** (port 9093): `flwr run` submits the app bundle and monitors progress

SuperNodes are long-running — they connect to the Fleet API at boot and wait for
instructions. When a run starts, the SuperLink tells each SuperNode to execute the
ClientApp in a subprocess.

### FedAvg Aggregation

After each round, the SuperLink combines client weights using Federated Averaging:

```
w_global = SUM(n_k / n_total * w_k)  for each client k
```

Where `n_k` is the number of training samples on client `k` and `w_k` are its
updated weights. This weighted average accounts for different dataset sizes.

### Subprocess Isolation

Both ServerApp and ClientApp run as subprocesses inside their respective
containers. This means:
- The ServerApp subprocess on the SuperLink can only import packages in that container (`flwr` only)
- The ClientApp subprocess on each SuperNode can import `torch`, `torchvision`, etc.
- Crashes in user code don't bring down the Flower infrastructure

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on `flwr run` | SSH tunnel not active | Open tunnel: `ssh -L 9093:172.16.100.3:9093 root@51.158.111.100` |
| `min_available_clients=2` timeout | SuperNode(s) not connected | Check containers: `bash setup/verify-cluster.sh` |
| `ModuleNotFoundError: torch` on SuperLink | ServerApp imports torch | Remove any torch imports from `server_app.py` |
| `ModuleNotFoundError: torch` on SuperNode | Old image without PyTorch | Redeploy: `bash setup/prepare-cluster.sh` |
| `No such file or directory: cifar` | Dataset download failed | Check SuperNode internet access (NAT/proxy) |
| Very low accuracy (< 20%) | Too few rounds or data issue | Increase `num-server-rounds` to 10+ |
| `RESOURCE_EXHAUSTED` gRPC error | Message size too large | Default limit is fine for SimpleCNN; reduce model size if customizing |
| `docker: permission denied` | Not root on SuperNode VM | SSH as root or use sudo |

---

## Project Structure

```
demo/
├── README.md                      # This file
├── pyproject.toml                 # Flower App Bundle configuration
├── flower_demo/
│   ├── __init__.py                # Package marker
│   ├── model.py                   # SimpleCNN + train/test/weight helpers
│   ├── client_app.py              # ClientApp: local PyTorch training
│   └── server_app.py              # ServerApp: FedAvg (no torch!)
├── Dockerfile.supernode-pytorch    # PyTorch SuperNode image
├── Dockerfile.supernode-tensorflow # TensorFlow SuperNode image
├── Dockerfile.supernode-sklearn    # scikit-learn SuperNode image
└── setup/
    ├── prepare-cluster.sh         # Build + deploy PyTorch image
    └── verify-cluster.sh          # Pre-flight connectivity checks
```

## References

- [Flower Framework Documentation](https://flower.ai/docs/)
- [Flower App Bundle Guide](https://flower.ai/docs/framework/how-to-run-flower-using-deployment-engine.html)
- [CIFAR-10 Dataset](https://www.cs.toronto.edu/~kriz/cifar.html)
- [FedAvg Paper (McMahan et al., 2017)](https://arxiv.org/abs/1602.05629)
- [spec/06-ml-framework-variants.md](../spec/06-ml-framework-variants.md) — PyTorch variant Dockerfile
- [spec/04-oneflow-orchestration.md](../spec/04-oneflow-orchestration.md) — Cluster orchestration
- [spec/05-fl-training.md](../spec/05-fl-training.md) — Training workflow specification
