# Quick Start: Federated Learning on OpenNebula

Deploy a working Flower federated learning cluster on OpenNebula in ~15 minutes.
You'll instantiate 3 VMs from pre-built appliance images, and the cluster
assembles itself — Docker, systemd services, and SuperNode-to-SuperLink
discovery all happen automatically at boot.

```
  OpenNebula Frontend
 ┌────────────────────────────────────────────────────────────┐
 │                                                            │
 │  You are here (SSH)              Flower Cluster (VMs)      │
 │  ┌──────────────┐         ┌───────────────────────────┐   │
 │  │              │         │  ┌──────────┐              │   │
 │  │  flwr run .  │────────>│  │ SuperLink │◄──┐          │   │
 │  │  (demo/)     │  :9093  │  │ :9092     │   │ weights  │   │
 │  │              │         │  │ :9093     │   │ (~3.5MB) │   │
 │  └──────────────┘         │  └──────────┘   │          │   │
 │                           │       ▲         ▼          │   │
 │                           │  ┌────┴─────┐ ┌──────────┐ │   │
 │                           │  │SuperNode │ │SuperNode │ │   │
 │                           │  │  VM #1   │ │  VM #2   │ │   │
 │                           │  │ [data]   │ │ [data]   │ │   │
 │                           │  └──────────┘ └──────────┘ │   │
 │                           └───────────────────────────────┘   │
 └────────────────────────────────────────────────────────────┘
```

**Where does each component run?**

| What | Where | Why |
|------|-------|-----|
| `oneimage`, `onetemplate`, `onevm` | Frontend shell | OpenNebula CLI manages VMs |
| `flwr run . opennebula` | Frontend shell | Submits training job to SuperLink |
| SuperLink container | SuperLink VM | Coordinates rounds, aggregates weights |
| SuperNode containers | SuperNode VMs | Train locally on private data |

**Time:** ~15 minutes | **VMs:** 3 | **Result:** 3-round FedAvg on CIFAR-10

| VM Role | vCPU | RAM | Disk |
|---------|------|-----|------|
| SuperLink | 2 | 4 GB | 10 GB |
| SuperNode (x2) | 2 | 4 GB | 20 GB |

---

## Prerequisites

- SSH access to the OpenNebula frontend (all commands run there)
- OpenNebula CLI configured on the frontend (`oneimage`, `onetemplate`, `onevm`)
- Python 3.11+ and `pip` on the frontend (for `flwr run`)
- SSH key registered in your OpenNebula user profile (`oneuser update oneadmin --append 'SSH_PUBLIC_KEY="<your-key>"'`)
- Pre-built appliance images uploaded to OpenNebula (see [BUILD.md](BUILD.md)
  for how to build them with Packer, or import them from the marketplace)
- A virtual network where VMs can reach each other and the internet (for
  CIFAR-10 download). If using a bridge-type network, ensure the gateway IP
  is assigned to the bridge interface on the host:
  ```bash
  ip addr add 172.20.0.1/24 dev <bridge-name>
  iptables -t nat -A POSTROUTING -s 172.20.0.0/24 ! -d 172.20.0.0/24 -j MASQUERADE
  ```

---

## Step 1: Upload Images and Create Templates

If the appliance images aren't already in your datastore, upload them:

```bash
# Upload the QCOW2 images built by Packer (see BUILD.md)
# Use a template file for each image:
cat > /tmp/superlink-img.tmpl <<'TMPL'
NAME = "Flower SuperLink v1.25.0"
TYPE = OS
PATH = /path/to/flower-superlink.qcow2
FORMAT = qcow2
TMPL
oneimage create -d default /tmp/superlink-img.tmpl

cat > /tmp/supernode-img.tmpl <<'TMPL'
NAME = "Flower SuperNode v1.25.0"
TYPE = OS
PATH = /path/to/flower-supernode.qcow2
FORMAT = qcow2
TMPL
oneimage create -d default /tmp/supernode-img.tmpl

# Wait for READY state
watch -n 5 'oneimage list | grep Flower'
```

Create VM templates for each role:

```bash
# SuperLink template
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
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
onetemplate create /tmp/superlink.tmpl

# SuperNode template
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
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
onetemplate create /tmp/supernode.tmpl
```

Note the template IDs from the output.

---

## Step 2: Deploy the Cluster

Instantiate the SuperLink first, then the SuperNodes. The appliance boot
sequence handles everything: Docker starts, the Flower container launches via
systemd, and SuperNodes connect to the SuperLink.

```bash
# Start SuperLink
onetemplate instantiate <superlink-template-id> --name flower-superlink

# Wait for it to reach RUNNING and note its IP
watch -n 5 'onevm list | grep flower'
```

Once the SuperLink is RUNNING, get its IP:

```bash
onevm show <superlink-vm-id> | grep PRIVATE
```

Now start SuperNodes, telling them where to find the SuperLink via the
`ONEAPP_FL_SUPERLINK_ADDRESS` context variable:

```bash
# Start SuperNode 1
onetemplate instantiate <supernode-template-id> --name flower-supernode-1 \
    --context ONEAPP_FL_SUPERLINK_ADDRESS=<superlink-ip>:9092

# Start SuperNode 2
onetemplate instantiate <supernode-template-id> --name flower-supernode-2 \
    --context ONEAPP_FL_SUPERLINK_ADDRESS=<superlink-ip>:9092
```

Wait for all VMs to reach RUNNING (~1-2 minutes):

```bash
watch -n 5 'onevm list | grep flower'
```

> **Using OneFlow instead?** A single command deploys the whole cluster with
> automatic sequencing (SuperLink boots first, SuperNodes discover it via
> OneGate). See [BUILD.md Section 6-7](BUILD.md#6-creating-the-oneflow-service-template).

---

## Step 3: Verify the Cluster

The appliance images boot with Docker and systemd services pre-configured.
The SuperNode image includes PyTorch and all ML dependencies pre-baked.
Verify all containers are running:

```bash
# Use onevm ssh to access VMs (syntax: onevm ssh <vmid> root)
onevm ssh <superlink-vm-id> root --cmd "docker ps"
onevm ssh <superlink-vm-id> root --cmd "docker logs flower-superlink 2>&1 | tail -5"
# Look for: "Starting Fleet API (gRPC-rere) on 0.0.0.0:9092"

# SuperNodes: check containers connected to SuperLink
onevm ssh <supernode-1-vm-id> root --cmd "docker logs flower-supernode 2>&1 | tail -3"
onevm ssh <supernode-2-vm-id> root --cmd "docker logs flower-supernode 2>&1 | tail -3"
# Look for: "Starting insecure HTTP channel to <superlink-ip>:9092"
```

Or via direct SSH from the frontend:

```bash
ssh root@<superlink-ip> docker ps
ssh root@<supernode-1-ip> docker logs flower-supernode 2>&1 | tail -3
```

---

## Step 4: Run Federated Training

`flwr run` submits the training job to the SuperLink's Control API (port 9093).
Run it **on the OpenNebula frontend**, which can reach the SuperLink directly.

First, install Flower in a virtual environment and set up the demo:

```bash
# Create a virtual environment with Flower and PyTorch
python3 -m venv /opt/flwr-env
source /opt/flwr-env/bin/activate
pip install "flwr[simulation]>=1.25.0" torch==2.6.0 torchvision==0.21.0 "flwr-datasets[vision]>=0.4.0"
```

Update `demo/pyproject.toml` with your SuperLink IP:

```toml
[tool.flwr.federations.opennebula]
address = "<superlink-ip>:9093"
insecure = true
```

Then install the demo and run:

```bash
cd demo
pip install -e .
flwr run . opennebula
```

The `flwr run` command is non-blocking — it submits the job and returns a run
ID. Monitor progress from the SuperLink logs:

```bash
# Watch training progress
ssh root@<superlink-ip> "docker logs -f flower-superlink 2>&1" | grep -E "ROUND|aggregate|History|loss|finished"
```

The first run downloads CIFAR-10 (~170 MB) on each SuperNode. Subsequent runs
use the cached dataset. Training takes ~5 minutes per round on 2 vCPU.

> **Running from your laptop instead?** Open an SSH tunnel:
> `ssh -N -L 9093:<superlink-ip>:9093 root@<frontend-ip>` and use the default
> address (`127.0.0.1:9093`) in `pyproject.toml`.

---

## Step 5: Interpret Results

Expected output after 3 rounds (from the SuperLink logs):

```
INFO :      Starting Flower ServerApp, config: num_rounds=3, no round_timeout
INFO :      [ROUND 1]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :      [ROUND 2]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :      [ROUND 3]
INFO :      configure_fit: strategy sampled 2 clients (out of 2)
INFO :      aggregate_fit: received 2 results and 0 failures
INFO :      aggregate_evaluate: received 2 results and 0 failures
INFO :      Run finished 3 round(s)
INFO :      	History (loss, distributed):
INFO :      		round 1: 1.30
INFO :      		round 2: 1.06
INFO :      		round 3: 0.95
```

- **Loss dropping from ~1.3 to ~0.95** across 3 rounds confirms the model is
  learning collaboratively
- Only model weights (~3.5 MB) crossed the network — raw images stayed on each VM
- Increase `num-server-rounds` or `local-epochs` in `pyproject.toml` for better
  accuracy

---

## Cleanup

```bash
# Terminate all VMs (containers stop automatically)
onevm terminate <superlink-vm-id>
onevm terminate <supernode-1-vm-id>
onevm terminate <supernode-2-vm-id>
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| VM stuck in BOOT | Contextualization failed | Check `onevm show <id>` for errors; ensure CONTEXT has `NETWORK=YES` |
| SuperNode can't reach SuperLink | Wrong IP or missing network | Verify IPs with `onevm show`; check VMs share a virtual network |
| `flower-supernode` container not starting | systemd service failed | `onevm ssh <id> root --cmd "systemctl status flower-supernode"` |
| `bytes_sent/bytes_recv cannot be zero` | SuperLink gRPC state error | Restart SuperLink and clear state: `systemctl stop flower-superlink && rm -f /opt/flower/state/state.db && systemctl start flower-superlink` |
| Shape mismatch / import errors | Wrong appliance image version | Rebuild with Packer and re-upload (see [BUILD.md](BUILD.md)) |
| `file is not a database` in SuperLink | Corrupted state DB | `ssh root@<superlink-ip> systemctl restart flower-superlink` |
| `flwr run` connection refused | Wrong address in pyproject.toml | Ensure address matches `<superlink-ip>:9093` |
| VMs unreachable from frontend | Bridge missing gateway IP | `ip addr add <gateway-ip>/24 dev <bridge>` on the host |
| SSH `Permission denied` | Missing SSH key in CONTEXT | Ensure template has `SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"` and your user has a key set |

---

## Next Steps

- **OneFlow orchestration** — Deploy the whole cluster with one command.
  See [BUILD.md Section 6-7](BUILD.md#6-creating-the-oneflow-service-template).
- **TLS encryption** — Enable mTLS for all gRPC channels via CONTEXT variables.
  See [`../spec/03-security-hardening.md`](../spec/03-security-hardening.md).
- **GPU passthrough** — Add `ONEAPP_FL_GPU_ENABLED=YES` to SuperNode CONTEXT.
  See [`../spec/10-gpu-passthrough.md`](../spec/10-gpu-passthrough.md).
- **Monitoring** — Flower 1.25.0 does not expose native Prometheus metrics.
  To monitor training, add `prometheus_client` gauges to your ServerApp
  strategy (see the [flower-via-docker-compose](https://github.com/adap/flower/tree/main/examples/flower-via-docker-compose)
  example) or use container-level metrics via cAdvisor.
- **Scaling** — Add more SuperNodes by instantiating additional VMs from the
  template, or use OneFlow auto-scaling policies.
