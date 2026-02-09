# Phase 7: Multi-Site Federation - Research

**Researched:** 2026-02-09
**Domain:** Cross-zone Flower federation on OpenNebula with WAN networking, gRPC keepalive, and TLS trust distribution
**Confidence:** HIGH (gRPC keepalive, TLS trust model), MEDIUM (OpenNebula federation/zone architecture, WireGuard networking), LOW (OpenNebula VXLAN cross-zone, Flower gRPC channel customization for keepalive)

## Summary

This research covers deploying a Flower federated learning cluster across multiple OpenNebula zones -- SuperLink in one zone, SuperNodes distributed across remote zones, connected over WAN. The spec must address four domains: (1) multi-site topology and how it interacts with OpenNebula federation's zone-local service constraints, (2) cross-zone networking options that give SuperNodes IP reachability to the SuperLink, (3) gRPC keepalive tuning to survive stateful firewall and load balancer idle timeouts on WAN paths, and (4) TLS certificate trust distribution across zones where OneGate is zone-local and cannot distribute the CA certificate cross-zone.

The critical architectural constraint is that **OneGate and OneFlow are zone-local services** -- they cannot operate across zone boundaries in an OpenNebula federation. This means the single-site OneFlow service template (Phase 4) cannot orchestrate a cross-zone deployment as a single service. Each zone must have its own OneFlow service or standalone VM deployments. SuperNode discovery via OneGate is unavailable cross-zone; the static `FL_SUPERLINK_ADDRESS` path (already specified in Phases 1-2) becomes mandatory for remote SuperNodes.

Flower's gRPC architecture is naturally suited to WAN deployment: SuperNodes initiate outbound-only connections to the SuperLink, which means only the SuperLink needs an inbound-reachable address. Flower already has a 210-second keepalive default (PR #1069, merged 2022), but WAN paths through stateful firewalls may require additional tuning. The spec should define explicit gRPC keepalive channel options via contextualization variables.

For TLS, the self-signed CA model from Phase 2 works cross-zone with one key change: the CA certificate must be distributed out-of-band (via `FL_SSL_CA_CERTFILE` CONTEXT variable) since OneGate cannot serve it cross-zone. The operator-provided certificate path is equally viable and may be preferred for multi-site where organizations have existing PKI.

**Primary recommendation:** Structure the spec as three sub-topics: (1) deployment topology and per-zone orchestration model, (2) cross-zone networking with two options (WireGuard site-to-site VPN and direct public IP), (3) gRPC keepalive + TLS trust as a combined connection resilience section. Use the 3-zone reference deployment (1 SuperLink zone + 2 SuperNode zones) as the narrative thread throughout.

## Standard Stack

### Core

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| OpenNebula Federation (Zones) | 7.0+ | Multi-site cloud management with shared users/groups | Native OpenNebula mechanism for multi-datacenter. Shared user accounts and marketplace across zones. |
| WireGuard | kernel module (5.6+) | Site-to-site VPN for cross-zone private networking | In-kernel, minimal overhead (60-byte IPv4 header), high throughput. Ubuntu 24.04 has native kernel support. |
| gRPC keepalive (Python) | grpcio (bundled with Flower) | Connection liveness over WAN paths | Built into gRPC; Flower already uses 210s default. Configurable via channel options. |
| TLS with shared CA | OpenSSL (Phase 2) | Cross-zone encrypted gRPC with trust chain | Phase 2 CA generation already produces the artifacts. Cross-zone just changes distribution method. |

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| Direct public IP | N/A | Alternative to VPN for simpler topologies | When SuperLink has a public/routable IP and firewall rules permit port 9092 inbound. |
| Operator-provided PKI | External CA | Enterprise TLS certificates for multi-site | Organizations with existing certificate infrastructure that spans data centers. |
| OpenNebula VXLAN + BGP EVPN | 7.0+ | L2 overlay networking across hosts | Only within a single zone or tightly-coupled sites with BGP peering. NOT suitable for WAN cross-zone. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| WireGuard | IPsec (strongSwan) | IPsec is more complex to configure but is the traditional enterprise VPN. WireGuard is simpler, faster, and has kernel-level integration on Ubuntu 24.04. |
| WireGuard | OpenNebula VXLAN/EVPN | VXLAN provides L2 overlay but requires multicast or BGP between sites. Designed for intra-zone, not WAN. Does not provide encryption. |
| Direct public IP | Tailscale/Netmaker mesh | Managed overlay simplifies configuration but adds external dependency. Spec should target the simplest self-hosted options. |
| Self-signed CA | Let's Encrypt / ACME | ACME requires public DNS and HTTP validation. Self-signed CA is better for private infrastructure without internet-facing endpoints. |

## Architecture Patterns

### Pattern 1: 3-Zone Reference Deployment Topology

**What:** The canonical multi-site Flower federation: SuperLink in Zone A, SuperNodes in Zones B and C.

**When to use:** Always -- this is the reference architecture the spec must enable.

```
Zone A (Coordinator)           Zone B (Training Site 1)      Zone C (Training Site 2)
+----------------------+       +----------------------+       +----------------------+
| OpenNebula Zone A    |       | OpenNebula Zone B    |       | OpenNebula Zone C    |
|                      |       |                      |       |                      |
| +------------------+ |       | +------------------+ |       | +------------------+ |
| | SuperLink VM     | |       | | SuperNode VM #1  | |       | | SuperNode VM #3  | |
| | - Fleet API 9092 |<--------| | - gRPC client    | |       | | - gRPC client    | |
| | - CA generated   | |  gRPC | | - Local data     | |       | | - Local data     | |
| | - State DB       | |       | +------------------+ |       | +------------------+ |
| +------------------+ |       | +------------------+ |       | +------------------+ |
|                      |       | | SuperNode VM #2  | |       | | SuperNode VM #4  | |
| OneFlow Service A    |       | | - gRPC client    |--------->| | - gRPC client    | |
| (SuperLink only)     |       | +------------------+ |  gRPC | +------------------+ |
| OneGate (local)      |       |                      |       |                      |
+----------------------+       | OneFlow Service B    |       | OneFlow Service C    |
                               | (SuperNodes only)    |       | (SuperNodes only)    |
                               | OneGate (local)      |       | OneGate (local)      |
                               +----------------------+       +----------------------+

Cross-zone connectivity: WireGuard VPN or Direct Public IP
TLS trust: CA cert distributed via FL_SSL_CA_CERTFILE CONTEXT variable
Discovery: Static FL_SUPERLINK_ADDRESS (OneGate is zone-local)
```

**Key architectural constraints:**
- OneFlow is zone-local: cannot create a single service spanning zones.
- OneGate is zone-local: SuperNodes in Zone B/C cannot query Zone A's OneGate.
- Each zone has its own OneFlow service or standalone VMs.
- Zone A's service: SuperLink role only (singleton, min_vms=1, max_vms=1).
- Zone B/C services: SuperNode role only (no parent dependency, since SuperLink is external).

### Pattern 2: Per-Zone OneFlow Service Templates

**What:** Separate OneFlow service templates for coordinator zone vs training zones.

**When to use:** When deploying multi-site with OneFlow orchestration in each zone.

**Zone A (Coordinator) Service Template:**
```json
{
  "name": "Flower Federation - Coordinator",
  "deployment": "straight",
  "ready_status_gate": true,
  "roles": [
    {
      "name": "superlink",
      "cardinality": 1,
      "min_vms": 1,
      "max_vms": 1,
      "template_id": "<superlink-vm-template>",
      "user_inputs": {
        "FLOWER_VERSION": "O|text|Flower version||1.25.0",
        "FL_TLS_ENABLED": "O|boolean|Enable TLS||YES",
        "FL_NUM_ROUNDS": "O|number|Training rounds||10"
      }
    }
  ]
}
```

**Zone B/C (Training Site) Service Template:**
```json
{
  "name": "Flower Federation - Training Site",
  "deployment": "straight",
  "ready_status_gate": true,
  "roles": [
    {
      "name": "supernode",
      "cardinality": 2,
      "min_vms": 2,
      "max_vms": 10,
      "template_id": "<supernode-vm-template>",
      "user_inputs": {
        "FLOWER_VERSION": "O|text|Flower version||1.25.0",
        "FL_TLS_ENABLED": "O|boolean|Enable TLS||YES",
        "FL_SUPERLINK_ADDRESS": "M|text|SuperLink address (IP:port)",
        "FL_SSL_CA_CERTFILE": "M|text64|CA certificate (base64 PEM)",
        "ML_FRAMEWORK": "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch"
      }
    }
  ]
}
```

**Key differences from single-site template (Phase 4):**
- No `parents` dependency (SuperLink is external to this service).
- `FL_SUPERLINK_ADDRESS` is **mandatory** (not optional) -- no OneGate discovery cross-zone.
- `FL_SSL_CA_CERTFILE` is **mandatory** when `FL_TLS_ENABLED=YES` -- no OneGate CA cert retrieval cross-zone.
- `ready_status_gate` still applies for internal readiness gating (each SuperNode reports ready independently).
- No SuperLink role in the remote zone template.

### Pattern 3: Cross-Zone Networking -- WireGuard Site-to-Site VPN

**What:** Establish a WireGuard tunnel between zone gateway nodes to create private IP reachability across zones.

**When to use:** When SuperLink and SuperNodes are on private networks in different data centers without direct IP reachability.

**Configuration approach:**
```
Zone A Gateway (wg0)              Zone B Gateway (wg0)
10.10.9.0/31                      10.10.9.1/31
Private subnet: 10.10.10.0/24    Private subnet: 10.10.11.0/24
UDP 51820 <-------- WAN --------> UDP 51820

Zone A wg0.conf:
[Interface]
Address = 10.10.9.0/31
ListenPort = 51820
PostUp = wg set %i private-key /etc/wireguard/%i.key

[Peer]
PublicKey = <zone-b-public-key>
AllowedIPs = 10.10.11.0/24, 10.10.9.1/31
Endpoint = <zone-b-public-ip>:51820

Zone B wg0.conf:
[Interface]
Address = 10.10.9.1/31
ListenPort = 51820
PostUp = wg set %i private-key /etc/wireguard/%i.key

[Peer]
PublicKey = <zone-a-public-key>
AllowedIPs = 10.10.10.0/24, 10.10.9.0/31
Endpoint = <zone-a-public-ip>:51820
```

**MTU consideration:** WireGuard adds 60 bytes overhead (IPv4). If the WAN path MTU is 1500, set WireGuard interface MTU to 1420. gRPC/HTTP2 frames are not affected since they are well below typical MTU limits.

**Firewall rule:** Allow UDP port 51820 between gateway public IPs. No additional port openings needed -- Flower gRPC traffic (port 9092) flows over the WireGuard tunnel on private IPs.

### Pattern 4: Cross-Zone Networking -- Direct Public IP

**What:** SuperLink VM gets a public IP or is behind a NAT with port forwarding for port 9092. SuperNodes connect directly over the internet.

**When to use:** When the SuperLink can be exposed on a routable IP and TLS is enabled (mandatory for public exposure).

**Configuration:**
- SuperLink VM: Public IP or 1:1 NAT to private IP. Firewall allows inbound TCP 9092.
- SuperNode VMs: Set `FL_SUPERLINK_ADDRESS=<public-ip>:9092` in CONTEXT.
- TLS is **mandatory** for this option (gRPC traffic traverses the public internet).

**TLS SAN consideration:** The server certificate SAN must include the **public IP** (or DNS name if used). If the SuperLink auto-generates certs, the SAN contains the VM's private IP, which will NOT match the public IP. Resolution options:
1. Use operator-provided certificates with the public IP/DNS in the SAN.
2. Use a DNS name that resolves to the SuperLink, and ensure the SAN includes that DNS name.
3. If using 1:1 NAT where the VM sees its public IP, auto-generation works.

### Pattern 5: gRPC Keepalive Configuration for WAN

**What:** Configure gRPC channel options to keep connections alive through stateful firewalls and load balancers.

**When to use:** Always for cross-zone deployments. Also beneficial for single-site deployments with network middleboxes.

**Recommended gRPC channel options (SuperNode side -- client):**
```python
# Python gRPC channel options for cross-zone Flower deployment
channel_options = [
    ("grpc.keepalive_time_ms", 60000),          # Send keepalive every 60 seconds
    ("grpc.keepalive_timeout_ms", 20000),        # Wait 20 seconds for ACK
    ("grpc.keepalive_permit_without_calls", 1),  # Keepalive even when idle
    ("grpc.http2.max_pings_without_data", 0),    # Allow unlimited pings without data
]
```

**Recommended gRPC server options (SuperLink side):**
```python
# Server must permit the client's keepalive frequency
server_options = [
    ("grpc.keepalive_time_ms", 60000),                              # Server also sends keepalives
    ("grpc.keepalive_timeout_ms", 20000),                           # Timeout for ACK
    ("grpc.keepalive_permit_without_calls", 1),                     # Allow idle keepalives
    ("grpc.http2.min_recv_ping_interval_without_data_ms", 30000),   # Accept pings every 30s
    ("grpc.http2.max_ping_strikes", 0),                             # Don't penalize frequent pings
]
```

**Why 60 seconds:** Common stateful firewall idle timeouts range from 60 seconds (aggressive) to 3600 seconds (lenient). Azure's TCP load balancer defaults to 4 minutes. The default gRPC keepalive of 2 hours is too long for most WAN paths. Flower's 210-second default (from PR #1069) is better but still risks timeout on aggressive firewalls. 60 seconds provides a safe margin below common timeout thresholds.

**Critical coordination requirement:** Client keepalive_time must be >= server's min_recv_ping_interval. If the client sends pings more frequently than the server permits, the server responds with GOAWAY ("ENHANCE_YOUR_CALM") and closes the connection.

### Anti-Patterns to Avoid

- **Trying to use OneFlow across zones:** OneFlow is zone-local. A single OneFlow service cannot span zones. Do not attempt to reference VM templates from other zones in a service template.
- **Relying on OneGate for cross-zone discovery:** OneGate operates only on local zone resources. SuperNodes in Zone B cannot query Zone A's OneGate. Use `FL_SUPERLINK_ADDRESS` for cross-zone.
- **Skipping TLS for cross-zone traffic:** gRPC model weights traverse WAN paths. Without TLS, model gradients are visible to network observers. TLS is mandatory for cross-zone.
- **Using auto-generated certs with NAT/public IP:** The auto-generated server certificate SAN contains the VM's private IP. If SuperNodes connect via a different (public) IP, TLS handshake fails with SAN mismatch. Use operator-provided certs with the correct SAN.
- **Setting keepalive_time_ms below server's min_recv_ping_interval:** Causes GOAWAY errors and connection drops. Always deploy server-side changes first when adjusting keepalive.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-zone VPN tunnel | Custom SSH tunnels or socat relays | WireGuard site-to-site | WireGuard runs in kernel space, survives connection drops, auto-reconnects. SSH tunnels are fragile. |
| Connection keepalive | Custom ping/heartbeat messages in application layer | gRPC native keepalive channel options | gRPC keepalive operates at HTTP/2 level, invisible to application. Custom heartbeats add complexity and do not prevent TCP idle timeout. |
| CA certificate distribution | Custom REST API or shared filesystem | FL_SSL_CA_CERTFILE CONTEXT variable | Already specified in Phase 2. The static provisioning path was designed for exactly this use case. |
| Cross-zone service orchestration | Custom scripts to coordinate deployment across zones | Separate OneFlow services per zone + deployment runbook | OneFlow handles per-zone orchestration. The cross-zone coordination is a human workflow (deploy Zone A first, get SuperLink IP, configure Zone B/C). |
| Connection resilience | Custom reconnection wrapper around gRPC | Flower's --max-retries 0 (unlimited) | Flower delegates reconnection to gRPC with unlimited retries. This handles both transient network issues and WireGuard tunnel flaps. |

**Key insight:** The cross-zone challenge is primarily an infrastructure concern (networking, certificate distribution), not an application concern. Flower's existing reconnection and TLS mechanisms handle the application layer correctly. The spec needs to bridge the infrastructure gap.

## Common Pitfalls

### Pitfall 1: OneGate Cross-Zone Assumption

**What goes wrong:** Operator assumes OneGate works across zones and deploys SuperNodes without `FL_SUPERLINK_ADDRESS`. SuperNodes query local OneGate, find no SuperLink in local zone, and boot fails.

**Why it happens:** The single-site spec (Phase 4) relies heavily on OneGate for service discovery. The natural assumption is that this extends to multi-site.

**How to avoid:** The spec must clearly state that OneGate is zone-local. Cross-zone SuperNode templates MUST set `FL_SUPERLINK_ADDRESS` as a mandatory variable. The remote-zone service template should use `M|text` (mandatory) type for this variable, not `O|text` (optional).

**Warning signs:** SuperNode discovery loops timing out (30 retries, 5 minutes). Error: "Failed to discover SuperLink endpoint via OneGate".

### Pitfall 2: TLS SAN Mismatch with NAT/VPN

**What goes wrong:** SuperLink auto-generates certificates with private IP in the SAN (e.g., 10.10.10.5). SuperNodes connect via WireGuard or public IP (e.g., 10.10.9.0 or 203.0.113.50). gRPC TLS handshake fails because the connection IP does not match the SAN.

**Why it happens:** The Phase 2 auto-generation uses `hostname -I | awk '{print $1}'` which returns the primary interface IP -- usually the private/management IP, not the WireGuard or public IP.

**How to avoid:** Two solutions:
1. Operator-provided certificates with correct SAN entries (recommended for multi-site).
2. Add WireGuard tunnel IP to the SAN during cert generation (requires a new CONTEXT variable, e.g., `FL_CERT_EXTRA_SAN`).

**Warning signs:** SuperNode gRPC logs: "certificate verify failed", "hostname mismatch".

### Pitfall 3: Firewall Idle Timeout Kills gRPC Connections

**What goes wrong:** After several minutes of training inactivity (e.g., between FL rounds when the SuperLink is waiting for slow clients), the gRPC connection is silently dropped by a stateful firewall or NAT device. The next round fails with connection errors.

**Why it happens:** Stateful firewalls track TCP connections and drop idle ones. Common idle timeouts: Azure LB 4 minutes, AWS NLB 350 seconds, Linux conntrack 432000 seconds (5 days), but enterprise firewalls often 60-600 seconds.

**How to avoid:** Configure gRPC keepalive to send pings more frequently than the shortest idle timeout on the path. 60-second keepalive_time is safe for most environments. The spec should define CONTEXT variables for keepalive tuning.

**Warning signs:** Intermittent "transport is closing" errors. Connections work initially but break after idle periods. Training succeeds for early rounds but fails in later rounds with longer gaps.

### Pitfall 4: WireGuard Tunnel Not Persisted Across Reboots

**What goes wrong:** WireGuard tunnel is configured manually but not enabled as a systemd service. After VM reboot, the tunnel is down and SuperNodes cannot reach the SuperLink.

**Why it happens:** `wg-quick up wg0` creates the tunnel but does not persist it. The systemd service must be explicitly enabled.

**How to avoid:** The spec should document `systemctl enable wg-quick@wg0` as part of the infrastructure setup.

**Warning signs:** Cross-zone connections work after manual setup but fail after any reboot.

### Pitfall 5: Deploying Remote Zones Before Coordinator is Ready

**What goes wrong:** Operator deploys Zone B/C SuperNode services before the Zone A SuperLink is ready. SuperNodes try to connect but the SuperLink is not yet listening.

**Why it happens:** No cross-zone `ready_status_gate` exists. Each zone's OneFlow operates independently.

**How to avoid:** The spec should define a deployment order runbook: (1) Deploy Zone A coordinator service, (2) wait for SuperLink READY=YES, (3) note SuperLink IP and CA cert, (4) configure and deploy Zone B/C services with those values. Flower's `--max-retries 0` provides resilience against minor timing issues, but the operator should still deploy in order.

**Warning signs:** SuperNode containers in retry loop. If the SuperLink never comes up, SuperNodes retry indefinitely (by design with --max-retries 0).

## Code Examples

### Python gRPC Keepalive Channel Options

```python
# Source: gRPC official documentation + Flower PR #1069
# These are the channel options that would be injected into Flower's gRPC client

GRPC_KEEPALIVE_OPTIONS = [
    # Send keepalive ping every 60 seconds
    ("grpc.keepalive_time_ms", 60000),
    # Wait 20 seconds for keepalive ACK
    ("grpc.keepalive_timeout_ms", 20000),
    # Send keepalive even when no RPCs are active
    ("grpc.keepalive_permit_without_calls", 1),
    # Allow unlimited pings without data frames
    ("grpc.http2.max_pings_without_data", 0),
]

GRPC_SERVER_KEEPALIVE_OPTIONS = [
    # Server sends keepalive every 60 seconds
    ("grpc.keepalive_time_ms", 60000),
    # Wait 20 seconds for keepalive ACK
    ("grpc.keepalive_timeout_ms", 20000),
    # Allow keepalive without active RPCs
    ("grpc.keepalive_permit_without_calls", 1),
    # Accept pings as frequently as every 30 seconds
    ("grpc.http2.min_recv_ping_interval_without_data_ms", 30000),
    # Do not penalize frequent pings (0 = unlimited strikes allowed)
    ("grpc.http2.max_ping_strikes", 0),
]
```

### Contextualization Variables for Keepalive (New for Phase 7)

```
# Phase 7: gRPC Keepalive Tuning
FL_GRPC_KEEPALIVE_TIME = "O|number|gRPC keepalive interval (seconds)||60"
FL_GRPC_KEEPALIVE_TIMEOUT = "O|number|gRPC keepalive ACK timeout (seconds)||20"
```

**Translation to gRPC options:**
```bash
# In generate_run_config() or docker environment setup
if [ -n "${FL_GRPC_KEEPALIVE_TIME}" ]; then
    KEEPALIVE_MS=$((FL_GRPC_KEEPALIVE_TIME * 1000))
    # Pass as environment variable to be picked up by Flower's gRPC layer
    echo "FLOWER_GRPC_KEEPALIVE_TIME_MS=${KEEPALIVE_MS}" >> /opt/flower/config/supernode.env
fi
```

**Note on Flower's gRPC configuration:** Flower internally manages gRPC channel creation. As of PR #1069, Flower sets a default keepalive_time of 210 seconds. The spec should define how operators can override this via CONTEXT variables. The exact mechanism (environment variable, CLI flag, or run_config) depends on Flower's configuration surface -- the spec should recommend the approach and note that implementation may need to patch or extend the Flower gRPC channel creation if no external configuration hook exists.

### WireGuard Gateway Configuration Template

```bash
#!/bin/bash
# /opt/flower/scripts/setup-wireguard.sh
# Template for WireGuard site-to-site gateway setup
# Run on the gateway VM in each zone (NOT on individual SuperLink/SuperNode VMs)

# Variables (from CONTEXT or operator input)
WG_PRIVATE_KEY="${WG_PRIVATE_KEY}"
WG_PEER_PUBLIC_KEY="${WG_PEER_PUBLIC_KEY}"
WG_LOCAL_ADDRESS="${WG_LOCAL_ADDRESS}"       # e.g., 10.10.9.0/31
WG_PEER_ENDPOINT="${WG_PEER_ENDPOINT}"       # e.g., 203.0.113.50:51820
WG_PEER_ALLOWED_IPS="${WG_PEER_ALLOWED_IPS}" # e.g., 10.10.11.0/24,10.10.9.1/31
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

# Install WireGuard (Ubuntu 24.04 has kernel module built-in)
apt-get install -y wireguard-tools

# Write configuration
cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
Address = ${WG_LOCAL_ADDRESS}
ListenPort = ${WG_LISTEN_PORT}
PostUp = wg set %i private-key /etc/wireguard/wg0.key

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
AllowedIPs = ${WG_PEER_ALLOWED_IPS}
Endpoint = ${WG_PEER_ENDPOINT}
PersistentKeepalive = 25
EOF

# Write private key
echo "${WG_PRIVATE_KEY}" > /etc/wireguard/wg0.key
chmod 600 /etc/wireguard/wg0.key

# Enable IP forwarding (gateway must forward between WG and local network)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-wireguard.conf

# Start and enable tunnel
systemctl enable --now wg-quick@wg0

# Verify
wg show wg0
```

### Cross-Zone TLS Certificate Distribution Workflow

```bash
# OPERATOR WORKFLOW: Extract CA cert from Zone A, inject into Zone B/C CONTEXT

# Step 1: On Zone A SuperLink VM (after boot, FL_READY=YES)
ssh root@<superlink-vm-ip>
base64 -w0 /opt/flower/certs/ca.crt
# Copy the base64 output

# Step 2: In Zone B/C SuperNode VM template CONTEXT
# Set FL_SSL_CA_CERTFILE = <pasted base64 string>
# Set FL_TLS_ENABLED = YES
# Set FL_SUPERLINK_ADDRESS = <superlink-wg-ip>:9092

# OR: For operator-provided PKI
# Generate certs with correct SANs using external CA
# Set FL_SSL_CA_CERTFILE on all SuperNodes
# Set FL_SSL_CA_CERTFILE + FL_SSL_CERTFILE + FL_SSL_KEYFILE on SuperLink
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| OpenVPN for site-to-site VPN | WireGuard (in-kernel) | Linux 5.6 (2020) | WireGuard has ~10x less code than OpenVPN, runs in kernel space, lower latency. |
| gRPC default keepalive (2 hours) | Flower 210s keepalive default | Flower PR #1069 (2022) | Prevents Azure/cloud idle connection drops. Still too long for aggressive firewalls. |
| Manual multi-site deployment | Per-zone OneFlow services | This spec (Phase 7) | Adds structure to multi-site deployment without requiring cross-zone orchestration. |
| Bidirectional gRPC streaming | Unary request-response (gRPC-rere) | Flower 1.8+ | Simpler, more resilient connection model. Better for WAN with intermittent connectivity. |
| 512 MB gRPC message limit | 2 GB limit + automatic chunking | Flower 1.20+ | Large model support. Critical for LLM federated fine-tuning across sites. |

**Deprecated/outdated:**
- OpenVPN: Still works but WireGuard is preferred for new deployments (simpler, faster, in-kernel).
- gRPC bidirectional streaming in Flower: Replaced by gRPC-rere (request-response). The new model is more resilient to connection drops.
- Single-service cross-zone deployment: Not possible with OpenNebula's zone-local OneFlow.

## Open Questions

1. **Flower gRPC channel options configuration surface**
   - What we know: Flower has a 210-second default keepalive (PR #1069). Channel options are passed as a list of tuples in Python.
   - What's unclear: Whether Flower exposes a CLI flag, environment variable, or run_config option to override gRPC channel options at runtime. The spec may need to define an approach that requires Flower-side changes.
   - Recommendation: Define the CONTEXT variables (`FL_GRPC_KEEPALIVE_TIME`) in the spec. Note that the implementation may need to modify Flower's channel creation or use environment variables that Flower reads.
   - **Confidence:** LOW -- Flower's configuration surface for gRPC internals is not well-documented.

2. **Server certificate SAN for multi-homed SuperLink**
   - What we know: Phase 2 auto-generation uses `hostname -I | awk '{print $1}'` for the SAN. In multi-site, the SuperLink may be reachable on multiple IPs (private, WireGuard tunnel, public).
   - What's unclear: Whether Flower/gRPC requires the SAN to match the exact IP the client connects to, or if any SAN IP is acceptable. (Standard TLS behavior requires match to connection address.)
   - Recommendation: Introduce `FL_CERT_EXTRA_SAN` CONTEXT variable to add additional IP/DNS entries to the auto-generated certificate SAN. For Phase 7, the operator-provided cert path may be simpler.
   - **Confidence:** HIGH for TLS SAN matching requirement (standard behavior). MEDIUM for implementation approach.

3. **WireGuard gateway placement -- dedicated VM vs zone router**
   - What we know: WireGuard site-to-site runs on gateway nodes that forward traffic between sites.
   - What's unclear: Whether the WireGuard gateway should be a dedicated VM, the SuperLink VM itself, or a zone-level router. The answer depends on the OpenNebula network topology.
   - Recommendation: Spec should present both options (dedicated gateway VM and SuperLink-as-gateway) with trade-offs. Dedicated gateway is cleaner (separation of concerns); SuperLink-as-gateway is simpler for small deployments.
   - **Confidence:** MEDIUM -- both approaches are valid; depends on deployment scale.

4. **OpenNebula VXLAN cross-zone viability**
   - What we know: OpenNebula 7.0 supports VXLAN with BGP EVPN control plane. In theory, EVPN could stretch L2 networks across sites.
   - What's unclear: Whether OpenNebula's VXLAN driver supports cross-zone (cross-datacenter) EVPN. The documentation focuses on intra-zone/intra-cluster scenarios.
   - Recommendation: Do NOT recommend VXLAN for cross-zone in Phase 7. It adds significant complexity (BGP peering, EVPN route reflectors) and does not provide encryption. WireGuard is simpler and more appropriate.
   - **Confidence:** LOW for cross-zone VXLAN viability.

## Sources

### Primary (HIGH confidence)
- [gRPC Keepalive Guide](https://grpc.io/docs/guides/keepalive/) - Official gRPC keepalive parameters and defaults
- [gRPC Core Keepalive Reference](https://grpc.github.io/grpc/core/md_doc_keepalive.html) - Complete parameter table with C-level argument names
- [OpenNebula 6.8 Federation Overview](https://docs.opennebula.io/6.8/installation_and_configuration/data_center_federation/overview.html) - Zone-local service constraints (OneGate, OneFlow, Scheduler)
- [Ubuntu WireGuard Site-to-Site Guide](https://documentation.ubuntu.com/server/how-to/wireguard-vpn/site-to-site/) - Official Ubuntu WireGuard configuration
- [Flower Network Communication](https://flower.ai/docs/framework/ref-flower-network-communication.html) - gRPC architecture, ports, connection direction
- [Flower CLI Reference](https://flower.ai/docs/framework/ref-api-cli.html) - SuperLink/SuperNode CLI flags including --max-retries
- Phase 2 specs (internal): `spec/04-tls-certificate-lifecycle.md`, `spec/05-supernode-tls-trust.md` - TLS trust model and static provisioning

### Secondary (MEDIUM confidence)
- [OpenNebula 7.0 Federation Config](https://docs.opennebula.io/7.0/product/control_plane_configuration/data_center_federation/config/) - Zone master/slave setup
- [Flower PR #1069 - gRPC Keepalive](https://github.com/adap/flower/pull/1069) - Flower's 210-second default keepalive, channel options exposure
- [gRPC is tricky to configure](https://www.evanjones.ca/grpc-is-tricky.html) - Keepalive coordination pitfalls, TCP_USER_TIMEOUT interaction
- [OpenNebula 7.0 VXLAN](https://docs.opennebula.io/7.0/product/cluster_configuration/networking_system/vxlan/) - VXLAN/EVPN for overlay networking
- [OpenNebula Blog: Federating Clouds](https://opennebula.io/blog/innovation/federating-opennebula-clouds/) - Real-world multi-zone deployment examples

### Tertiary (LOW confidence)
- [Flower Issue #823 - gRPC channel closed](https://github.com/adap/flower/issues/823) - Connection issues (resolved as startup order, not keepalive)
- [WireGuard MTU Tuning](https://gist.github.com/nitred/f16850ca48c48c79bf422e90ee5b9d95) - Community MTU calculation guidance
- [Contabo WireGuard Performance Tuning](https://contabo.com/blog/maximizing-wireguard-performance/) - Performance optimization guidance

## Metadata

**Confidence breakdown:**
- OpenNebula zone architecture (OneGate/OneFlow zone-local): HIGH -- confirmed across multiple documentation versions (5.2, 5.6, 6.4, 6.8, 7.0)
- gRPC keepalive parameters and defaults: HIGH -- official gRPC documentation with specific values
- WireGuard site-to-site configuration: HIGH -- official Ubuntu documentation with working examples
- TLS trust distribution model: HIGH -- extends Phase 2's existing static provisioning path
- Flower gRPC channel options exposure: LOW -- PR #1069 shows it exists but runtime configuration surface unclear
- OpenNebula VXLAN cross-zone: LOW -- documentation does not address cross-zone VXLAN explicitly
- Per-zone OneFlow template pattern: MEDIUM -- logical extension of Phase 4, but not documented as a standard pattern

**Research date:** 2026-02-09
**Valid until:** 2026-03-09 (30 days -- OpenNebula and gRPC APIs are stable; Flower may add new configuration options)
