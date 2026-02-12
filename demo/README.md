# Privacy-Preserving Image Classification with Flower FL on OpenNebula

Three demos showing federated learning across different ML frameworks — all
training a CIFAR-10 image classifier without sharing raw data between nodes.

## Framework Demos

| Demo | Model | Parameters | Framework |
|---|---|---|---|
| `pytorch/` | SimpleCNN (Conv→Conv→FC→FC) | ~878K | PyTorch 2.6.0 |
| `tensorflow/` | Sequential CNN (Conv2D→Conv2D→Dense→Dense) | ~880K | TensorFlow 2.18.1 |
| `sklearn/` | MLPClassifier (3072→512→10) | ~1.6M | scikit-learn 1.4+ |

All three use the same Flower ServerApp (FedAvg strategy) and CIFAR-10 dataset.
The `server_app.py` is framework-agnostic and identical across all demos.

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

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Python | 3.11+ | For `flwr run` on your workstation |
| pip | latest | `pip install --upgrade pip` |
| SSH access | — | To `root@<frontend-ip>` (OpenNebula frontend) |

## Quick Start

### 1. Open SSH Tunnel

```bash
ssh -L 9093:<superlink-ip>:9093 -N root@<frontend-ip>
```

### 2. Bootstrap SuperNodes with the Right Framework

The SuperNode QCOW2 image ships with all three framework Docker images
pre-baked. Set the `ONEAPP_FL_FRAMEWORK` context variable to tell each
SuperNode which one to run at boot.

**Via Sunstone UI:**
1. Go to **Templates → VMs → SuperNode template → Update**
2. Under **Context → Custom Vars**, set `ONEAPP_FL_FRAMEWORK` to `pytorch`,
   `tensorflow`, or `sklearn`
3. Restart the SuperNode VMs (or instantiate new ones from the updated template)

**Via CLI:**
```bash
# Update the running SuperNode VMs (replace <vm-id> with actual IDs)
onevm updateconf <vm-id> --append 'CONTEXT=[ONEAPP_FL_FRAMEWORK="pytorch"]'
onevm reboot <vm-id>
```

**Via OneFlow service template:**

The service template exposes `ONEAPP_FL_ML_FRAMEWORK` as a dropdown. Select
the framework when instantiating the service, and all SuperNodes in the role
will boot with that image.

After reboot, each SuperNode's appliance will:
1. Read `ONEAPP_FL_FRAMEWORK` from VM context
2. Select the matching Docker image (`flower-supernode-{framework}:1.25.0`)
3. Create and start the container via systemd

### 3. Pick a Framework and Run

**PyTorch** (default):
```bash
cd demo/pytorch
pip install -e .
flwr run . opennebula
```

**TensorFlow**:
```bash
cd demo/tensorflow
pip install -e .
flwr run . opennebula
```

**scikit-learn**:
```bash
cd demo/sklearn
pip install -e .
flwr run . opennebula
```

The demo framework must match the `ONEAPP_FL_FRAMEWORK` set on the SuperNodes.
For example, running `demo/tensorflow` requires SuperNodes bootstrapped with
`ONEAPP_FL_FRAMEWORK=tensorflow`.

### 4. Local Simulation (No Cluster Needed)

Each demo includes a `local-sim` federation for testing without a cluster:

```bash
cd demo/pytorch   # or tensorflow, sklearn
flwr run . local-sim
```

---

## Project Structure

```
demo/
├── README.md                              # This file
├── pytorch/
│   ├── pyproject.toml                     # Flower App Bundle (PyTorch deps)
│   └── flower_demo/
│       ├── __init__.py
│       ├── model.py                       # SimpleCNN (torch.nn)
│       ├── client_app.py                  # PyTorch training loop
│       └── server_app.py                  # FedAvg (framework-agnostic)
├── tensorflow/
│   ├── pyproject.toml                     # Flower App Bundle (TF deps)
│   └── flower_demo/
│       ├── __init__.py
│       ├── model.py                       # Sequential CNN (Keras)
│       ├── client_app.py                  # Keras training loop
│       └── server_app.py                  # FedAvg (framework-agnostic)
├── sklearn/
│   ├── pyproject.toml                     # Flower App Bundle (sklearn deps)
│   └── flower_demo/
│       ├── __init__.py
│       ├── model.py                       # MLPClassifier
│       ├── client_app.py                  # sklearn partial_fit loop
│       └── server_app.py                  # FedAvg (framework-agnostic)
├── Dockerfile.supernode-pytorch           # PyTorch SuperNode image
├── Dockerfile.supernode-tensorflow        # TensorFlow SuperNode image
├── Dockerfile.supernode-sklearn           # scikit-learn SuperNode image
└── setup/
    ├── prepare-cluster.sh                 # Build + deploy images
    └── verify-cluster.sh                  # Pre-flight checks
```

## Aggregation Strategy

All three demos use **Federated Averaging (FedAvg)**, the foundational
aggregation algorithm for federated learning (McMahan et al., 2017).

### How FedAvg Works

Each training round follows the same cycle:

1. **Broadcast** — The SuperLink sends the current global model weights to all
   participating SuperNodes
2. **Local training** — Each SuperNode trains the model on its private data
   partition for one or more epochs, producing updated local weights
3. **Collect** — SuperNodes send their updated weights (never raw data) back to
   the SuperLink
4. **Aggregate** — The SuperLink computes a weighted average of all client
   weights, proportional to each client's dataset size:

```
w_global = SUM( n_k / n_total * w_k )   for each client k
```

Where `n_k` is the number of training samples on client `k`, `w_k` are its
updated weights, and `n_total` is the sum of all samples across clients.

### Strategy Configuration

The `server_app.py` (identical in all three demos) configures FedAvg as:

| Parameter | Value | Meaning |
|---|---|---|
| `fraction_fit` | 1.0 | All connected clients participate in every round |
| `fraction_evaluate` | 1.0 | All clients evaluate the global model each round |
| `min_fit_clients` | 2 | Wait for at least 2 clients before starting a round |
| `min_available_clients` | 2 | Don't start training until 2 clients are connected |
| `initial_parameters` | None | First client's weights become the starting point |

The ServerApp is **framework-agnostic** — it only sees numpy arrays of weights.
It does not import PyTorch, TensorFlow, or sklearn. This is a hard constraint
because the SuperLink container only has `flwr` installed.

### What Each Framework Trains

While the aggregation strategy is the same, each demo uses a different model
architecture and local training approach:

**PyTorch** — `demo/pytorch/`
- **Model**: `SimpleCNN` — a `torch.nn.Module` with two Conv2d layers (5x5
  kernels, padding=1), two max-pool layers, and two fully connected layers
  (2304→512→10). ~878K parameters.
- **Optimizer**: SGD with lr=0.01, momentum=0.9
- **Data pipeline**: `torchvision` transforms normalize images to [-1, 1],
  served via `DataLoader`
- **Serialization**: `state_dict()` values converted to numpy arrays

**TensorFlow** — `demo/tensorflow/`
- **Model**: `keras.Sequential` CNN — two Conv2D layers (5x5 kernels,
  padding='same'), two MaxPooling2D layers, and two Dense layers (512→10
  with softmax output). ~880K parameters.
- **Optimizer**: SGD (Keras default)
- **Data pipeline**: Images converted to numpy arrays, normalized to [0, 1]
- **Serialization**: `model.get_weights()` returns native numpy arrays

**scikit-learn** — `demo/sklearn/`
- **Model**: `MLPClassifier` — a single hidden layer MLP (3072→512→10).
  ~1.6M parameters (larger because no convolutions — raw pixel input).
- **Training**: `partial_fit()` with `warm_start=True` for incremental
  learning across federated rounds
- **Data pipeline**: Images flattened from 32x32x3 to 3072-dim vectors,
  normalized to [0, 1]
- **Serialization**: Manually extracts `coefs_` and `intercepts_` arrays.
  Weights are initialized before the first round since sklearn only creates
  these attributes after the first `fit()` call.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Connection refused` on `flwr run` | SSH tunnel not active | `ssh -L 9093:<superlink-ip>:9093 root@<frontend-ip>` |
| `min_available_clients=2` timeout | SuperNode(s) not connected | Check containers with `verify-cluster.sh` |
| `ModuleNotFoundError: torch` on SuperLink | ServerApp imports torch | Remove torch imports from `server_app.py` |
| `ModuleNotFoundError` on SuperNode | Wrong framework image | Set `ONEAPP_FL_FRAMEWORK` context var and restart |
| Very low accuracy (< 20%) | Too few rounds | Increase `num-server-rounds` to 10+ |

## References

- [Flower Framework Documentation](https://flower.ai/docs/)
- [Flower App Bundle Guide](https://flower.ai/docs/framework/how-to-run-flower-using-deployment-engine.html)
- [CIFAR-10 Dataset](https://www.cs.toronto.edu/~kriz/cifar.html)
- [FedAvg Paper (McMahan et al., 2017)](https://arxiv.org/abs/1602.05629)
