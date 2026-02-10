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
| SuperNode (x2) | 2 | 4 GB | 10 GB |

---

## Prerequisites

- SSH access to the OpenNebula frontend (all commands run there)
- OpenNebula CLI configured on the frontend (`oneimage`, `onetemplate`, `onevm`)
- Python 3.11+ and `pip` on the frontend (for `flwr run`)
- SSH key registered in your OpenNebula user profile
- Pre-built appliance images uploaded to OpenNebula (see [BUILD.md](BUILD.md)
  for how to build them with Packer, or import them from the marketplace)
- VMs can reach each other and the internet (for CIFAR-10 download)

---

## Step 1: Upload Images and Create Templates

If the appliance images aren't already in your datastore, upload them:

```bash
# Upload the QCOW2 images built by Packer (see BUILD.md)
oneimage create \
    --name "Flower SuperLink v1.25.0" \
    --path /path/to/flower-superlink.qcow2 \
    --type OS --driver qcow2 --datastore default

oneimage create \
    --name "Flower SuperNode v1.25.0" \
    --path /path/to/flower-supernode.qcow2 \
    --type OS --driver qcow2 --datastore default

# Wait for READY state
watch -n 5 'oneimage list | grep Flower'
```

Create VM templates for each role:

```bash
# SuperLink template
onetemplate create <<'EOF'
NAME = "Flower SuperLink"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperLink v1.25.0" ]
NIC = [ NETWORK_ID = <vnet-id> ]
CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF

# SuperNode template
onetemplate create <<'EOF'
NAME = "Flower SuperNode"
CPU = 2
VCPU = 2
MEMORY = 4096
DISK = [ IMAGE = "Flower SuperNode v1.25.0" ]
NIC = [ NETWORK_ID = <vnet-id> ]
CONTEXT = [
  TOKEN = "YES",
  NETWORK = "YES",
  REPORT_READY = "YES",
  SSH_PUBLIC_KEY = "$USER[SSH_PUBLIC_KEY]"
]
EOF
```

Note the template IDs from the output.

---

## Step 2: Deploy the Cluster

Instantiate the SuperLink first, then the SuperNodes. The appliance boot
sequence handles everything: Docker starts, the Flower container launches via
systemd, and SuperNodes auto-discover the SuperLink.

```bash
# Start SuperLink
onetemplate instantiate <superlink-template-id> --name flower-superlink

# Wait for it to reach RUNNING and note its IP
onevm list -l ID,NAME,STAT,IP
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
# SuperLink: check container and Fleet API
ssh root@<superlink-ip> docker ps
ssh root@<superlink-ip> docker logs flower-superlink 2>&1 | tail -5
# Look for: "started gRPC server on 0.0.0.0:9092"

# SuperNodes: check containers connected to SuperLink
for IP in <supernode-1-ip> <supernode-2-ip>; do
  echo "--- ${IP} ---"
  ssh root@${IP} docker logs flower-supernode 2>&1 | tail -3
done
# Look for: "Opened insecure gRPC connection"
```

---

## Step 4: Run Federated Training

`flwr run` submits the training job to the SuperLink's Control API (port 9093).
Run it **on the OpenNebula frontend**, which can reach the SuperLink directly.

First, update `demo/pyproject.toml` with your SuperLink IP:

```toml
[tool.flwr.federations.opennebula]
address = "<superlink-ip>:9093"
insecure = true
```

Then install the demo and run:

```bash
# On the OpenNebula frontend
cd demo
pip install -e .
flwr run . opennebula
```

The first run downloads CIFAR-10 (~170 MB) on each SuperNode. Subsequent runs
use the cached dataset. Training takes ~5 minutes per round on 1 vCPU.

> **Running from your laptop instead?** Open an SSH tunnel:
> `ssh -N -L 9093:<superlink-ip>:9093 root@<frontend-ip>` and use the default
> address (`127.0.0.1:9093`) in `pyproject.toml`.

---

## Step 5: Interpret Results

Expected output after 3 rounds:

```
INFO : Starting Flower ServerApp
INFO : [ROUND 1]
INFO : configure_fit: strategy sampled 2 clients (out of 2)
INFO : aggregate_fit: received 2 results and 0 failures
INFO : [ROUND 2]
INFO : aggregate_fit: received 2 results and 0 failures
INFO : [ROUND 3]
INFO : aggregate_fit: received 2 results and 0 failures
INFO : Run finished 3 round(s)
INFO : History (loss, distributed):
INFO :     round 1: 1.34
INFO :     round 2: 1.03
INFO :     round 3: 0.95
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
| `flower-supernode` container not starting | systemd service failed | `ssh root@<ip> systemctl status flower-supernode` for details |
| Shape mismatch / import errors | Wrong appliance image version | Rebuild with Packer and re-upload (see [BUILD.md](BUILD.md)) |
| `file is not a database` in SuperLink | Corrupted state DB | `ssh root@<superlink-ip> systemctl restart flower-superlink` |
| `flwr run` connection refused | Wrong address in pyproject.toml | Ensure address matches `<superlink-ip>:9093` |

---

## Next Steps

- **OneFlow orchestration** — Deploy the whole cluster with one command.
  See [BUILD.md Section 6-7](BUILD.md#6-creating-the-oneflow-service-template).
- **TLS encryption** — Enable mTLS for all gRPC channels via CONTEXT variables.
  See [`../spec/03-security-hardening.md`](../spec/03-security-hardening.md).
- **GPU passthrough** — Add `ONEAPP_FL_GPU_ENABLED=YES` to SuperNode CONTEXT.
  See [`../spec/10-gpu-passthrough.md`](../spec/10-gpu-passthrough.md).
- **Monitoring** — Enable Prometheus metrics with `ONEAPP_FL_METRICS_ENABLED=YES`.
  See [`../spec/12-monitoring.md`](../spec/12-monitoring.md).
- **Scaling** — Add more SuperNodes by instantiating additional VMs from the
  template, or use OneFlow auto-scaling policies.
