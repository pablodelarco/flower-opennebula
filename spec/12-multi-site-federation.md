# Multi-Site Federation

**Requirement:** ORCH-02
**Phase:** 07 - Multi-Site Federation
**Status:** Specification

---

## 1. Purpose and Scope

This section specifies how to deploy a Flower federated learning cluster across multiple OpenNebula zones -- SuperLink in one zone, SuperNodes distributed across remote zones, connected over WAN. Multi-site federation is the key differentiator for production deployments where training data is distributed across geographically separate data centers and cannot be centralized due to privacy, regulatory, or bandwidth constraints.

**What this section covers:**
- 3-zone reference deployment topology with per-zone OneFlow services.
- Per-zone OneFlow service template variants (coordinator zone vs training site).
- Two cross-zone networking options: WireGuard site-to-site VPN and direct public IP.
- gRPC keepalive configuration for WAN connection resilience.
- TLS certificate trust distribution across zones where OneGate is zone-local.
- End-to-end 3-zone deployment walkthrough.
- Failure modes, recovery procedures, and anti-patterns.

**What this section does NOT cover:**
- Single-site orchestration within one zone (see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md) -- Phase 4).
- TLS certificate generation and dual provisioning model (see [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md) -- Phase 2).
- SuperNode TLS trust and end-to-end handshake (see [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md) -- Phase 2).
- Edge optimization and auto-scaling (Phase 9).

**Critical architectural constraint:** OneGate and OneFlow are zone-local services in an OpenNebula federation. They cannot operate across zone boundaries. This means the single-site OneFlow service template (Phase 4) cannot orchestrate a cross-zone deployment as a single service. Each zone must have its own independent OneFlow service. SuperNode discovery via OneGate is unavailable cross-zone; the static `FL_SUPERLINK_ADDRESS` path (already specified in Phases 1-2) becomes mandatory for remote SuperNodes.

**Cross-references:**
- Single-site orchestration: [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md) -- OneFlow service template, deployment sequencing, cardinality config.
- TLS certificate lifecycle: [`spec/04-tls-certificate-lifecycle.md`](04-tls-certificate-lifecycle.md) -- CA generation, dual provisioning, OneGate publication.
- SuperNode TLS trust: [`spec/05-supernode-tls-trust.md`](05-supernode-tls-trust.md) -- CA cert retrieval, static provisioning fallback, TLS mode detection.
- Contextualization reference: [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) -- complete variable definitions including new Phase 7 variables.

---

## 2. 3-Zone Reference Deployment Topology

This is the canonical multi-site Flower federation architecture. All subsequent sections reference this topology.

### Architecture Diagram

```
Zone A (Coordinator)              Zone B (Training Site 1)         Zone C (Training Site 2)
+----------------------------+    +----------------------------+    +----------------------------+
| OpenNebula Zone A          |    | OpenNebula Zone B          |    | OpenNebula Zone C          |
|                            |    |                            |    |                            |
| +------------------------+ |    | +------------------------+ |    | +------------------------+ |
| | SuperLink VM           | |    | | SuperNode VM #1        | |    | | SuperNode VM #3        | |
| | - Fleet API :9092      |<------| - gRPC client (outbound)|<-+  | | - gRPC client (outbound)| |
| | - TLS certs generated  | | gRPC| - Local training data   |  |  | | - Local training data   | |
| | - State DB (state.db)  | |    | +------------------------+ |  |  | +------------------------+ |
| +------------------------+ |    | +------------------------+ |  |  | +------------------------+ |
|                            |    | | SuperNode VM #2        | |  |  | | SuperNode VM #4        | |
| OneFlow Service A          |    | | - gRPC client (outbound)|----+  | | - gRPC client (outbound)| |
|   Role: superlink (1 VM)   |    | +------------------------+ | gRPC | +------------------------+ |
|   min_vms=1, max_vms=1     |    |                            |    |                            |
|                            |    | OneFlow Service B          |    | OneFlow Service C          |
| OneGate (zone-local)       |    |   Role: supernode (2+ VMs) |    |   Role: supernode (2+ VMs) |
+----------------------------+    |   No parents dependency     |    |   No parents dependency     |
                                  |                            |    |                            |
                                  | OneGate (zone-local)       |    | OneGate (zone-local)       |
                                  +----------------------------+    +----------------------------+

Cross-zone connectivity: WireGuard site-to-site VPN (Section 4) or Direct Public IP (Section 5)
TLS trust distribution: CA cert via FL_SSL_CA_CERTFILE CONTEXT variable (Section 8)
SuperNode discovery: Static FL_SUPERLINK_ADDRESS (OneGate is zone-local, cannot serve cross-zone)
gRPC keepalive: FL_GRPC_KEEPALIVE_TIME=60s for WAN resilience (Section 7)
```

### Zone Roles

**Zone A (Coordinator):**
- Hosts the SuperLink VM -- the single FL coordinator that manages training rounds and aggregates model updates.
- Runs its own OneFlow Service A with a single `superlink` role (singleton: min_vms=1, max_vms=1).
- OneGate is available locally for SuperLink readiness publication (`FL_READY=YES`, `FL_ENDPOINT`, `FL_CA_CERT`).
- The SuperLink's Fleet API (port 9092) is the inbound target for all gRPC connections from remote SuperNodes.

**Zone B (Training Site 1):**
- Hosts SuperNode VMs that train on local data in Zone B's data center.
- Runs its own OneFlow Service B with a single `supernode` role (no `parents` dependency -- SuperLink is external).
- `FL_SUPERLINK_ADDRESS` is mandatory (set to the SuperLink's reachable IP from Zone B).
- `FL_SSL_CA_CERTFILE` is mandatory when TLS is enabled (OneGate cannot distribute the CA cert cross-zone).
- OneGate is available locally for per-VM readiness publication (`FL_NODE_READY=YES`).

**Zone C (Training Site 2):**
- Identical pattern to Zone B. Hosts SuperNode VMs training on Zone C's local data.
- Independent OneFlow Service C with the same template structure as Service B.

### Key Architectural Constraints

The following five constraints are fundamental to the multi-site architecture. Each arises from OpenNebula's zone-local service model and Flower's TLS verification behavior.

| # | Constraint | Implication |
|---|-----------|-------------|
| 1 | **OneFlow is zone-local.** A single OneFlow service cannot span multiple zones. | Each zone must have its own independent OneFlow service. Zone A has a coordinator service; Zones B/C have training site services. |
| 2 | **OneGate is zone-local.** SuperNodes in Zone B/C cannot query Zone A's OneGate. | The auto-discovery path (SuperNode retrieves `FL_ENDPOINT` and `FL_CA_CERT` from OneGate) does not work cross-zone. Static configuration is required. |
| 3 | **FL_SUPERLINK_ADDRESS is mandatory for remote SuperNodes.** Without OneGate discovery, SuperNodes must know the SuperLink's address explicitly. | In the training site template, `FL_SUPERLINK_ADDRESS` changes from `O|text` (optional) to `M|text` (mandatory). |
| 4 | **FL_SSL_CA_CERTFILE is mandatory for TLS cross-zone.** Without OneGate, the CA certificate must be provided out-of-band via the CONTEXT variable. | In the training site template, `FL_SSL_CA_CERTFILE` changes from `O|text64` (optional) to `M|text64` (mandatory) when `FL_TLS_ENABLED=YES`. |
| 5 | **No `parents` dependency in remote zone templates.** The SuperLink is external to the training site's OneFlow service. | The training site service template has no `parents` array. SuperNode VMs boot immediately when the service is instantiated. `--max-retries 0` (unlimited) handles the case where SuperNodes boot before the SuperLink is ready. |

---

## 3. Per-Zone OneFlow Service Templates

Multi-site federation requires two distinct service template variants, derived from the single-site template defined in [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 3.

### 3.1 Coordinator Zone Template (Zone A)

This template deploys only the SuperLink role. It is the coordinator half of a multi-site federation.

```json
{
  "name": "Flower Federation - Coordinator",
  "description": "Coordinator zone for multi-site Flower federation. Deploys a single SuperLink that remote training sites connect to.",
  "deployment": "straight",
  "ready_status_gate": true,
  "shutdown_action": "shutdown",

  "user_inputs": {
    "FLOWER_VERSION": "O|text|Flower Docker image version tag||1.25.0",
    "FL_TLS_ENABLED": "O|boolean|Enable TLS encryption||YES",
    "FL_LOG_LEVEL": "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
  },

  "roles": [
    {
      "name": "superlink",
      "type": "vm",
      "template_id": 0,
      "cardinality": 1,
      "min_vms": 1,
      "max_vms": 1,
      "shutdown_action": "shutdown",

      "user_inputs": {
        "FL_NUM_ROUNDS": "O|number|Number of federated learning rounds||10",
        "FL_STRATEGY": "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg|FedAvg",
        "FL_MIN_FIT_CLIENTS": "O|number|Minimum clients for training round||2",
        "FL_MIN_EVALUATE_CLIENTS": "O|number|Minimum clients for evaluation||2",
        "FL_MIN_AVAILABLE_CLIENTS": "O|number|Minimum available clients to start||2",
        "FL_PROXIMAL_MU": "O|number-float|FedProx proximal term (mu)||1.0",
        "FL_SERVER_LR": "O|number-float|Server-side learning rate||0.1",
        "FL_CLIENT_LR": "O|number-float|Client-side learning rate||0.1",
        "FL_NUM_MALICIOUS": "O|number|Expected malicious clients (Krum/Bulyan)||0",
        "FL_TRIM_BETA": "O|number-float|Trim fraction per tail (FedTrimmedAvg)||0.2",
        "FL_CHECKPOINT_ENABLED": "O|boolean|Enable model checkpointing||NO",
        "FL_CHECKPOINT_INTERVAL": "O|number|Save checkpoint every N rounds||5",
        "FL_CHECKPOINT_PATH": "O|text|Checkpoint directory (container path)||/app/checkpoints",
        "FL_CERT_EXTRA_SAN": "O|text|Additional SAN entries for cert (e.g., IP:10.10.9.0,DNS:flower.example.com)||",
        "FL_GRPC_KEEPALIVE_TIME": "O|number|gRPC keepalive interval in seconds||60",
        "FL_GRPC_KEEPALIVE_TIMEOUT": "O|number|gRPC keepalive ACK timeout in seconds||20"
      },

      "template_contents": {
        "CONTEXT": {
          "TOKEN": "YES",
          "REPORT_READY": "YES",
          "READY_SCRIPT_PATH": "/opt/flower/scripts/health-check.sh",
          "NETWORK": "YES"
        }
      }
    }
  ]
}
```

**Key differences from single-site template:**
- `FL_TLS_ENABLED` defaults to `YES` (recommended for multi-site; cross-zone traffic should always be encrypted).
- No `supernode` role -- SuperNodes are in remote zones with their own services.
- New Phase 7 variables: `FL_CERT_EXTRA_SAN`, `FL_GRPC_KEEPALIVE_TIME`, `FL_GRPC_KEEPALIVE_TIMEOUT`.
- `FL_NUM_ROUNDS` defaults to `10` (multi-site campaigns tend to run longer).
- `ready_status_gate: true` still applies -- the SuperLink must be healthy before the operator proceeds to deploy training sites.

### 3.2 Training Site Template (Zone B/C)

This template deploys only SuperNode VMs. It is instantiated independently in each training site zone.

```json
{
  "name": "Flower Federation - Training Site",
  "description": "Training site for multi-site Flower federation. SuperNodes connect to a remote SuperLink in the coordinator zone.",
  "deployment": "straight",
  "ready_status_gate": true,
  "shutdown_action": "shutdown",

  "user_inputs": {
    "FLOWER_VERSION": "O|text|Flower Docker image version tag||1.25.0",
    "FL_TLS_ENABLED": "O|boolean|Enable TLS encryption||YES",
    "FL_LOG_LEVEL": "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO"
  },

  "roles": [
    {
      "name": "supernode",
      "type": "vm",
      "template_id": 0,
      "cardinality": 2,
      "min_vms": 2,
      "max_vms": 10,
      "shutdown_action": "shutdown",

      "user_inputs": {
        "FL_SUPERLINK_ADDRESS": "M|text|SuperLink address in coordinator zone (IP:port)",
        "FL_SSL_CA_CERTFILE": "M|text64|CA certificate from coordinator zone (base64 PEM)",
        "ML_FRAMEWORK": "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch",
        "FL_USE_CASE": "O|list|Pre-built use case|none,image-classification,anomaly-detection,llm-fine-tuning|none",
        "FL_NODE_CONFIG": "O|text|Space-separated key=value node config||",
        "FL_GRPC_KEEPALIVE_TIME": "O|number|gRPC keepalive interval in seconds||60",
        "FL_GRPC_KEEPALIVE_TIMEOUT": "O|number|gRPC keepalive ACK timeout in seconds||20"
      },

      "template_contents": {
        "CONTEXT": {
          "TOKEN": "YES",
          "REPORT_READY": "YES",
          "READY_SCRIPT_PATH": "/opt/flower/scripts/health-check.sh",
          "NETWORK": "YES"
        }
      }
    }
  ]
}
```

**Key differences from single-site template:**
- No `superlink` role -- the SuperLink is in the coordinator zone.
- No `parents` dependency -- SuperNodes boot immediately (the SuperLink is external to this service).
- `FL_SUPERLINK_ADDRESS` is **mandatory** (`M|text`) -- no OneGate discovery cross-zone.
- `FL_SSL_CA_CERTFILE` is **mandatory** (`M|text64`) -- no OneGate CA cert retrieval cross-zone.
- `FL_TLS_ENABLED` defaults to `YES` (cross-zone traffic must be encrypted).
- New Phase 7 variable: `FL_GRPC_KEEPALIVE_TIME`, `FL_GRPC_KEEPALIVE_TIMEOUT`.

### 3.3 Template Comparison Table

| Aspect | Single-Site (Phase 4) | Coordinator (Zone A) | Training Site (Zone B/C) |
|--------|----------------------|---------------------|--------------------------|
| Roles | superlink + supernode | superlink only | supernode only |
| `parents` dependency | supernode depends on superlink | N/A (single role) | None (SuperLink is external) |
| FL_TLS_ENABLED default | `NO` | `YES` | `YES` |
| FL_SUPERLINK_ADDRESS | `O\|text` (optional) | N/A | `M\|text` (mandatory) |
| FL_SSL_CA_CERTFILE | `O\|text64` (optional) | N/A | `M\|text64` (mandatory) |
| FL_CERT_EXTRA_SAN | N/A | `O\|text` (new) | N/A |
| FL_GRPC_KEEPALIVE_TIME | N/A | `O\|number` (new) | `O\|number` (new) |
| ready_status_gate | true | true | true |
| Deployment coordination | OneFlow manages ordering | Manual: deploy Zone A first | Manual: deploy after Zone A is ready |

---

## 4. Cross-Zone Networking -- WireGuard Site-to-Site VPN

### When to Use

Use WireGuard when the SuperLink and SuperNodes are on private networks in different data centers without direct IP reachability. WireGuard creates an encrypted tunnel between zone gateway nodes, providing private IP connectivity across zones.

### Architecture

```
Zone A (Coordinator)                              Zone B (Training Site)
+--------------------------------+                +--------------------------------+
| Private subnet: 10.10.10.0/24 |                | Private subnet: 10.10.11.0/24  |
|                                |                |                                |
| +----------+  +-------------+ |                | +-------------+  +----------+  |
| | SuperLink|  | WG Gateway  | |   WireGuard    | | WG Gateway  |  |SuperNode |  |
| | 10.10.10.5  | wg0: 10.10.9.0 |<--- tunnel --->| wg0: 10.10.9.1  | 10.10.11.5 |
| +----------+  | pub: A.A.A.A| |   UDP 51820    | | pub: B.B.B.B|  +----------+  |
|               +-------------+ |                | +-------------+  +----------+  |
|                                |                |                  |SuperNode |  |
|                                |                |                  | 10.10.11.6 |
|                                |                |                  +----------+  |
+--------------------------------+                +--------------------------------+

SuperNode FL_SUPERLINK_ADDRESS = 10.10.10.5:9092  (reachable via WireGuard tunnel)
Flower gRPC (TCP 9092) flows inside the encrypted WireGuard tunnel.
Only UDP 51820 traverses the public internet.
```

### Gateway Placement Options

| Option | Description | Pros | Cons |
|--------|-------------|------|------|
| Dedicated gateway VM | A separate VM in each zone runs WireGuard and forwards traffic between the tunnel and the local network. | Separation of concerns. SuperLink/SuperNode VMs unmodified. Gateway can serve multiple services. | Additional VM to manage. Requires IP forwarding and routing configuration. |
| SuperLink-as-gateway | The SuperLink VM itself runs WireGuard. SuperNodes connect to the SuperLink's WireGuard IP directly. | Simpler for small deployments. No additional VM. SuperLink's tunnel IP is the FL_SUPERLINK_ADDRESS. | Mixes networking and application concerns. SuperLink VM needs a public IP for the WireGuard endpoint. |

**Recommendation:** Use a dedicated gateway VM for production deployments (cleaner separation). Use SuperLink-as-gateway for proof-of-concept or small deployments (2-3 zones).

### WireGuard Configuration

**Zone A Gateway (`/etc/wireguard/wg0.conf`):**

```ini
[Interface]
Address = 10.10.9.0/31
ListenPort = 51820
PostUp = wg set %i private-key /etc/wireguard/wg0.key

[Peer]
PublicKey = <zone-b-public-key>
AllowedIPs = 10.10.11.0/24, 10.10.9.1/31
Endpoint = <zone-b-gateway-public-ip>:51820
PersistentKeepalive = 25
```

**Zone B Gateway (`/etc/wireguard/wg0.conf`):**

```ini
[Interface]
Address = 10.10.9.1/31
ListenPort = 51820
PostUp = wg set %i private-key /etc/wireguard/wg0.key

[Peer]
PublicKey = <zone-a-public-key>
AllowedIPs = 10.10.10.0/24, 10.10.9.0/31
Endpoint = <zone-a-gateway-public-ip>:51820
PersistentKeepalive = 25
```

**For a 3-zone deployment (Zone C):** Add a second `[Peer]` block to Zone A's configuration pointing to Zone C's gateway, and configure Zone C's gateway with Zone A as its peer. Zone B and Zone C do not need direct peering -- all gRPC traffic flows to Zone A (hub-and-spoke topology).

### Infrastructure Setup

**MTU:** Set WireGuard interface MTU to `1420` (1500 standard ethernet MTU minus 60 bytes WireGuard IPv4 overhead). gRPC/HTTP2 frames are well below typical MTU limits and are not affected.

```bash
# Add to [Interface] section of wg0.conf
MTU = 1420
```

**Firewall:** Allow UDP port 51820 between gateway public IPs. No additional port openings are needed -- Flower gRPC traffic (TCP 9092) flows inside the WireGuard tunnel on private IPs.

```bash
# On Zone A gateway
ufw allow from <zone-b-public-ip> to any port 51820 proto udp
ufw allow from <zone-c-public-ip> to any port 51820 proto udp
```

**IP forwarding:** Enable on gateway VMs so they can route traffic between the WireGuard tunnel and the local zone network.

```bash
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.d/99-wireguard.conf
```

**Routing:** VMs in each zone need routes to reach the remote zone's subnet via the gateway. Options:
- **Static route on each VM:** `ip route add 10.10.11.0/24 via <local-gateway-ip>`
- **Zone router configuration:** Configure the OpenNebula virtual router to route the remote subnet through the gateway VM.
- **SuperLink-as-gateway:** No additional routing needed -- SuperNodes connect directly to the gateway's WireGuard IP.

**Persistence:** Enable the WireGuard tunnel as a systemd service to survive reboots.

```bash
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0
```

### WireGuard Key Generation

```bash
# On each gateway (Zone A and Zone B)
wg genkey | tee /etc/wireguard/wg0.key | wg pubkey > /etc/wireguard/wg0.pub
chmod 600 /etc/wireguard/wg0.key

# Exchange public keys between zones (out-of-band)
cat /etc/wireguard/wg0.pub
```

---

## 5. Cross-Zone Networking -- Direct Public IP

### When to Use

Use direct public IP when the SuperLink has a public/routable IP address (or 1:1 NAT) and you want a simpler topology without VPN infrastructure. This option has fewer moving parts but requires TLS (mandatory -- traffic traverses the public internet).

### Configuration

- **SuperLink VM:** Assign a public IP address directly, or configure 1:1 NAT / port forwarding on the zone router to map a public IP to the SuperLink's private IP on TCP port 9092.
- **SuperNode VMs:** Set `FL_SUPERLINK_ADDRESS=<public-ip>:9092` in the training site template.
- **Firewall:** Allow inbound TCP port 9092 on the SuperLink's public IP from SuperNode source IPs (or `0.0.0.0/0` if SuperNode IPs are dynamic).

**TLS IS MANDATORY.** When gRPC traffic traverses the public internet, model weights and gradients are visible to network observers without encryption. Do not use `FL_TLS_ENABLED=NO` with direct public IP connectivity.

### TLS SAN Consideration

When the SuperLink auto-generates certificates (Phase 2 default), the SAN contains the VM's primary private IP (detected via `hostname -I | awk '{print $1}'`). If SuperNodes connect via a different (public) IP, the TLS handshake fails with a SAN mismatch error ("certificate verify failed", "hostname mismatch").

**Three resolution options:**

| # | Option | When to Use | Configuration |
|---|--------|-------------|---------------|
| 1 | Operator-provided certs | Enterprise PKI available. Recommended for production. | Generate certs from your CA with the public IP or DNS name in the SAN. Set `FL_SSL_CA_CERTFILE`, `FL_SSL_CERTFILE`, `FL_SSL_KEYFILE` on the SuperLink. Set `FL_SSL_CA_CERTFILE` on SuperNodes. |
| 2 | DNS name with SAN | Public DNS available for the SuperLink. | Create a DNS A record pointing to the SuperLink's public IP. Use `FL_CERT_EXTRA_SAN=DNS:flower.example.com` on the SuperLink. SuperNodes use `FL_SUPERLINK_ADDRESS=flower.example.com:9092`. |
| 3 | 1:1 NAT (VM sees public IP) | Cloud provider assigns the public IP directly to the VM interface. | No additional configuration. `hostname -I` returns the public IP, which is included in the auto-generated SAN. This is the simplest path but depends on the cloud provider's networking model. |

### New CONTEXT Variable: FL_CERT_EXTRA_SAN

**Purpose:** Adds additional SAN entries to the auto-generated server certificate on the SuperLink, allowing the certificate to be valid for addresses beyond the primary VM IP.

| Attribute | Value |
|-----------|-------|
| Variable | `FL_CERT_EXTRA_SAN` |
| USER_INPUT | `O\|text\|Additional SAN entries for auto-generated cert (comma-separated)\|\|` |
| Type | text |
| Default | (empty) |
| Appliance | SuperLink only |
| Phase | 7 |

**Format:** Comma-separated `type:value` entries. Supported types are `IP` and `DNS`.

**Example values:**
- `IP:203.0.113.50` -- add a public IP to the SAN.
- `DNS:flower.example.com` -- add a DNS name to the SAN.
- `IP:10.10.9.0,DNS:flower.example.com` -- add both a WireGuard tunnel IP and a DNS name.

**Behavior:** When `FL_CERT_EXTRA_SAN` is set and non-empty, the certificate generation script (Phase 2, Section 3, Step 4) appends the specified entries to the `[alt_names]` section of the CSR and signing configuration. If unset or empty, auto-generation uses only the primary VM IP (Phase 2 behavior unchanged).

**Implementation note:** The generation script parses the comma-separated list and appends entries:

```bash
# Pseudocode for FL_CERT_EXTRA_SAN processing in generate-certs.sh
EXTRA_SAN_INDEX=4   # Start after IP.3 (VM IP)
DNS_INDEX=2         # Start after DNS.1 (localhost)

if [ -n "${FL_CERT_EXTRA_SAN}" ]; then
    IFS=',' read -ra SAN_ENTRIES <<< "${FL_CERT_EXTRA_SAN}"
    for entry in "${SAN_ENTRIES[@]}"; do
        entry=$(echo "$entry" | xargs)  # trim whitespace
        case "$entry" in
            IP:*)
                echo "IP.${EXTRA_SAN_INDEX} = ${entry#IP:}" >> "$SAN_CONFIG"
                EXTRA_SAN_INDEX=$((EXTRA_SAN_INDEX + 1))
                ;;
            DNS:*)
                echo "DNS.${DNS_INDEX} = ${entry#DNS:}" >> "$SAN_CONFIG"
                DNS_INDEX=$((DNS_INDEX + 1))
                ;;
            *)
                log "WARN" "FL_CERT_EXTRA_SAN: ignoring unrecognized entry '${entry}'. Expected IP:<addr> or DNS:<name>."
                ;;
        esac
    done
fi
```

### Trade-offs: WireGuard vs Direct Public IP

| Criterion | WireGuard VPN | Direct Public IP |
|-----------|---------------|-----------------|
| Network encryption | WireGuard tunnel encrypts all traffic (plus TLS on top) | TLS only (mandatory) |
| TLS SAN handling | SuperNodes connect to private/tunnel IPs that match auto-generated SAN | SAN mismatch likely; requires FL_CERT_EXTRA_SAN or operator certs |
| Additional infrastructure | Gateway VM(s), WireGuard configuration | None (uses existing public IP/NAT) |
| Firewall rules | UDP 51820 between gateways only | TCP 9092 inbound to SuperLink public IP |
| Network complexity | Higher (tunnel, routing, IP forwarding) | Lower (standard TCP connectivity) |
| Performance overhead | Minimal (~3-5% for WireGuard encryption) | None beyond TLS |
| SuperLink exposure | Private network only (not exposed to internet) | Public IP exposed (attack surface) |

---

## 6. Selection Criteria -- WireGuard vs Direct Public IP

Use this decision matrix to choose the cross-zone networking option for your deployment.

| Criterion | Choose WireGuard | Choose Direct Public IP |
|-----------|-----------------|------------------------|
| **Security requirements** | Defense-in-depth required: encrypted tunnel + TLS. SuperLink not exposed to public internet. | TLS encryption is sufficient. Firewall rules restrict access to known SuperNode IPs. |
| **Existing infrastructure** | VPN gateway infrastructure already in place or desired for other services. | Public IPs available. No appetite for VPN management overhead. |
| **TLS certificate management** | Self-signed CA with auto-generated certs (no SAN mismatch because connections use tunnel IPs). | Operator-provided certs with correct SANs, or FL_CERT_EXTRA_SAN for auto-generated certs. |
| **Number of zones** | 3+ zones: hub-and-spoke VPN topology scales predictably. | 2 zones: direct connectivity is simplest. |
| **Firewall policy** | Only UDP 51820 needed between sites. All application ports (9092) flow inside the tunnel. | TCP 9092 must be open inbound to SuperLink. Each new port requires a firewall rule. |
| **Operational complexity** | Higher: WireGuard setup, key management, routing. | Lower: standard TCP connectivity. |
| **Recommended for** | Production multi-site deployments, regulated environments, 3+ zones. | Proof-of-concept, 2-zone deployments, environments with existing public IP allocation. |

**Decision summary:**
- **Default recommendation:** WireGuard for production deployments (defense-in-depth, simpler TLS, no public exposure).
- **Acceptable alternative:** Direct public IP for small deployments or when VPN infrastructure is not available, provided TLS is enabled and certificates have correct SANs.

---

## 7. gRPC Keepalive Configuration

### Why Keepalive Is Needed

Stateful firewalls and NAT devices track TCP connections and drop idle ones after a timeout. Common idle timeouts vary widely:

| Environment | Typical Idle Timeout |
|-------------|---------------------|
| Enterprise firewalls | 60-600 seconds |
| Azure TCP load balancer | 4 minutes (240 seconds) |
| AWS Network Load Balancer | 350 seconds |
| Linux conntrack (default) | 432000 seconds (5 days) |
| Aggressive edge firewalls | 60 seconds |

gRPC's default keepalive interval is 2 hours (7200 seconds) -- far too long for WAN paths through middleboxes. Flower's built-in default (210 seconds, introduced in PR #1069) is better but still risks timeout on aggressive firewalls with 60-second idle limits.

When a firewall drops an idle TCP connection silently, the next gRPC call fails with "transport is closing" or similar errors. The connection appears to work initially but breaks after idle periods between training rounds, especially in later rounds with longer gaps.

### Recommended Values

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| keepalive_time | 60 seconds | Below the most aggressive common firewall timeout (60s). Provides a safe margin. |
| keepalive_timeout | 20 seconds | Time to wait for a keepalive ACK. If no response within 20s, the connection is considered dead. |
| permit_without_calls | true | Send keepalive pings even when no RPCs are active. Essential for idle periods between FL rounds. |

### Client-Side Options (SuperNode)

The SuperNode is the gRPC client. These channel options must be set on the client-side gRPC channel.

| gRPC Channel Option | Value | Description |
|---------------------|-------|-------------|
| `grpc.keepalive_time_ms` | `60000` | Send keepalive ping every 60 seconds. |
| `grpc.keepalive_timeout_ms` | `20000` | Wait 20 seconds for keepalive ACK before declaring connection dead. |
| `grpc.keepalive_permit_without_calls` | `1` | Send keepalive even when no RPCs are in flight. |
| `grpc.http2.max_pings_without_data` | `0` | Allow unlimited pings without data frames (0 = unlimited). |

### Server-Side Options (SuperLink)

The SuperLink is the gRPC server. Server-side options control what the server accepts from clients and when the server itself sends keepalives.

| gRPC Server Option | Value | Description |
|--------------------|-------|-------------|
| `grpc.keepalive_time_ms` | `60000` | Server also sends keepalive pings every 60 seconds. |
| `grpc.keepalive_timeout_ms` | `20000` | Server waits 20 seconds for keepalive ACK. |
| `grpc.keepalive_permit_without_calls` | `1` | Server sends keepalive even when idle. |
| `grpc.http2.min_recv_ping_interval_without_data_ms` | `30000` | Accept client pings as frequently as every 30 seconds. |
| `grpc.http2.max_ping_strikes` | `0` | Do not penalize clients for frequent pings (0 = unlimited). |

### CRITICAL: Keepalive Coordination Rule

**Client `keepalive_time` MUST be >= server `min_recv_ping_interval`.**

If the client sends pings more frequently than the server permits, the server responds with `GOAWAY` frame containing `ENHANCE_YOUR_CALM` error code and closes the connection. This manifests as sudden connection drops with cryptic error messages.

With the recommended values: client keepalive_time = 60s >= server min_recv_ping_interval = 30s. This provides a 2x safety margin.

**Deployment rule:** When adjusting keepalive values, update the server-side configuration first (to accept the new ping frequency), then update clients. Rolling out client changes first may trigger GOAWAY errors on servers that have not yet been updated.

### New CONTEXT Variables

| Variable | USER_INPUT Definition | Default | Appliance | Description |
|----------|----------------------|---------|-----------|-------------|
| `FL_GRPC_KEEPALIVE_TIME` | `O\|number\|gRPC keepalive interval in seconds\|\|60` | `60` | Both (SuperLink + SuperNode) | Interval between keepalive pings, in seconds. Implementation multiplies by 1000 for gRPC millisecond options. |
| `FL_GRPC_KEEPALIVE_TIMEOUT` | `O\|number\|gRPC keepalive ACK timeout in seconds\|\|20` | `20` | Both (SuperLink + SuperNode) | Time to wait for keepalive ACK before declaring connection dead, in seconds. Implementation multiplies by 1000 for gRPC millisecond options. |

**Validation rules:**
- `FL_GRPC_KEEPALIVE_TIME`: Positive integer (>0). Values below 10 generate a warning ("keepalive_time < 10s is aggressive and may cause excessive network traffic").
- `FL_GRPC_KEEPALIVE_TIMEOUT`: Positive integer (>0). Must be less than `FL_GRPC_KEEPALIVE_TIME`.

### Translation to gRPC Options

The configure.sh script translates the CONTEXT variables into environment variables that the Flower process reads at startup.

```bash
# In configure.sh -- keepalive configuration
KEEPALIVE_TIME="${FL_GRPC_KEEPALIVE_TIME:-60}"
KEEPALIVE_TIMEOUT="${FL_GRPC_KEEPALIVE_TIMEOUT:-20}"

# Convert seconds to milliseconds for gRPC
KEEPALIVE_TIME_MS=$((KEEPALIVE_TIME * 1000))
KEEPALIVE_TIMEOUT_MS=$((KEEPALIVE_TIMEOUT * 1000))

# Write to environment file for Docker container
echo "FLOWER_GRPC_KEEPALIVE_TIME_MS=${KEEPALIVE_TIME_MS}" >> /opt/flower/config/flower.env
echo "FLOWER_GRPC_KEEPALIVE_TIMEOUT_MS=${KEEPALIVE_TIMEOUT_MS}" >> /opt/flower/config/flower.env

log "INFO" "gRPC keepalive: time=${KEEPALIVE_TIME}s (${KEEPALIVE_TIME_MS}ms), timeout=${KEEPALIVE_TIMEOUT}s (${KEEPALIVE_TIMEOUT_MS}ms)"
```

**Note on Flower integration:** Flower internally manages gRPC channel creation and sets a default keepalive_time of 210 seconds (PR #1069). The implementation may need to pass channel options via environment variables or extend Flower's configuration surface. The spec defines the operator interface (CONTEXT variables) and the target gRPC values. The exact mechanism by which these values are injected into Flower's gRPC layer is an implementation detail that depends on Flower's configuration surface at deployment time.

---

## 8. TLS Certificate Trust Across Zones

### The Problem

OneGate is zone-local. The auto-discovery TLS path used in single-site deployments -- where SuperNode retrieves `FL_CA_CERT` from OneGate after the SuperLink publishes it -- does not work cross-zone. A SuperNode in Zone B cannot query Zone A's OneGate.

The static `FL_SSL_CA_CERTFILE` path from Phase 2 (`spec/05-supernode-tls-trust.md`, Section 3) is the cross-zone mechanism. This path was designed for exactly this use case: out-of-band CA certificate distribution when OneGate is not available.

### Operator Workflow: Self-Signed CA

For deployments using the SuperLink's auto-generated self-signed CA (Phase 2 default):

**Step 1: Deploy the coordinator zone (Zone A).**
Instantiate the coordinator OneFlow service with `FL_TLS_ENABLED=YES`. Wait for the service to reach RUNNING state and the SuperLink to report `FL_READY=YES`.

**Step 2: Extract the CA certificate from the SuperLink VM.**

```bash
# SSH into the SuperLink VM
ssh root@<superlink-vm-ip>

# Extract and base64-encode the CA certificate
base64 -w0 /opt/flower/certs/ca.crt
# Output: LS0tLS1CRUdJTi... (one long base64 string)
# Copy this string.
```

**Step 3: Configure training site templates with the CA certificate.**
In the training site OneFlow service template (Zone B/C), set:
- `FL_SSL_CA_CERTFILE` = the base64 string copied from Step 2.
- `FL_SUPERLINK_ADDRESS` = the SuperLink's reachable IP:port (WireGuard tunnel IP or public IP, depending on networking option).
- `FL_TLS_ENABLED` = `YES`.

**Step 4: Deploy the training sites (Zones B, C).**
Instantiate the training site OneFlow services. SuperNodes decode `FL_SSL_CA_CERTFILE`, use it as the trust anchor for `--root-certificates`, and connect to the SuperLink with TLS verification.

### Operator Workflow: Enterprise PKI

For organizations with existing certificate authority infrastructure:

**Step 1: Generate certificates from the enterprise CA.**
Create a server certificate for the SuperLink with correct SAN entries:
- Include the SuperLink's private IP.
- Include the WireGuard tunnel IP (if using WireGuard): e.g., `IP:10.10.9.0`.
- Include the public IP or DNS name (if using direct public IP): e.g., `DNS:flower.example.com`.

**Step 2: Configure the coordinator zone SuperLink.**
Set on the SuperLink:
- `FL_SSL_CA_CERTFILE` = base64-encoded enterprise CA certificate.
- `FL_SSL_CERTFILE` = base64-encoded server certificate.
- `FL_SSL_KEYFILE` = base64-encoded server private key.

These trigger the operator-provided path (Phase 2, Section 4) and skip auto-generation.

**Step 3: Configure the training site SuperNodes.**
Set on each training site template:
- `FL_SSL_CA_CERTFILE` = the same base64-encoded enterprise CA certificate.
- `FL_TLS_ENABLED` = `YES`.
- `FL_SUPERLINK_ADDRESS` = SuperLink reachable address.

**Step 4: Deploy all zones.**
All zones can be deployed in parallel since the certificates are pre-provisioned. SuperNodes verify the SuperLink's server certificate against the enterprise CA.

### FL_CERT_EXTRA_SAN Integration with WireGuard

When using a self-signed CA with WireGuard, the auto-generated server certificate SAN contains the SuperLink VM's primary private IP (e.g., `10.10.10.5`). SuperNodes in Zone B connect to the SuperLink via the WireGuard tunnel IP (e.g., `10.10.9.0`). This causes a SAN mismatch.

**Solution:** Set `FL_CERT_EXTRA_SAN=IP:10.10.9.0` on the SuperLink so the auto-generated certificate includes the WireGuard tunnel IP in the SAN. SuperNodes then connect to `10.10.9.0:9092`, which matches the SAN entry.

**Example for SuperLink-as-gateway with WireGuard:**
```
FL_TLS_ENABLED=YES
FL_CERT_EXTRA_SAN=IP:10.10.9.0
```

**Example for dedicated gateway with routing:**
```
FL_TLS_ENABLED=YES
# No FL_CERT_EXTRA_SAN needed if SuperNodes connect to the SuperLink's
# private IP (10.10.10.5) via routing through the WireGuard tunnel.
# The private IP is already in the auto-generated SAN.
```

### Decision: Self-Signed CA vs Enterprise PKI

| Criterion | Self-Signed CA | Enterprise PKI |
|-----------|---------------|----------------|
| Setup complexity | Low (auto-generated at boot) | Higher (cert generation, key management) |
| CA cert distribution | Manual extraction from SuperLink VM | Distributed from enterprise CA infrastructure |
| SAN management | May need FL_CERT_EXTRA_SAN for multi-homed SuperLink | SANs specified during cert generation |
| Certificate lifetime | 365 days (fixed by auto-generation) | Operator-controlled (can be multi-year) |
| Compliance | May not satisfy enterprise security requirements | Integrates with existing compliance framework |
| Recommended for | Development, testing, small multi-site deployments | Production, regulated environments, long-lived deployments |

---

## 9. 3-Zone Deployment Walkthrough

This section provides a complete end-to-end procedure for deploying a 3-zone Flower federation. A reader should be able to plan and execute a multi-site deployment using only this walkthrough and the referenced specs.

### Prerequisites

1. **Three OpenNebula zones** federated under a common OpenNebula master. Users and groups are shared across zones.
2. **Cross-zone networking** established using either WireGuard (Section 4) or direct public IP (Section 5). The SuperLink's Fleet API (port 9092) must be reachable from all training site zones.
3. **VM templates registered** in each zone:
   - Zone A: SuperLink VM template (from the SuperLink QCOW2 appliance).
   - Zone B: SuperNode VM template (from the appropriate framework variant QCOW2).
   - Zone C: SuperNode VM template (same or different framework variant).
4. **OneFlow service templates registered** in each zone:
   - Zone A: Coordinator zone template (Section 3.1).
   - Zone B: Training site template (Section 3.2).
   - Zone C: Training site template (Section 3.2).
5. **WireGuard tunnels active** (if using WireGuard) and verified with `wg show wg0`.

### Phase 1: Deploy Coordinator Zone (Zone A)

**Step 1: Instantiate the coordinator service.**

```bash
# In Zone A
oneflow-template instantiate <coordinator-template-id> \
  --extra_template '{"custom_attrs_values": {
    "FL_TLS_ENABLED": "YES",
    "FL_CERT_EXTRA_SAN": "IP:10.10.9.0",
    "FL_GRPC_KEEPALIVE_TIME": "60",
    "FL_NUM_ROUNDS": "10",
    "FL_MIN_AVAILABLE_CLIENTS": "4"
  }}'
```

**Step 2: Wait for RUNNING state.**

```bash
# Monitor service deployment
oneflow show <service-id>

# Expected progression:
# PENDING -> DEPLOYING -> RUNNING (typically 60-90 seconds)
```

**Step 3: Verify SuperLink is healthy.**

```bash
# SSH into SuperLink VM
ssh root@<superlink-vm-ip>

# Check container status
docker ps | grep flower-superlink

# Check logs
docker logs flower-superlink --tail 20

# Verify TLS certificates were generated
ls -la /opt/flower/certs/
# Expected: ca.key (root:root 0600), ca.crt, server.pem, server.key (49999:49999)
```

**Step 4: Extract the CA certificate.**

```bash
# Still on the SuperLink VM
CA_CERT_B64=$(base64 -w0 /opt/flower/certs/ca.crt)
echo "$CA_CERT_B64"
# Copy this base64 string for use in Zone B/C configuration
```

**Step 5: Note the SuperLink's reachable address.**

For WireGuard: use the SuperLink's WireGuard tunnel IP (e.g., `10.10.9.0:9092`) or its private IP if reachable via routing through the gateway.

For direct public IP: use the public IP and port (e.g., `203.0.113.50:9092`).

### Phase 2: Configure Training Sites (Zones B, C)

**Step 6: Update Zone B training site template.**

Configure the template `user_inputs` or use `--extra_template` at instantiation:
- `FL_SUPERLINK_ADDRESS` = `10.10.9.0:9092` (WireGuard) or `203.0.113.50:9092` (public IP).
- `FL_SSL_CA_CERTFILE` = the base64 CA cert string from Step 4.
- `FL_TLS_ENABLED` = `YES`.
- `FL_GRPC_KEEPALIVE_TIME` = `60`.
- `ML_FRAMEWORK` = `pytorch` (or your chosen framework).

**Step 7: Update Zone C training site template.**

Same configuration as Zone B. `FL_SUPERLINK_ADDRESS` and `FL_SSL_CA_CERTFILE` values are identical (same SuperLink, same CA).

### Phase 3: Deploy Training Sites

**Step 8: Instantiate training site services (can be parallel).**

```bash
# In Zone B
oneflow-template instantiate <training-site-template-id-b> \
  --extra_template '{"custom_attrs_values": {
    "FL_SUPERLINK_ADDRESS": "10.10.9.0:9092",
    "FL_SSL_CA_CERTFILE": "<base64-ca-cert-from-step-4>",
    "FL_TLS_ENABLED": "YES",
    "FL_GRPC_KEEPALIVE_TIME": "60",
    "ML_FRAMEWORK": "pytorch"
  }}'

# In Zone C (can run simultaneously)
oneflow-template instantiate <training-site-template-id-c> \
  --extra_template '{"custom_attrs_values": {
    "FL_SUPERLINK_ADDRESS": "10.10.9.0:9092",
    "FL_SSL_CA_CERTFILE": "<base64-ca-cert-from-step-4>",
    "FL_TLS_ENABLED": "YES",
    "FL_GRPC_KEEPALIVE_TIME": "60",
    "ML_FRAMEWORK": "pytorch"
  }}'
```

**Step 9: Wait for training site services to reach RUNNING.**

```bash
# Monitor Zone B service
oneflow show <service-id-b>

# Monitor Zone C service
oneflow show <service-id-c>

# Expected: PENDING -> DEPLOYING -> RUNNING (30-60 seconds per zone)
# Note: No parents dependency, so SuperNode VMs boot immediately.
# With --max-retries 0, SuperNodes retry until they connect to the SuperLink.
```

### Phase 4: Verify Federation

**Step 10: Verify SuperNode connections on the SuperLink.**

```bash
# SSH into SuperLink VM
ssh root@<superlink-vm-ip>

# Check container logs for connected clients
docker logs flower-superlink 2>&1 | grep -i "client"
# Expected: Messages indicating 4 clients connected (2 from Zone B + 2 from Zone C)
```

**Step 11: Verify from a SuperNode.**

```bash
# SSH into a SuperNode VM in Zone B
ssh root@<supernode-vm-ip>

# Check container status
docker ps | grep flower-supernode

# Check logs for successful connection
docker logs flower-supernode --tail 20
# Expected: Successful gRPC connection to SuperLink, no TLS errors
```

**Step 12: Submit a training run.**

Once `FL_MIN_AVAILABLE_CLIENTS` (default: 4) is satisfied, submit a Flower run:

```bash
# From any machine with access to the SuperLink Control API (port 9093)
# Or via the Flower CLI
flwr run --app <path-to-fab> --insecure  # Use --insecure for Control API only (port 9093)
```

### Deployment Timeline

```
t=0s     Deploy Zone A coordinator service
         |
t=5s     OneFlow creates SuperLink VM in Zone A
         |
         +-- SuperLink boot: OS -> configure.sh -> TLS cert gen -> bootstrap.sh
         |
t=60s    SuperLink RUNNING, FL_READY=YES
t=60s    Operator extracts CA cert (base64 -w0 /opt/flower/certs/ca.crt)
         |
t=120s   Deploy Zone B + Zone C training site services (parallel)
         |
t=125s   OneFlow creates SuperNode VMs in Zone B (2 VMs) and Zone C (2 VMs) in parallel
         |
         +-- SuperNode boot (parallel): OS -> configure.sh -> TLS validate -> bootstrap.sh
         +-- No parents dependency: SuperNodes boot immediately
         +-- --max-retries 0: SuperNodes retry until SuperLink is reachable
         |
t=155s   SuperNode containers start, gRPC connections to SuperLink (cross-zone)
t=160s   TLS handshake succeeds (CA cert from FL_SSL_CA_CERTFILE)
t=165s   All 4 SuperNodes connected. FL_MIN_AVAILABLE_CLIENTS=4 satisfied.
         |
t=165s   3-zone federation fully operational. Training can begin.
```

**Nominal total time:** ~3 minutes from start to fully operational 3-zone federation. The dominant factor is the manual step of extracting and distributing the CA certificate (t=60s to t=120s). With pre-provisioned PKI certificates, Zones B/C can be deployed in parallel with Zone A, reducing total time to ~90 seconds.

### Verification Commands Summary

| What to Check | Command | Expected Output |
|---------------|---------|-----------------|
| Zone A service status | `oneflow show <id-a>` | State: RUNNING |
| Zone B service status | `oneflow show <id-b>` | State: RUNNING |
| Zone C service status | `oneflow show <id-c>` | State: RUNNING |
| SuperLink container | `docker logs flower-superlink` | Fleet API listening, clients connected |
| SuperNode container | `docker logs flower-supernode` | Connected to SuperLink, no TLS errors |
| WireGuard tunnel | `wg show wg0` | Transfer data visible, handshake recent |
| TLS certificate SAN | `openssl x509 -in /opt/flower/certs/server.pem -noout -text \| grep -A3 "Subject Alternative"` | Includes tunnel/public IP |
| OneGate readiness | `curl -s ${ONEGATE_ENDPOINT}/vm -H "X-ONEGATE-TOKEN: ..."` | FL_READY=YES |

---

## 10. Failure Modes and Recovery

| # | Failure | Symptom | Cause | Recovery |
|---|---------|---------|-------|----------|
| 1 | **WireGuard tunnel down** | SuperNode gRPC connections fail with "transport is closing" or TCP timeout. | WireGuard interface down, peer unreachable, UDP 51820 blocked. | Check `wg show wg0` on both gateways. Verify UDP 51820 is open. Restart with `systemctl restart wg-quick@wg0`. SuperNodes reconnect automatically (`--max-retries 0`). |
| 2 | **SuperLink VM crash** | All SuperNode connections drop simultaneously. SuperNodes enter reconnection loop. | SuperLink process crash, VM reboot, host failure. | Same as single-site recovery (Phase 4, Section 9): systemd restarts the container (`restart: unless-stopped`). SuperNodes reconnect when the SuperLink is back. If checkpointing is enabled, training resumes from the last checkpoint. |
| 3 | **CA cert mismatch** | SuperNode TLS handshake fails: "certificate verify failed". SuperNode container runs but cannot train. | `FL_SSL_CA_CERTFILE` in Zone B/C does not match the CA that signed the SuperLink's server certificate. Operator copied wrong cert or SuperLink was redeployed (new CA generated). | Re-extract CA cert from SuperLink: `base64 -w0 /opt/flower/certs/ca.crt`. Update `FL_SSL_CA_CERTFILE` in training site templates. Redeploy training site services. |
| 4 | **SAN mismatch** | SuperNode TLS handshake fails: "hostname mismatch". Similar to #3 but different root cause. | SuperNode connects to an IP not listed in the server certificate's SAN. Common when using WireGuard or public IP without `FL_CERT_EXTRA_SAN`. | Add the connection IP to the SuperLink's SAN: set `FL_CERT_EXTRA_SAN=IP:<tunnel-or-public-ip>`. Redeploy the coordinator service to regenerate certs. Re-extract and redistribute the new CA cert. |
| 5 | **Firewall idle timeout** | gRPC connections silently dropped after idle period. Training succeeds for early rounds but fails in later rounds with longer gaps. | Stateful firewall drops idle TCP connections before the next gRPC message. | Configure keepalive: set `FL_GRPC_KEEPALIVE_TIME=60` on both SuperLink and SuperNodes. If the firewall timeout is known, set keepalive to 50% of the timeout value. |
| 6 | **Zone B/C deployed before Zone A** | SuperNodes in retry loop attempting to connect. Service appears stuck in DEPLOYING. | Operator deployed training sites before the coordinator was ready. | Not a failure -- by design. SuperNodes with `--max-retries 0` retry indefinitely. Once the SuperLink becomes available, connections succeed automatically. The operator should monitor and wait. |
| 7 | **GOAWAY ENHANCE_YOUR_CALM** | SuperNode connections drop with "ENHANCE_YOUR_CALM" error. Clients reconnect but immediately get dropped again. | Client keepalive_time < server min_recv_ping_interval. The server rejects the client's ping frequency. | Ensure `FL_GRPC_KEEPALIVE_TIME` is the same or higher on clients than the server's expected minimum interval. With defaults (60s client, 30s server min), this should not occur. |
| 8 | **Partial zone failure** | Some SuperNodes in Zone B disconnect. Zone C SuperNodes continue training. Training rounds proceed with reduced client count. | Network partition or hardware failure affecting some VMs in one zone. | If remaining clients >= `FL_MIN_FIT_CLIENTS`, training continues automatically. If below threshold, SuperLink waits. Fix the affected VMs or scale up in unaffected zones. |

---

## 11. Anti-Patterns

Common misconfigurations specific to multi-site federation deployments.

| Anti-Pattern | What Goes Wrong | Correct Approach |
|-------------|----------------|-----------------|
| **Trying OneFlow across zones** | OneFlow is zone-local. Referencing a VM template from another zone in a service template fails. A single service cannot span zones. | Create separate OneFlow services in each zone: coordinator template in Zone A, training site template in Zones B/C. Coordinate deployments manually (deploy Zone A first). |
| **Relying on OneGate for cross-zone discovery** | SuperNodes in Zone B query local OneGate, find no SuperLink in local zone, enter discovery retry loop for 5 minutes, and boot fails. | Set `FL_SUPERLINK_ADDRESS` as mandatory (`M\|text`) in the training site template. Use the SuperLink's reachable IP (tunnel or public). |
| **Skipping TLS for cross-zone traffic** | gRPC model weights traverse WAN paths in plaintext. Model gradients are visible to network observers. Potential for model inversion attacks. | Always enable TLS for cross-zone: set `FL_TLS_ENABLED=YES` and provide `FL_SSL_CA_CERTFILE` on all SuperNodes. The coordinator template defaults to `FL_TLS_ENABLED=YES`. |
| **Using auto-generated certs with NAT/public IP without FL_CERT_EXTRA_SAN** | Auto-generated cert SAN contains the VM's private IP. SuperNodes connect via public/tunnel IP. TLS handshake fails with SAN mismatch. | Set `FL_CERT_EXTRA_SAN` on the SuperLink with the public/tunnel IP. Or use operator-provided certificates with correct SANs. |
| **Setting client keepalive_time below server min_recv_ping_interval** | Server sends GOAWAY with ENHANCE_YOUR_CALM error. Client connections are immediately dropped and the reconnection loop triggers the same error. | Ensure client `FL_GRPC_KEEPALIVE_TIME` >= 30s (the default server `min_recv_ping_interval` is 30s). Use the same `FL_GRPC_KEEPALIVE_TIME` value on both SuperLink and SuperNodes. |
| **Deploying SuperNodes in the coordinator zone template** | The coordinator template is for the SuperLink only (singleton). Adding a SuperNode role creates a hybrid single-site/multi-site deployment that conflicts with training site SuperNodes. | Use the single-site template (Phase 4) for same-zone deployments. Use the coordinator template (Section 3.1) only for the SuperLink in multi-site federation. If some SuperNodes should be in Zone A alongside the SuperLink, deploy a separate training site service in Zone A. |

---

## 12. New Contextualization Variables Summary

Phase 7 introduces three new contextualization variables. These are added to the existing variable reference (`spec/03-contextualization-reference.md`).

### Variable Definitions

| # | Context Variable | USER_INPUT Definition | Type | Default | Appliance | Validation Rule | Purpose |
|---|------------------|----------------------|------|---------|-----------|-----------------|---------|
| 1 | `FL_GRPC_KEEPALIVE_TIME` | `O\|number\|gRPC keepalive interval in seconds\|\|60` | number | `60` | Both (SuperLink + SuperNode) | Positive integer (>0). Warning if <10. | Interval between gRPC keepalive pings. Values in seconds; implementation multiplies by 1000 for gRPC millisecond options. |
| 2 | `FL_GRPC_KEEPALIVE_TIMEOUT` | `O\|number\|gRPC keepalive ACK timeout in seconds\|\|20` | number | `20` | Both (SuperLink + SuperNode) | Positive integer (>0). Must be < `FL_GRPC_KEEPALIVE_TIME`. | Time to wait for keepalive ACK before declaring connection dead. Values in seconds; implementation multiplies by 1000 for gRPC millisecond options. |
| 3 | `FL_CERT_EXTRA_SAN` | `O\|text\|Additional SAN entries for auto-generated cert (comma-separated)\|\|` | text | (empty) | SuperLink only | If set: comma-separated `IP:<addr>` or `DNS:<name>` entries. | Additional Subject Alternative Name entries for the auto-generated server certificate. Used to add WireGuard tunnel IPs, public IPs, or DNS names to the SAN. |

### USER_INPUT Definitions (Copy-Paste Ready)

```
# Phase 7: Multi-Site Federation
FL_GRPC_KEEPALIVE_TIME = "O|number|gRPC keepalive interval in seconds||60"
FL_GRPC_KEEPALIVE_TIMEOUT = "O|number|gRPC keepalive ACK timeout in seconds||20"
FL_CERT_EXTRA_SAN = "O|text|Additional SAN entries for auto-generated cert (comma-separated)||"
```

### Updated Variable Count

With Phase 7 additions, the total contextualization variable count updates:

| Category | Count | Change |
|----------|-------|--------|
| SuperLink parameters | 22 | +3 (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN) |
| SuperNode parameters | 12 | +2 (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT) |
| Shared infrastructure | 5 | (unchanged) |
| Phase 2+ placeholders | 5 | (unchanged) |
| **Total unique variables** | **42** | **+3 new** |

*Note:* FL_GRPC_KEEPALIVE_TIME and FL_GRPC_KEEPALIVE_TIMEOUT appear on both appliances but are counted once each in the total.

---

*Specification for ORCH-02: Multi-Site Federation Architecture*
*Phase: 07 - Multi-Site Federation*
*Version: 1.0*
