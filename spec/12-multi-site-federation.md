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
