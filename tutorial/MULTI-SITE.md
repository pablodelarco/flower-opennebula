# Multi-Site Federated Learning with Tailscale

> Connect SuperNodes across hospitals, data centers, or cloud regions — without VPNs, firewall rules, or public IPs.

---

## The Problem

In a real federation, each SuperNode sits in a different organization's network. They can't reach each other or the SuperLink directly — different LANs, firewalls, NATs.

```
Hospital A (LAN 10.0.1.0/24)        Hospital B (LAN 192.168.5.0/24)
┌──────────────┐                     ┌──────────────┐
│ SuperLink    │        ???          │ SuperNode    │
│ 10.0.1.50    │◄── no route ──────►│ 192.168.5.20 │
└──────────────┘                     └──────────────┘
```

The spec ([spec/12-multi-site-federation.md](../spec/12-multi-site-federation.md)) describes two options: raw WireGuard tunnels or public IP exposure. Both require manual key exchange, gateway VMs, firewall rules, and routing config.

[Tailscale](https://tailscale.com/) eliminates all of that.

## How Tailscale Solves It

Tailscale is a mesh VPN built on WireGuard. Every device that joins your tailnet gets a stable `100.x.y.z` IP reachable from any other device in the tailnet — regardless of NAT, firewalls, or network topology.

```
Hospital A                         Hospital B                      Hospital C
┌──────────────┐                   ┌──────────────┐                ┌──────────────┐
│ SuperLink    │                   │ SuperNode #1 │                │ SuperNode #2 │
│ ts: 100.64.0.1│◄── tailnet ────►│ ts: 100.64.0.2│◄── mesh ────►│ ts: 100.64.0.3│
└──────────────┘   (encrypted,     └──────────────┘                └──────────────┘
                    NAT-punching)

FL_SUPERLINK_ADDRESS = 100.64.0.1:9092
```

No gateway VMs. No firewall rules. No key exchange. No routing config.

---

## Prerequisites

- A [Tailscale account](https://login.tailscale.com/start) (free for up to 100 devices)
- An **auth key** from the Tailscale admin console:
  1. Go to **Settings → Keys → Generate auth key**
  2. Enable **Reusable** (so multiple VMs can use the same key)
  3. Optionally enable **Ephemeral** (nodes auto-deregister when they shut down)
  4. Copy the key (`tskey-auth-...`)
- SSH access to each VM (SuperLink and SuperNodes)

---

## Step 1: Install Tailscale on the SuperLink VM

SSH into the SuperLink VM and install Tailscale:

```bash
ssh root@<superlink-ip>

curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-<YOUR_KEY> --hostname=flower-superlink
```

Note the Tailscale IP:

```bash
tailscale ip -4
# Example: 100.64.0.1
```

This is the address remote SuperNodes will connect to.

## Step 2: Install Tailscale on Each SuperNode VM

On each SuperNode (at each hospital/site):

```bash
ssh root@<supernode-ip>

curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey=tskey-auth-<YOUR_KEY> --hostname=flower-supernode-1
```

Verify connectivity:

```bash
# From the SuperNode, ping the SuperLink's Tailscale IP
ping -c 3 100.64.0.1

# Or use the MagicDNS name
ping -c 3 flower-superlink
```

## Step 3: Configure SuperNodes to Use the Tailscale Address

Since the SuperNodes are on different networks, OneGate auto-discovery won't work. Set the SuperLink address explicitly.

**Option A: At VM deployment time** (CONTEXT variable)

When creating or updating the SuperNode VM template:

```
ONEAPP_FL_SUPERLINK_ADDRESS = 100.64.0.1:9092
```

Then reboot the SuperNode for the appliance to pick it up:

```bash
onevm reboot <supernode-vm-id>
```

**Option B: On a running SuperNode** (restart the container)

```bash
ssh root@<supernode-tailscale-ip>

# Edit the SuperNode environment
sed -i 's|SUPERLINK_ADDRESS=.*|SUPERLINK_ADDRESS=100.64.0.1:9092|' /opt/flower/config/supernode.env

# Restart the service
systemctl restart flower-supernode
```

**Option C: MagicDNS** (if enabled in your tailnet)

```
ONEAPP_FL_SUPERLINK_ADDRESS = flower-superlink:9092
```

## Step 4: Run Training

From any machine with access to the SuperLink (including via Tailscale):

```bash
cd demo/pytorch
pip install -e .

# Edit pyproject.toml — use the Tailscale IP
# [tool.flwr.federations.opennebula]
# address = "100.64.0.1:9093"

flwr run . opennebula
```

---

## Do I Still Need TLS?

Tailscale already encrypts all traffic with WireGuard. So TLS is **defense-in-depth** rather than strictly required.

| Scenario | Recommendation |
|----------|---------------|
| Internal testing / PoC | `FL_TLS_ENABLED=NO` is fine — Tailscale encrypts the transport |
| Production / compliance | `FL_TLS_ENABLED=YES` — defense-in-depth, audit requirements |

If you do enable TLS, the auto-generated certificate's SAN will contain the VM's local IP. Since SuperNodes connect via the Tailscale IP, you'll get a SAN mismatch. Fix it with:

```
ONEAPP_FL_CERT_EXTRA_SAN = IP:100.64.0.1
```

Or just skip TLS — Tailscale is already WireGuard.

---

## Tailscale ACLs (Access Control)

For production, lock down which devices can reach the SuperLink's Fleet API using [Tailscale ACLs](https://tailscale.com/kb/1018/acls):

```json
{
  "acls": [
    {
      "action": "accept",
      "src": ["tag:supernode"],
      "dst": ["tag:superlink:9092,9093"]
    }
  ],
  "tagOwners": {
    "tag:superlink":  ["autogroup:admin"],
    "tag:supernode":  ["autogroup:admin"]
  }
}
```

Then tag devices when joining:

```bash
# SuperLink
tailscale up --authkey=tskey-auth-<KEY> --hostname=flower-superlink --advertise-tags=tag:superlink

# SuperNodes
tailscale up --authkey=tskey-auth-<KEY> --hostname=flower-supernode-1 --advertise-tags=tag:supernode
```

---

## Comparison: Tailscale vs Raw WireGuard vs Public IP

| | Tailscale | WireGuard | Public IP |
|---|---|---|---|
| Setup per site | `curl + tailscale up` | Gateway VM, wg0.conf, keys, routing | NAT/firewall rules |
| Key management | Automatic | Manual exchange | N/A (TLS certs instead) |
| NAT traversal | Built-in (DERP relay fallback) | Manual (port forwarding) | Requires public IP |
| Firewall rules | None | UDP 51820 | TCP 9092 inbound |
| MagicDNS | Yes | No | No |
| ACLs | Built-in web UI | iptables | Firewall rules |
| Encryption | WireGuard (automatic) | WireGuard (manual) | TLS only |
| Cost | Free up to 100 devices | Free | Free |
| Best for | Most deployments | Air-gapped / no SaaS | 2-site PoC |

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `tailscale up` hangs | Check internet access. Tailscale needs HTTPS outbound to coordination servers. |
| Nodes don't see each other | Verify both are on the same tailnet: `tailscale status` on both. |
| High latency between sites | Check `tailscale netcheck` — if using DERP relay, direct connection failed. Open UDP 41641 outbound. |
| SuperNode can't connect to SuperLink | Verify `tailscale ping flower-superlink` works. Check `FL_SUPERLINK_ADDRESS` uses the Tailscale IP. |
| TLS SAN mismatch | Set `ONEAPP_FL_CERT_EXTRA_SAN=IP:<tailscale-ip>` on the SuperLink, or disable TLS (Tailscale encrypts). |

---

## References

- [Tailscale Quickstart](https://tailscale.com/kb/1017/install)
- [Tailscale Auth Keys](https://tailscale.com/kb/1085/auth-keys)
- [Tailscale ACLs](https://tailscale.com/kb/1018/acls)
- [Multi-site federation spec](../spec/12-multi-site-federation.md) (WireGuard / public IP approach)
