# Quick Start: Federated Learning on OpenNebula

> Deploy a privacy-preserving FL cluster in 15 minutes. Three VMs, three training rounds, zero data sharing.

---

### What you will build

```
                           OpenNebula Cloud
  ┌───────────────────────────────────────────────────────────┐
  │                                                           │
  │       ┌───────────────────────────────┐                   │
  │       │         SuperLink VM          │                   │
  │       │     Flower Coordinator        │                   │
  │       │                               │                   │
  │       │   gRPC Fleet API  :9092       │                   │
  │       │   Control API     :9093       │                   │
  │       │   Dashboard       :8080       │                   │
  │       └───────────┬───────────────────┘                   │
  │              _____|_____                                   │
  │             |           |                                  │
  │        weights      weights                                │
  │        (~3.5 MB)    (~3.5 MB)                              │
  │             |           |                                  │
  │    ┌────────┴──┐   ┌───┴─────────┐                        │
  │    │ SuperNode │   │ SuperNode   │                        │
  │    │   VM #1   │   │   VM #2     │                        │
  │    │           │   │             │                        │
  │    │  Hospital │   │  Hospital   │                        │
  │    │  A data   │   │  B data     │                        │
  │    │  [local]  │   │  [local]    │                        │
  │    └───────────┘   └─────────────┘                        │
  │                                                           │
  │    Raw images NEVER leave the SuperNode VMs.              │
  └───────────────────────────────────────────────────────────┘

  You (frontend)                        Result
  ─────────────                         ──────
  flwr run . opennebula  ──────────>    3 rounds FedAvg CIFAR-10
                                        Loss: 1.27 → 1.03 → 0.94
                                        ~7 min total training time
```

| Component | Where it runs | What it does |
|-----------|--------------|--------------|
| `oneflow-template`, `oneflow` | Frontend shell | OneFlow service orchestration (primary) |
| `oneimage`, `onetemplate` | Frontend shell | Image and template management |
| SuperLink container | SuperLink VM | Coordinates rounds, aggregates weights |
| SuperNode containers | SuperNode VMs | Train locally on private data |
| `flwr run . opennebula` | Frontend shell | Submits training job to SuperLink |
| Dashboard | SuperLink VM `:8080` | Live topology and training metrics |

### Time and resources

| | |
|---|---|
| **Total time** | ~15-20 minutes end to end |
| **VMs required** | 3 (1 SuperLink + 2 SuperNodes) |
| **Training** | ~2 minutes per round on 2 vCPU |
| **Network transferred** | ~3.5 MB of model weights per round |
| **Raw data transferred** | None. Zero. That is the point. |

| VM Role | vCPU | RAM | Disk |
|---------|------|-----|------|
| SuperLink | 2 | 4 GB | 10 GB |
| SuperNode (x2) | 2 | 4 GB | 20 GB |

---

## Prerequisites

Before starting, confirm every item on this list. Missing any one of them will block deployment.

- **SSH access to the OpenNebula frontend** -- all commands in this guide run there
- **OpenNebula CLI configured** -- `oneimage`, `onetemplate`, `oneflow-template`, `oneflow` available in your shell
- **Python 3.11+ and pip** -- required on the frontend for `flwr run`
- **SSH public key in your OpenNebula user profile**
  ```bash
  oneuser update oneadmin --append 'SSH_PUBLIC_KEY="<your-key>"'
  ```
- **Pre-built appliance images** -- uploaded to an OpenNebula datastore (see [BUILD.md](BUILD.md) for how to build them with Packer, or import from the marketplace)
- **Virtual network with internet access** -- VMs must reach each other and download CIFAR-10 (~170 MB) on first run

> **Warning:** If you are using a **bridge-type virtual network**, you must assign the gateway IP to the bridge interface on the KVM host. Without this, VMs cannot reach the host or external networks.
>
> **Persistent fix (recommended):**
> ```bash
> cat > /etc/systemd/network/50-<bridge-name>.network <<'EOF'
> [Match]
> Name=<bridge-name>
>
> [Network]
> Address=<gateway-ip>/24
> EOF
> systemctl restart systemd-networkd
> ```
>
> **Quick test fix:**
> ```bash
> ip addr add <gateway-ip>/24 dev <bridge-name>
> iptables -t nat -A POSTROUTING -s <subnet>/24 ! -d <subnet>/24 -j MASQUERADE
> ```

---

## Step 1 of 6: Import Appliances

**Time:** ~3 minutes

### Option A: From the Marketplace (recommended)

If your OpenNebula instance has the community marketplace configured:

1. Open Sunstone -> **Storage -> Apps**
2. Search for **"Flower FL"**
3. Select **"Service Flower FL 1.25.0"** -> click **Export**
4. Choose a datastore and confirm

OpenNebula automatically imports all disk images, VM templates, and the OneFlow
service template. Skip to **Step 2**.

### Option B: Build from source

If you built the QCOW2 images with Packer (see [BUILD.md](BUILD.md)), upload
them manually.

If the appliance images are not already in your datastore, upload them.

> **Note:** OpenNebula's `RESTRICTED_DIRS` blocks image uploads from `/root` by default. If your QCOW2 files are in `/root`, copy them to `/var/tmp` first:
> ```bash
> cp /root/flower-superlink.qcow2 /var/tmp/
> cp /root/flower-supernode.qcow2 /var/tmp/
> ```

### 1.1 Upload images

```bash
cat > /tmp/superlink-img.tmpl <<'TMPL'
NAME = "Flower SuperLink v1.25.0"
TYPE = OS
PATH = /var/tmp/flower-superlink.qcow2
FORMAT = qcow2
TMPL
oneimage create -d default /tmp/superlink-img.tmpl

cat > /tmp/supernode-img.tmpl <<'TMPL'
NAME = "Flower SuperNode v1.25.0"
TYPE = OS
PATH = /var/tmp/flower-supernode.qcow2
FORMAT = qcow2
TMPL
oneimage create -d default /tmp/supernode-img.tmpl
```

Wait for both images to reach `READY` state:

```bash
watch -n 5 'oneimage list | grep Flower'
```

Expected output:

```
  38 oneadmin   Flower SuperLink v1.25.0   2048  default  rdy   06/10 12:34
  39 oneadmin   Flower SuperNode v1.25.0   4096  default  rdy   06/10 12:35
```

### 1.2 Create VM templates

**SuperLink template:**

```bash
cat > /tmp/superlink.tmpl <<'EOF'
NAME = "Flower SuperLink"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperLink v1.25.0" ]
NIC = [ NETWORK = "<your-vnet-name>" ]
GRAPHICS = [ LISTEN = "0.0.0.0", TYPE = "VNC" ]
OS = [ ARCH = "x86_64" ]
CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
  ONEAPP_FL_ML_FRAMEWORK = "$ONEAPP_FL_ML_FRAMEWORK",
  ONEAPP_FL_FRAMEWORK = "$ONEAPP_FL_ML_FRAMEWORK",
  ONEAPP_FL_NUM_ROUNDS = "$ONEAPP_FL_NUM_ROUNDS",
  ONEAPP_FL_AGG_STRATEGY = "$ONEAPP_FL_AGG_STRATEGY",
  ONEAPP_FL_STRATEGY = "$ONEAPP_FL_AGG_STRATEGY",
  ONEAPP_FL_MIN_AVAILABLE_CLIENTS = "$ONEAPP_FL_MIN_AVAILABLE_CLIENTS",
  ONEAPP_FL_TLS_ENABLED = "$ONEAPP_FL_TLS_ENABLED"
]
EOF
onetemplate create /tmp/superlink.tmpl
```

**SuperNode template:**

```bash
cat > /tmp/supernode.tmpl <<'EOF'
NAME = "Flower SuperNode"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperNode v1.25.0" ]
NIC = [ NETWORK = "<your-vnet-name>" ]
GRAPHICS = [ LISTEN = "0.0.0.0", TYPE = "VNC" ]
OS = [ ARCH = "x86_64" ]
CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]",
  ONEAPP_FL_ML_FRAMEWORK = "$ONEAPP_FL_ML_FRAMEWORK",
  ONEAPP_FL_FRAMEWORK = "$ONEAPP_FL_ML_FRAMEWORK",
  ONEAPP_FL_NUM_ROUNDS = "$ONEAPP_FL_NUM_ROUNDS",
  ONEAPP_FL_AGG_STRATEGY = "$ONEAPP_FL_AGG_STRATEGY",
  ONEAPP_FL_STRATEGY = "$ONEAPP_FL_AGG_STRATEGY",
  ONEAPP_FL_MIN_AVAILABLE_CLIENTS = "$ONEAPP_FL_MIN_AVAILABLE_CLIENTS",
  ONEAPP_FL_TLS_ENABLED = "$ONEAPP_FL_TLS_ENABLED",
  ONEAPP_FL_GPU_ENABLED = "$ONEAPP_FL_GPU_ENABLED"
]
EOF
onetemplate create /tmp/supernode.tmpl
```

Note the template IDs from the output -- you will need them for the OneFlow service template.

Expected output:

```
ID: 31
```

### 1.3 Register the OneFlow service template

The OneFlow service template orchestrates the full cluster: it boots the SuperLink first, waits for it to report `READY`, then starts the SuperNodes which auto-discover the SuperLink via OneGate.

**1. Edit `build/oneflow/flower-cluster.yaml`** -- set your template IDs and network:

```bash
# Find your template and network IDs
onetemplate list | grep "Flower"
onevnet list
```

Update the `vm_template` fields in the YAML with your actual template IDs. The `$Private` network reference resolves from the `networks` section -- it maps to your FL cluster network.

**2. Register the service template:**

```bash
oneflow-template create build/oneflow/flower-cluster.yaml
```

Note the service template ID from the output -- you will use it in Step 2.

---

## Step 2 of 6: Deploy the Cluster

**Time:** ~2 minutes

OneFlow deploys the entire cluster in the correct order: SuperLink boots first, reports `READY`, then SuperNodes start and auto-discover the SuperLink via OneGate.

### 2.1 Instantiate the service

```bash
oneflow-template instantiate <service-template-id>
```

To select a specific ML framework at deployment time:

```bash
oneflow-template instantiate <service-template-id> \
    --user_inputs '{"ONEAPP_FL_ML_FRAMEWORK": "pytorch"}'
```

Available frameworks: `pytorch` (default), `tensorflow`, `sklearn`.

### 2.2 Monitor deployment

```bash
watch -n 5 oneflow show <service-id>
```

The deployment runs in two phases:

1. **Phase 1:** SuperLink VM boots, configures Docker, starts Flower, publishes endpoint to OneGate, reports `READY`
2. **Phase 2:** SuperNode VMs boot, discover SuperLink via OneGate, connect to Fleet API on port 9092

Expected progression:

```
PENDING → DEPLOYING → RUNNING
```

### 2.3 Get the SuperLink IP

```bash
SUPERLINK_IP=$(oneflow show <service-id> --json | \
    jq -r '.DOCUMENT.TEMPLATE.BODY.roles[] |
    select(.name=="superlink") | .nodes[0].vm_info.VM.TEMPLATE.NIC[0].IP')
echo "SuperLink IP: $SUPERLINK_IP"
```

Expected output:

```
SuperLink IP: 172.16.100.3
```

> **Manual deployment:** For environments without OneFlow or when deploying across zones, see [BUILD.md Appendix A](BUILD.md#appendix-a-manual-deployment-without-packer) or deploy individual VMs with `onetemplate instantiate` and pass `ONEAPP_FL_SUPERLINK_ADDRESS` manually.

---

## Step 3 of 6: Verify the Cluster

**Time:** ~1 minute

The appliance images boot with Docker and systemd services pre-configured. The SuperNode image includes PyTorch, TensorFlow, and scikit-learn pre-baked. The framework is selected at deployment via `ONEAPP_FL_FRAMEWORK`.

First, confirm the OneFlow service is fully running:

```bash
oneflow show <service-id>
# All roles should show state: RUNNING
```

Then verify the containers on each VM.

### 3.1 Check the SuperLink

```bash
ssh root@$SUPERLINK_IP docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

Expected output:

```
NAMES              STATUS          PORTS
flower-superlink   Up 2 minutes    0.0.0.0:9092-9093->9092-9093/tcp
```

Confirm the Fleet API is listening:

```bash
ssh root@$SUPERLINK_IP docker logs flower-superlink 2>&1 | tail -5
```

Expected output (look for the Fleet API line):

```
INFO :      Starting Flower server, config: ...
INFO :      Starting Fleet API (gRPC-rere) on 0.0.0.0:9092
INFO :      Starting Control API on 0.0.0.0:9093
```

### 3.2 Check the SuperNodes

```bash
ssh root@172.16.100.4 docker logs flower-supernode 2>&1 | tail -3
ssh root@172.16.100.5 docker logs flower-supernode 2>&1 | tail -3
```

Expected output (for each SuperNode):

```
INFO :      Starting insecure HTTP channel to 172.16.100.3:9092
```

> **Note:** If you rebuilt images and SSH refuses to connect with a host key warning, clear the old key:
> ```bash
> ssh-keygen -R 172.16.100.3
> ssh-keygen -R 172.16.100.4
> ssh-keygen -R 172.16.100.5
> ```

---

## Step 4 of 6: Run Federated Training

**Time:** ~7 minutes (includes CIFAR-10 download on first run)

The `demo/` directory contains three independent Flower projects -- one per ML framework. Each trains a CIFAR-10 image classifier using **FedAvg** (Federated Averaging), where SuperNodes train locally and only send model weights back to the SuperLink for aggregation. Raw images never leave the VMs.

| Demo | Model | Params | Best for |
|------|-------|--------|----------|
| `demo/pytorch/` | SimpleCNN (2 conv + 2 FC layers) | ~878K | GPU training, computer vision |
| `demo/tensorflow/` | Keras Sequential CNN | ~880K | Keras ecosystem, quick prototyping |
| `demo/sklearn/` | MLPClassifier (3072→512→10) | ~1.6M | Tabular data, lightweight |

All three share the same `server_app.py` (FedAvg strategy, framework-agnostic).

### 4.1 Pick a framework and install

Choose one that matches the `ONEAPP_FL_FRAMEWORK` your SuperNodes are running:

```bash
# PyTorch (default)
cd demo/pytorch

# Or TensorFlow
cd demo/tensorflow

# Or scikit-learn
cd demo/sklearn
```

Set up a venv and install:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```

### 4.2 Configure the SuperLink address

Edit the `pyproject.toml` in your chosen demo directory:

```toml
[tool.flwr.federations.opennebula]
address = "<superlink-ip>:9093"
insecure = true
```

### 4.3 Run training

```bash
flwr run . opennebula
```

`flwr run` ships the code as a FAB (Flower App Bundle) to the SuperLink, which distributes it to the SuperNodes. When you change Python code, just run `flwr run` again -- no need to rebuild Docker images.

Expected output:

```
Loading project configuration...
Success
```

### 4.4 Monitor training progress

Watch the SuperLink logs in real time:

```bash
ssh root@$SUPERLINK_IP "docker logs -f flower-superlink 2>&1" \
    | grep -E "ROUND|aggregate|History|loss|finished"
```

The first run downloads CIFAR-10 (~170 MB) on each SuperNode. Subsequent runs use the cached dataset. Training takes ~2 minutes per round on 2 vCPU.

> **Note:** Running from your laptop instead of the frontend? Open an SSH tunnel:
> ```bash
> ssh -N -L 9093:<superlink-ip>:9093 root@<frontend-ip>
> ```
> Then use the default address (`127.0.0.1:9093`) in `pyproject.toml`.

---

## Step 5 of 6: Interpret Results

After 3 rounds of FedAvg with 2 clients, the SuperLink logs will show:

```
INFO :      Starting Flower ServerApp, config: num_rounds=3, no round_timeout
INFO :
INFO :      [ROUND 1]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :
INFO :      [ROUND 2]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :
INFO :      [ROUND 3]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :
INFO :      Run finished 3 round(s)
INFO :
INFO :      History (loss, distributed):
INFO :          round 1: 1.27
INFO :          round 2: 1.03
INFO :          round 3: 0.94
```

### What this means

- **Loss dropping 1.27 to 0.94** -- the model is learning collaboratively across both nodes
- **0 failures** -- both SuperNodes completed every round successfully
- **Only model weights (~3.5 MB) crossed the network** -- 25,000 raw training images stayed on each VM
- **Total training time: ~7 minutes** for 3 rounds on 2 vCPU per node

### Tuning for better accuracy

Edit the `pyproject.toml` in your demo directory to increase rounds or local training:

```toml
[tool.flwr.app.config]
num-server-rounds = 10    # more rounds of communication
local-epochs = 2          # more local training per round
batch-size = 32
```

With 10 rounds and 2 local epochs, expect ~65-70% accuracy on CIFAR-10.

---

## Step 6 of 6: Monitor with Dashboard

**Time:** ~1 minute

The project includes a real-time monitoring dashboard built with FastAPI and animated SVG topology visualization.

### 6.1 Start the dashboard

From the frontend, install dependencies and launch:

```bash
source /opt/flwr-env/bin/activate
pip install fastapi uvicorn
cd dashboard
python -m uvicorn app:app --host 0.0.0.0 --port 8080 &
```

### 6.2 Access the dashboard

Open your browser to:

```
http://<frontend-ip>:8080
```

Or through an SSH tunnel:

```bash
ssh -N -L 8080:<frontend-ip>:8080 root@<frontend-ip>
# Then open http://localhost:8080
```

The dashboard displays:

- **Cluster topology** -- animated SVG showing SuperLink and SuperNode connections
- **VM status** -- running/stopped state for each node
- **Training metrics** -- per-round loss and accuracy as training progresses
- **Dark/light mode** -- toggle for your preference

> **Note:** The dashboard reads cluster state from OpenNebula CLI and Docker container logs via SSH. It requires SSH access to each VM, which is already configured if you completed the previous steps.

---

## Cleanup

Delete the OneFlow service when finished. This terminates all VMs and stops all containers.

```bash
oneflow delete <service-id>
```

To also remove the service template, VM templates, and images:

```bash
oneflow-template delete <service-template-id>
onetemplate delete <superlink-template-id>
onetemplate delete <supernode-template-id>
oneimage delete "Flower SuperLink v1.25.0"
oneimage delete "Flower SuperNode v1.25.0"
```

---

<details>
<summary><strong>Troubleshooting</strong></summary>

### VM and Network Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| VM stuck in `BOOT` | Contextualization failed | Check `onevm show <id>` for errors. Ensure CONTEXT has `NETWORK=YES`. |
| VMs unreachable from frontend | Bridge network missing gateway IP | Assign the gateway: `ip addr add <gateway-ip>/24 dev <bridge>` and add NAT: `iptables -t nat -A POSTROUTING -s <subnet> ! -d <subnet> -j MASQUERADE`. |
| SSH `Permission denied` | Missing SSH key in CONTEXT | Ensure the template has `SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"` and your user has a key set via `oneuser update`. |
| SSH `Host key verification failed` | Image was rebuilt, SSH host key changed | Clear the old key: `ssh-keygen -R <vm-ip>` and retry. |

### Container and Service Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `flower-supernode` container not starting | systemd service failed | Check status: `ssh root@<ip> systemctl status flower-supernode`. Check logs: `ssh root@<ip> journalctl -u flower-supernode -n 30`. |
| SuperNode cannot reach SuperLink | Wrong IP or no shared network | Verify IPs with `onevm show <id>`. Confirm both VMs are on the same virtual network. |
| `flower-superlink` service enters restart loop | Stale state or port conflict | Stop and clean up: `ssh root@<superlink-ip> "systemctl stop flower-superlink && docker rm -f flower-superlink && systemctl start flower-superlink"`. |

### Training Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `flwr run` returns `Connection refused` | Wrong address in `pyproject.toml` | Ensure address is `<superlink-ip>:9093`. If using SSH tunnel, check the tunnel is active. |
| `bytes_sent/bytes_recv cannot be zero` | gRPC state corruption in Flower 1.25.0 | Clear SuperLink state and restart all nodes: `ssh root@<superlink-ip> "systemctl stop flower-superlink && rm -f /opt/flower/state/state.db && systemctl start flower-superlink"`. Then restart both SuperNodes (see below). |
| `file is not a database` in SuperLink logs | Corrupted SQLite state DB | Same fix as above: stop SuperLink, delete `state.db`, restart. |
| SuperNodes stuck after SuperLink restart | Old node IDs are invalid in the new state DB | After restarting the SuperLink, you **must** also restart both SuperNodes: `ssh root@<supernode-ip> systemctl restart flower-supernode`. |
| `min_available_clients=2` timeout | SuperNode(s) not connected | Check containers on each SuperNode: `ssh root@<ip> docker ps`. Restart if needed: `ssh root@<ip> systemctl restart flower-supernode`. |
| Shape mismatch or import errors | Wrong appliance image version | Rebuild with Packer and re-upload. See [BUILD.md](BUILD.md). |
| Very low accuracy (< 20% after 3 rounds) | Insufficient training | Increase `num-server-rounds` to 10 and `local-epochs` to 2 in `pyproject.toml`. |

### Image Upload Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `oneimage create` fails with permission error | Image file is in a restricted directory | OpenNebula's `RESTRICTED_DIRS` blocks `/root` by default. Copy the file: `cp /root/image.qcow2 /var/tmp/` and update the path. |
| Image stuck in `LOCKED` state | Upload still in progress or failed | Wait 5 minutes. If still locked: `oneimage delete <id>` and retry. |

</details>

---

## What's Next?

You have a working federated learning cluster.

**Try another framework** -- Switch SuperNodes to TensorFlow or scikit-learn by setting `ONEAPP_FL_FRAMEWORK` and rebooting. Then run the matching demo from `demo/tensorflow/` or `demo/sklearn/`.

**Try a different aggregation strategy** -- Swap FedAvg for FedProx (better with non-IID data) or FedAdam (adaptive learning rates) by changing one import in `server_app.py`. See [`demo/README.md`](../demo/README.md) for code examples.

**Scale up** -- Add more SuperNodes with `oneflow scale <service-id> supernode 5`. Each new node joins the federation automatically.

**Enable TLS** -- Set `ONEAPP_FL_TLS_ENABLED=YES` in the VM CONTEXT. The SuperLink auto-generates certificates and distributes the CA via OneGate.

**Enable GPU** -- Set `ONEAPP_FL_GPU_ENABLED=YES` on SuperNode VMs with PCI-passthrough GPUs. Requires host-level IOMMU setup.
