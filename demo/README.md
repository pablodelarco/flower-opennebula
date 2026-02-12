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

## Framework Differences

### PyTorch
- Uses `torch.nn.Module` with explicit forward pass
- DataLoader wraps `flwr_datasets` with `apply_transforms`
- SGD optimizer with lr=0.01, momentum=0.9
- Device-aware (GPU if available, CPU otherwise)

### TensorFlow
- Uses `keras.Sequential` model with `.fit()` / `.evaluate()`
- Images converted to numpy arrays, normalized to [0, 1]
- SGD optimizer (Keras default)
- `model.get_weights()` / `model.set_weights()` for serialization

### scikit-learn
- Uses `MLPClassifier` with `partial_fit()` for incremental learning
- Images flattened from 32×32×3 to 3072-dim vectors
- `warm_start=True` preserves weights between rounds
- Weights manually initialized before first round (sklearn quirk)

## Understanding the Code

### server_app.py (shared)

The ServerApp is **identical** across all three demos. It configures FedAvg with:
- `fraction_fit=1.0` — All clients participate every round
- `min_fit_clients=2` — Wait for both hospitals
- No `initial_parameters` — First client's weights initialize the global model

**Critical constraint**: This file must NOT import any ML framework. The
SuperLink container only has `flwr` installed.

### client_app.py (framework-specific)

Each client follows the same pattern:
1. Load a CIFAR-10 partition using `flwr_datasets`
2. `get_parameters()` — Serialize model weights as numpy arrays
3. `fit()` — Set weights, train locally, return updated weights
4. `evaluate()` — Set weights, evaluate, return loss + accuracy

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
