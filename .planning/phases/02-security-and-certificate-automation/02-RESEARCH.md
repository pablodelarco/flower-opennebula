# Phase 2: Security and Certificate Automation - Research

**Researched:** 2026-02-07
**Domain:** TLS certificate lifecycle for Flower federated learning on OpenNebula (generation, distribution via OneGate, trust chain, file permissions)
**Confidence:** HIGH

## Summary

This phase specifies how the Flower SuperLink and SuperNode appliances transition from `--insecure` mode (Phase 1) to TLS-encrypted gRPC communication. The research covers three key areas: (1) Flower's TLS CLI interface and certificate requirements, (2) the certificate generation process at SuperLink boot time using OpenSSL, and (3) the distribution of the CA certificate from SuperLink to SuperNodes via OneGate.

Flower uses **server-side TLS** (not mutual TLS). The SuperLink holds three files: CA certificate, server certificate, and server private key. The SuperNode holds only the CA certificate, which it uses to verify the SuperLink's identity via `--root-certificates`. This is a standard gRPC server-side TLS pattern -- the server proves its identity to the client; the client does not prove its identity to the server. Flower has a separate, optional SuperNode authentication layer (ECDSA signature-based) that sits on top of TLS, but that is out of scope for APPL-04.

The recommended architecture generates a self-signed CA and server certificate on the SuperLink VM at boot time, publishes the CA certificate (base64-encoded PEM) to OneGate, and has SuperNodes retrieve it during their discovery phase. This extends the existing OneGate-based discovery model from Phase 1 without introducing new infrastructure dependencies.

**Primary recommendation:** Generate certificates at SuperLink boot (Step 7 in the boot sequence, after validation, before container start), publish CA cert to OneGate as `FL_CA_CERT`, and have SuperNodes retrieve it during their existing discovery query. Use openssl for generation. No external CA infrastructure required.

## Standard Stack

The established tools for this domain:

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| OpenSSL | 3.0+ (ships with Ubuntu 24.04) | CA + server certificate generation | Pre-installed on Ubuntu 24.04, industry standard, no additional dependencies |
| Flower TLS CLI flags | Flower 1.25.0 | SuperLink: `--ssl-ca-certfile`, `--ssl-certfile`, `--ssl-keyfile`; SuperNode: `--root-certificates` | Official Flower API for TLS configuration |
| OneGate API | OpenNebula 7.0 | CA certificate distribution from SuperLink to SuperNodes | Already used for service discovery; no new infrastructure |
| base64 | coreutils | Encode/decode PEM certificates for OneGate transport | Pre-installed, handles PEM-safe transport through OneGate attributes |

### Supporting
| Tool | Version | Purpose | When to Use |
|------|---------|---------|-------------|
| `text64` USER_INPUT type | OpenNebula 7.0 | Accept pre-generated CA cert via contextualization | When operator wants to use their own CA instead of auto-generated |
| jq | any | Parse OneGate JSON response for FL_CA_CERT extraction | Already required for discovery (Phase 1) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Boot-time self-signed CA | External PKI/CA infrastructure | External CA is more secure for production but adds infrastructure dependency; out of scope for marketplace appliance that must work standalone |
| OneGate cert distribution | CONTEXT variables only (text64) | CONTEXT-only means operator must manually provide certs; auto-generation + OneGate distribution is the zero-config path |
| OpenSSL CLI | Python cryptography library | Would require installing Python packages on host; OpenSSL is already available and simpler for shell scripts |

**No installation required.** All tools (openssl, base64, curl, jq) are already present in the Phase 1 QCOW2 image.

## Architecture Patterns

### Certificate File Layout

```
/opt/flower/certs/                  # Already exists from Phase 1 (owned by 49999:49999, mode 0700)
    ca.crt                          # CA certificate (PEM) -- generated or provided
    server.pem                      # Server certificate signed by CA (PEM) -- SuperLink only
    server.key                      # Server private key (PEM) -- SuperLink only, mode 0600
```

**Inside Docker container (via volume mount):**
```
/app/certificates/                  # Mount target for SuperLink
    ca.crt
    server.pem
    server.key

/app/ca.crt                         # Mount target for SuperNode (single file)
```

### Pattern 1: Server-Side TLS (Flower's Model)

**What:** The SuperLink presents a TLS server certificate; SuperNodes verify it using the CA certificate. This is standard gRPC server-side TLS. The SuperNode does NOT present a client certificate -- Flower does NOT use mutual TLS (mTLS) for its base TLS implementation.

**When to use:** Always when TLS is enabled. This is the only TLS mode Flower supports at the transport layer.

**Trust chain:**
```
Self-signed CA (generated at SuperLink boot)
    |
    +-- signs --> Server Certificate (with SuperLink IP as SAN)
    |
    +-- distributed to --> SuperNode (via OneGate or CONTEXT variable)
                          Used as --root-certificates to verify SuperLink
```

**SuperLink Docker run (TLS mode):**
```bash
docker run --rm \
  --name flower-superlink \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  -v /opt/flower/certs:/app/certificates:ro \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --ssl-ca-certfile certificates/ca.crt \
  --ssl-certfile certificates/server.pem \
  --ssl-keyfile certificates/server.key \
  --isolation subprocess \
  --fleet-api-address 0.0.0.0:9092 \
  --database state/state.db
```
Source: https://flower.ai/docs/framework/docker/enable-tls.html

**SuperNode Docker run (TLS mode):**
```bash
docker run --rm \
  --name flower-supernode \
  -v /opt/flower/data:/app/data:ro \
  -v /opt/flower/certs/ca.crt:/app/ca.crt:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --root-certificates ca.crt \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES:-0} \
  --max-wait-time ${FL_MAX_WAIT_TIME:-0}
```
Source: https://flower.ai/docs/framework/docker/enable-tls.html

**Key change from Phase 1:** The `--insecure` flag is REMOVED and replaced with certificate flags. Both sides must agree on TLS mode -- mixing `--insecure` on one side with TLS on the other causes connection failure.

### Pattern 2: Boot-Time Certificate Generation on SuperLink

**What:** The SuperLink generates a self-signed CA and server certificate during the configure stage, before the Flower container starts.

**When to use:** Default behavior when `FL_TLS_ENABLED=YES` and no pre-existing certificates are provided via `FL_SSL_CA_CERTFILE`.

**Sequence (new boot step, between current Steps 7 and 8):**
```
Step 7a: Generate TLS certificates (new)
  IF FL_TLS_ENABLED=YES:
    IF FL_SSL_CA_CERTFILE is provided (pre-existing CA):
      Decode base64 CONTEXT variables to /opt/flower/certs/
      (operator-provided certs, no generation needed)
    ELSE:
      Generate self-signed CA:
        openssl genrsa -out /opt/flower/certs/ca.key 4096
        openssl req -new -x509 -key ca.key -sha256 -days 365 -out ca.crt
      Generate server certificate with VM IP as SAN:
        openssl genrsa -out /opt/flower/certs/server.key 4096
        openssl req -new -key server.key -out server.csr -config <(dynamic_conf)
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key \
          -CAcreateserial -out server.pem -days 365 -sha256 \
          -extfile <(dynamic_conf) -extensions req_ext
      Set file ownership: chown 49999:49999 /opt/flower/certs/*
      Set key permissions: chmod 0600 /opt/flower/certs/server.key /opt/flower/certs/ca.key
  ELSE:
    Skip certificate generation (Phase 1 insecure mode)
```

### Pattern 3: CA Certificate Distribution via OneGate

**What:** After generating certificates, the SuperLink publishes the CA certificate to OneGate so SuperNodes can retrieve it during their discovery phase.

**When to use:** Default for OneFlow deployments with auto-generated certificates.

**SuperLink publishes (added to Step 12 -- OneGate publication):**
```bash
# Base64-encode the CA cert for safe OneGate transport
CA_CERT_B64=$(base64 -w0 /opt/flower/certs/ca.crt)

curl -s -X PUT "${ONEGATE_ENDPOINT}/vm" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_READY=YES" \
  -d "FL_ENDPOINT=${MY_IP}:9092" \
  -d "FL_VERSION=${FLOWER_VERSION}" \
  -d "FL_ROLE=superlink" \
  -d "FL_TLS=YES" \
  -d "FL_CA_CERT=${CA_CERT_B64}"
```

**SuperNode retrieves (during discovery, Step 7):**
```bash
# Extract CA cert from OneGate service response
FL_CA_CERT_B64=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_CA_CERT // empty
')

if [ -n "$FL_CA_CERT_B64" ]; then
    echo "$FL_CA_CERT_B64" | base64 -d > /opt/flower/certs/ca.crt
    chown 49999:49999 /opt/flower/certs/ca.crt
fi
```

### Pattern 4: Dual Certificate Provisioning (Auto vs Manual)

**What:** Two paths for getting certificates onto the appliance. Auto-generation is the zero-config default; manual provisioning via CONTEXT variables supports operators who have their own CA.

**Decision logic:**
```
IF FL_TLS_ENABLED != YES:
    Use --insecure (Phase 1 behavior)

IF FL_SSL_CA_CERTFILE is set (base64 PEM via text64):
    Decode FL_SSL_CA_CERTFILE -> /opt/flower/certs/ca.crt
    Decode FL_SSL_CERTFILE   -> /opt/flower/certs/server.pem  (SuperLink only)
    Decode FL_SSL_KEYFILE    -> /opt/flower/certs/server.key   (SuperLink only)
    (operator-provided certificates, skip generation)

ELSE:
    Auto-generate CA + server cert (Pattern 2)
    Publish CA cert to OneGate (Pattern 3)
```

### Anti-Patterns to Avoid

- **Distributing the server private key:** The CA private key (`ca.key`) and server private key (`server.key`) MUST stay on the SuperLink VM. Only the CA certificate (`ca.crt`) is distributed. Publishing private keys to OneGate would be a critical security vulnerability.
- **Using `--insecure` in production:** Phase 1's insecure mode transmits model weights in plaintext over gRPC. This is acceptable for development only. Phase 2 makes TLS the recommended default.
- **Hardcoding certificate SANs:** The server certificate MUST include the SuperLink VM's actual IP address as a Subject Alternative Name (SAN). Using `localhost` or `127.0.0.1` only works for same-machine testing. At boot time, the script must dynamically detect the VM's IP and include it in the SAN.
- **Skipping file ownership:** Flower containers run as UID 49999. Certificate files mounted into the container MUST be readable by this user. Forgetting `chown 49999:49999` causes "Permission denied" errors that are hard to diagnose.
- **Using PEM files with incorrect line endings:** OpenSSL and gRPC expect proper PEM formatting. When transporting certificates through OneGate (URL-encoded form data) or CONTEXT variables (base64), ensure encoding/decoding preserves the PEM structure.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| TLS certificate generation | Custom Python script with cryptography library | OpenSSL CLI (`openssl genrsa`, `openssl req`, `openssl x509`) | OpenSSL is pre-installed, well-documented, and handles all edge cases. Shell scripts are sufficient for CA + server cert generation. |
| Certificate format conversion | Custom encoding/decoding | `base64 -w0` (encode) / `base64 -d` (decode) | Standard coreutils, handles PEM safely |
| SAN configuration for dynamic IPs | Hardcoded config file | bash process substitution with `<(cat <<EOF ... EOF)` | Allows injecting VM IP at runtime without temp files |
| Certificate validation | Manual openssl verify commands | `openssl verify -CAfile ca.crt server.pem` | One-line verification built into OpenSSL |
| Mutual TLS / client certificates | Custom mTLS implementation | Flower's built-in SuperNode authentication (`--enable-supernode-auth`) | Flower uses ECDSA signature-based auth, not mTLS. Don't implement client certificates -- they are not part of Flower's security model. |

**Key insight:** The entire certificate lifecycle can be implemented with OpenSSL CLI commands in bash scripts. No additional packages, libraries, or infrastructure are needed beyond what Phase 1 already provides.

## Common Pitfalls

### Pitfall 1: SAN Mismatch Causes "Certificate Verify Failed"

**What goes wrong:** The server certificate's Subject Alternative Names (SANs) don't include the IP address that SuperNodes use to connect. gRPC TLS verification fails with `ssl_transport_security.cc` errors.
**Why it happens:** The certificate is generated with `CN=localhost` and SANs for `127.0.0.1` only (copied from Flower's dev script), but SuperNodes connect to the VM's actual network IP (e.g., `192.168.1.100`).
**How to avoid:** At certificate generation time, detect the VM's IP using `hostname -I | awk '{print $1}'` and include it as `IP.1` in the SAN extension. Also include `localhost` and `127.0.0.1` for local testing.
**Warning signs:** SuperNode logs show "SSL handshake failed" or "certificate verify failed" immediately after connecting.

### Pitfall 2: File Permission Errors on Certificate Mounts

**What goes wrong:** The Flower container starts but crashes with "Permission denied" when reading certificate files.
**Why it happens:** Certificate files generated by root-owned scripts have `root:root` ownership. The Flower container runs as UID 49999 (`app` user) and cannot read them.
**How to avoid:** After generating certificates, always run `chown -R 49999:49999 /opt/flower/certs/`. The `/opt/flower/certs/` directory was created in Phase 1 with correct ownership, but files generated inside it by root scripts will have root ownership.
**Warning signs:** Container exits immediately on start. `docker logs flower-superlink` shows permission errors on cert file paths.

### Pitfall 3: Base64 Encoding Breaks PEM Structure

**What goes wrong:** CA certificate retrieved from OneGate is malformed -- line breaks are missing or extra whitespace is added.
**Why it happens:** OneGate attribute values are stored as strings in XML. URL encoding during PUT and XML parsing during GET can corrupt multi-line PEM content. Base64 encoding is needed to preserve the PEM structure.
**How to avoid:** Always base64-encode the entire PEM file before publishing to OneGate (`base64 -w0` for single-line output). Decode on the receiving side with `base64 -d`. Do NOT try to publish raw PEM content as a OneGate attribute.
**Warning signs:** SuperNode's `ca.crt` file contains garbled content. `openssl x509 -in ca.crt -text` fails with "unable to load certificate."

### Pitfall 4: TLS Mode Mismatch Between SuperLink and SuperNode

**What goes wrong:** SuperLink runs with TLS enabled but SuperNode connects with `--insecure`, or vice versa. Connection fails silently or with cryptic gRPC errors.
**Why it happens:** The `FL_TLS_ENABLED` variable is not synchronized between roles in a OneFlow service. One VM has TLS enabled, another doesn't.
**How to avoid:** In OneFlow service templates, set `FL_TLS_ENABLED` at the service level (applied to all roles), not per-role. The spec should mandate that both sides MUST agree on TLS mode. SuperNodes should detect TLS mode from the `FL_TLS` attribute published by SuperLink to OneGate.
**Warning signs:** SuperNode log shows "Connection refused" or "handshake failed" errors. SuperLink log shows unexpected plaintext data on TLS port.

### Pitfall 5: CA Key Leakage Through OneGate

**What goes wrong:** The CA private key (`ca.key`) is accidentally published to OneGate alongside the CA certificate.
**Why it happens:** Script publishes all files in `/opt/flower/certs/` without filtering.
**How to avoid:** The publication script must explicitly name only `ca.crt` for OneGate publication. Never use glob patterns. The CA private key should have mode 0600 and be excluded from any publication mechanism. After certificate generation is complete, consider whether the CA key even needs to be retained (it doesn't, unless cert rotation is needed).
**Warning signs:** `FL_CA_KEY` attribute appears in OneGate. Any SuperNode operator can now forge certificates.

### Pitfall 6: Certificate Expiry After 365 Days

**What goes wrong:** Certificates generated at boot time expire after 365 days (the standard validity period). After expiry, all SuperNode connections fail.
**Why it happens:** Self-signed certificates have a fixed validity period. The appliance is immutable -- there is no certificate rotation mechanism.
**How to avoid:** Document that certificates expire with the deployment. For long-running deployments, operators should either: (a) redeploy the service before expiry, or (b) provide their own long-lived certificates via the `FL_SSL_*` CONTEXT variables. The 365-day default is sufficient for most FL training campaigns, which run for hours to weeks, not years.
**Warning signs:** After ~1 year of uptime, SuperNodes fail to connect. OpenSSL logs show "certificate has expired."

## Code Examples

Verified patterns from official sources and standard OpenSSL usage:

### Complete Certificate Generation Script

```bash
#!/bin/bash
# /opt/flower/scripts/generate-certs.sh
# Generates self-signed CA + server certificate for Flower TLS
# Called during SuperLink boot when FL_TLS_ENABLED=YES and no certs provided

set -euo pipefail
source /opt/flower/scripts/common.sh

CERT_DIR="/opt/flower/certs"
CERT_DAYS=365
KEY_SIZE=4096

# Detect VM IP for SAN
VM_IP=$(hostname -I | awk '{print $1}')
if [ -z "$VM_IP" ]; then
    log "ERROR" "Cannot detect VM IP for certificate SAN"
    exit 1
fi

log "INFO" "Generating TLS certificates with SAN for IP: ${VM_IP}"

# Step 1: Generate CA private key
openssl genrsa -out "${CERT_DIR}/ca.key" ${KEY_SIZE} 2>/dev/null
log "INFO" "CA private key generated"

# Step 2: Generate self-signed CA certificate
openssl req -new -x509 \
    -key "${CERT_DIR}/ca.key" \
    -sha256 \
    -subj "/O=Flower FL/CN=Flower CA" \
    -days ${CERT_DAYS} \
    -out "${CERT_DIR}/ca.crt" 2>/dev/null
log "INFO" "CA certificate generated (valid ${CERT_DAYS} days)"

# Step 3: Generate server private key
openssl genrsa -out "${CERT_DIR}/server.key" ${KEY_SIZE} 2>/dev/null
log "INFO" "Server private key generated"

# Step 4: Generate server CSR with dynamic SAN
openssl req -new \
    -key "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.csr" \
    -config <(cat <<EOF
[req]
default_bits = ${KEY_SIZE}
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn

[dn]
O = Flower FL
CN = ${VM_IP}

[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = ${VM_IP}
EOF
) 2>/dev/null
log "INFO" "Server CSR generated with SAN: localhost, 127.0.0.1, ::1, ${VM_IP}"

# Step 5: Sign server certificate with CA
openssl x509 -req \
    -in "${CERT_DIR}/server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/server.pem" \
    -days ${CERT_DAYS} \
    -sha256 \
    -extfile <(cat <<EOF
[req_ext]
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = ${VM_IP}
EOF
) \
    -extensions req_ext 2>/dev/null
log "INFO" "Server certificate signed by CA"

# Step 6: Clean up CSR and serial (not needed at runtime)
rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/ca.srl"

# Step 7: Set ownership and permissions
chown 49999:49999 "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.pem" "${CERT_DIR}/server.key"
chmod 0644 "${CERT_DIR}/ca.crt"          # CA cert: readable by all (will be distributed)
chmod 0644 "${CERT_DIR}/server.pem"       # Server cert: readable
chmod 0600 "${CERT_DIR}/server.key"       # Server key: owner-only
chmod 0600 "${CERT_DIR}/ca.key"           # CA key: owner-only (root keeps this)
chown root:root "${CERT_DIR}/ca.key"      # CA key stays root-owned

# Step 8: Verify certificate chain
if openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.pem" >/dev/null 2>&1; then
    log "INFO" "Certificate chain verified successfully"
else
    log "ERROR" "Certificate chain verification FAILED"
    exit 1
fi

log "INFO" "TLS certificate generation complete"
```
Source: Based on Flower's official generate.sh (https://github.com/adap/flower/blob/main/dev/certificates/generate.sh) adapted for dynamic IP SAN and OpenNebula deployment context.

### Decoding Operator-Provided Certificates from CONTEXT Variables

```bash
# When operator provides certificates via CONTEXT (text64 type)
decode_context_certs() {
    local cert_dir="/opt/flower/certs"

    if [ -n "${FL_SSL_CA_CERTFILE:-}" ]; then
        echo "${FL_SSL_CA_CERTFILE}" | base64 -d > "${cert_dir}/ca.crt"
        log "INFO" "CA certificate decoded from FL_SSL_CA_CERTFILE"
    fi

    if [ -n "${FL_SSL_CERTFILE:-}" ]; then
        echo "${FL_SSL_CERTFILE}" | base64 -d > "${cert_dir}/server.pem"
        log "INFO" "Server certificate decoded from FL_SSL_CERTFILE"
    fi

    if [ -n "${FL_SSL_KEYFILE:-}" ]; then
        echo "${FL_SSL_KEYFILE}" | base64 -d > "${cert_dir}/server.key"
        log "INFO" "Server private key decoded from FL_SSL_KEYFILE"
    fi

    # Set ownership
    chown 49999:49999 "${cert_dir}/ca.crt" "${cert_dir}/server.pem" "${cert_dir}/server.key"
    chmod 0600 "${cert_dir}/server.key"
}
```

### SuperNode CA Certificate Retrieval from OneGate

```bash
# During SuperNode discovery (extends existing discover.sh)
retrieve_ca_cert() {
    local service_json="$1"
    local cert_dir="/opt/flower/certs"

    # Check if SuperLink advertises TLS
    local tls_flag
    tls_flag=$(echo "$service_json" | jq -r '
      .SERVICE.roles[]
      | select(.name == "superlink")
      | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_TLS // empty
    ')

    if [ "$tls_flag" = "YES" ]; then
        local ca_cert_b64
        ca_cert_b64=$(echo "$service_json" | jq -r '
          .SERVICE.roles[]
          | select(.name == "superlink")
          | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_CA_CERT // empty
        ')

        if [ -n "$ca_cert_b64" ]; then
            echo "$ca_cert_b64" | base64 -d > "${cert_dir}/ca.crt"
            chown 49999:49999 "${cert_dir}/ca.crt"
            log "INFO" "CA certificate retrieved from OneGate"
            return 0
        else
            log "ERROR" "SuperLink has TLS enabled but FL_CA_CERT not published"
            return 1
        fi
    fi

    return 0  # No TLS, no cert needed
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single `--certificates` flag (tuple) | Three separate flags: `--ssl-ca-certfile`, `--ssl-certfile`, `--ssl-keyfile` | Flower 1.9+ | Clearer API, each cert file specified independently |
| `root_certificates` parameter in Python API | `--root-certificates` CLI flag for SuperNode | Flower 1.9+ (SuperExec architecture) | CLI-native TLS for Docker deployments |
| `--insecure` is default | TLS is recommended default for production | Flower documentation 2024+ | `--insecure` is explicitly warned against in docs |
| `enable-ssl-connections` docs page | `enable-tls-connections` docs page | Flower docs restructure | Updated terminology from SSL to TLS throughout |

**Deprecated/outdated:**
- The old `--certificates` flag (single tuple) is deprecated. Use the three separate `--ssl-*` flags.
- Flower's `generate_creds.py` Python script is no longer the primary example. The `dev/certificates/generate.sh` bash script is the current reference.
- The term "SSL" in Flower's API flags is a legacy naming convention. The actual protocol is TLS 1.2+.

## Contextualization Variable Updates for Phase 2

The Phase 1 spec already defines placeholder variables for Phase 2 TLS. Here is the refined specification based on research:

### New/Updated Variables

| Variable | Type | Default | Appliance | Purpose |
|----------|------|---------|-----------|---------|
| `FL_TLS_ENABLED` | `O\|boolean` | `NO` | Both | Master switch. `YES` enables TLS, `NO` keeps `--insecure`. |
| `FL_SSL_CA_CERTFILE` | `O\|text64` | (empty) | Both | Base64-encoded PEM CA certificate. If set on SuperLink, skips auto-generation. If set on SuperNode, uses this instead of OneGate retrieval. |
| `FL_SSL_CERTFILE` | `O\|text64` | (empty) | SuperLink | Base64-encoded PEM server certificate. Required if FL_SSL_CA_CERTFILE is set. |
| `FL_SSL_KEYFILE` | `O\|text64` | (empty) | SuperLink | Base64-encoded PEM server private key. Required if FL_SSL_CA_CERTFILE is set. |

### OneGate Published Attributes (SuperLink -> SuperNode)

| Attribute | Value | Purpose |
|-----------|-------|---------|
| `FL_TLS` | `YES` or `NO` | Whether SuperLink is running with TLS |
| `FL_CA_CERT` | base64-encoded PEM CA certificate | CA certificate for SuperNode trust verification |

### Validation Rules

| Variable | Rule |
|----------|------|
| `FL_TLS_ENABLED` | `YES` or `NO` (case-insensitive) |
| `FL_SSL_CA_CERTFILE` | If set: must decode to valid PEM (`openssl x509 -in - -noout`) |
| `FL_SSL_CERTFILE` | Required if `FL_SSL_CA_CERTFILE` is set on SuperLink |
| `FL_SSL_KEYFILE` | Required if `FL_SSL_CA_CERTFILE` is set on SuperLink |

### Consistency Rules

- If `FL_TLS_ENABLED=YES` on SuperLink, ALL SuperNodes MUST also have TLS enabled (either via OneGate auto-detection or explicit `FL_TLS_ENABLED=YES`).
- If `FL_SSL_CA_CERTFILE` is provided on SuperLink, `FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` MUST also be provided (all three or none).
- SuperNodes using OneGate discovery auto-detect TLS mode from the `FL_TLS` attribute published by SuperLink.
- SuperNodes using static discovery (`FL_SUPERLINK_ADDRESS`) MUST have `FL_TLS_ENABLED` and `FL_SSL_CA_CERTFILE` set explicitly (no OneGate to retrieve from).

## Boot Sequence Changes

### SuperLink Boot Sequence (Updated)

```
Phase 1 Steps 1-7 remain unchanged.

NEW Step 7a: TLS Certificate Setup
  IF FL_TLS_ENABLED == YES:
    IF FL_SSL_CA_CERTFILE is set:
      Decode FL_SSL_CA_CERTFILE -> /opt/flower/certs/ca.crt
      Decode FL_SSL_CERTFILE   -> /opt/flower/certs/server.pem
      Decode FL_SSL_KEYFILE    -> /opt/flower/certs/server.key
      Validate chain: openssl verify -CAfile ca.crt server.pem
    ELSE:
      Run /opt/flower/scripts/generate-certs.sh
      (generates self-signed CA + server cert with VM IP SAN)
    Set ownership: chown 49999:49999 certs/*
    Update Docker run command: remove --insecure, add --ssl-* flags
    Add volume mount: -v /opt/flower/certs:/app/certificates:ro

Step 8 (generate systemd unit): Updated to include TLS flags conditionally
Steps 9-11 remain unchanged.

Step 12 (OneGate publication): UPDATED
  Add FL_TLS=YES and FL_CA_CERT=(base64 ca.crt) to publication
```

### SuperNode Boot Sequence (Updated)

```
Phase 1 Steps 1-6 remain unchanged.

Step 7 (discovery): UPDATED
  After discovering FL_ENDPOINT, also check:
    IF FL_TLS attribute is "YES" on SuperLink:
      Retrieve FL_CA_CERT from OneGate response
      Decode to /opt/flower/certs/ca.crt
      Set TLS mode for container start
    OR IF FL_TLS_ENABLED == YES and FL_SSL_CA_CERTFILE is set:
      Decode FL_SSL_CA_CERTFILE -> /opt/flower/certs/ca.crt
      Set TLS mode for container start

NEW Step 7b: TLS Certificate Validation
  IF TLS mode active:
    Validate CA cert: openssl x509 -in /opt/flower/certs/ca.crt -noout
    IF invalid: FAIL with clear error

Steps 8-9 remain unchanged.

Step 10 (start container): UPDATED
  IF TLS mode:
    Remove --insecure from Docker run
    Add -v /opt/flower/certs/ca.crt:/app/ca.crt:ro
    Add --root-certificates ca.crt

Steps 11-13 remain unchanged.
```

## Open Questions

Things that could not be fully resolved during research:

1. **OneGate attribute size limit for base64 certificates**
   - What we know: A 4096-bit RSA CA certificate PEM file is approximately 1.3-2 KB. Base64-encoded, this is approximately 1.7-2.7 KB. OneGate stores attributes in XML and has no documented size limit.
   - What's unclear: Whether there is an undocumented limit on OneGate attribute value size. The OpenNebula docs do not specify a maximum.
   - Recommendation: Test with a 4096-bit CA cert (~2 KB base64) during implementation. If size is an issue, fall back to CONTEXT-only distribution. LOW risk -- PEM certificates are small compared to typical XML payloads.

2. **OneGate cross-zone certificate retrieval**
   - What we know: Phase 7 (multi-site) requires SuperNodes in Zone B to trust a SuperLink CA in Zone A. OneGate cross-zone behavior is already flagged as unverified (see STATE.md blockers).
   - What's unclear: Whether OneGate's `/service` endpoint works across zones.
   - Recommendation: For Phase 2, scope to single-zone only. Cross-zone TLS is a Phase 7 concern. Document that cross-zone deployments must use static cert provisioning via `FL_SSL_CA_CERTFILE`.

3. **SuperNode authentication (ECDSA key-based) interaction with TLS**
   - What we know: Flower has a separate SuperNode authentication layer that sits ON TOP of TLS. It uses ECDSA key pairs, not client certificates. It requires TLS to be enabled first.
   - What's unclear: Whether Phase 2 should include SuperNode authentication or just TLS.
   - Recommendation: Phase 2 scope is TLS only (APPL-04). SuperNode authentication is a distinct security layer and could be a future phase. The APPL-04 requirement says "TLS certificate automation," not "node authentication."

4. **Certificate rotation / renewal**
   - What we know: Auto-generated certificates have a 365-day validity. The appliance is immutable (no runtime reconfiguration).
   - What's unclear: Whether there should be a mechanism for certificate rotation without full redeployment.
   - Recommendation: No rotation mechanism. Immutability model from Phase 1 applies: redeploy to renew certificates. FL training campaigns are typically hours to weeks, not years. Document the 365-day expiry as a known constraint.

5. **CA key retention on SuperLink**
   - What we know: After signing the server certificate, the CA private key (`ca.key`) is no longer needed unless additional certificates need to be signed.
   - What's unclear: Whether to delete `ca.key` after generation for security, or retain it for potential future use.
   - Recommendation: Retain `ca.key` with root-only permissions (mode 0600, owner root:root). It may be needed if the spec later adds server certificate renewal or if Phase 7 requires signing additional certs. It is NOT mounted into the Docker container.

## Sources

### Primary (HIGH confidence)
- [Flower TLS Connections Guide](https://flower.ai/docs/framework/how-to-enable-tls-connections.html) - CLI flags, certificate requirements, trust model
- [Flower Docker TLS Guide](https://flower.ai/docs/framework/docker/enable-tls.html) - Docker volume mounts, UID 49999 permissions, exact container commands
- [Flower CLI Reference](https://flower.ai/docs/framework/ref-api-cli.html) - Verified flag names: `--ssl-ca-certfile`, `--ssl-certfile`, `--ssl-keyfile`, `--root-certificates`, `--insecure`
- [Flower Dev Certificates Script](https://github.com/adap/flower/blob/main/dev/certificates/generate.sh) - OpenSSL commands, key size (4096), validity (365 days), certificate.conf structure
- [Flower Dev Certificate Config](https://github.com/adap/flower/blob/main/dev/certificates/certificate.conf) - SAN structure, distinguished name fields
- [Flower SuperNode Authentication](https://flower.ai/docs/framework/how-to-authenticate-supernodes.html) - Confirmed TLS is NOT mTLS; separate auth layer
- [OpenNebula OneGate API](https://docs.opennebula.io/7.0/product/integration_references/system_interfaces/onegate_api/) - PUT/GET endpoints, attribute publication model

### Secondary (MEDIUM confidence)
- [Flower Network Communication](https://flower.ai/docs/framework/ref-flower-network-communication.html) - Port assignments, connection model
- [Flower Docker Persist State](https://flower.ai/docs/framework/docker/persist-superlink-state.html) - UID 49999 confirmed, `/app/state` working directory
- [OpenNebula OneGate Configuration](https://docs.opennebula.io/7.0/product/operation_references/opennebula_services_configuration/onegate/) - Server configuration, no documented size limits

### Tertiary (LOW confidence)
- OneGate attribute size limits: No documentation found. Estimated safe based on typical XML payload sizes. Needs runtime validation.
- PEM certificate sizes: Based on general RSA key size calculations (4096-bit RSA CA cert ~ 1.3-2 KB PEM, ~ 1.7-2.7 KB base64). Verified against multiple web sources but not measured with Flower's specific generate.sh output.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Verified against official Flower docs and CLI reference; OpenSSL is pre-installed on Ubuntu 24.04
- Architecture: HIGH - TLS model verified against Flower's official Docker TLS guide; certificate generation adapted from Flower's own dev script
- Pitfalls: HIGH - Based on official docs warnings (UID 49999 permissions, SAN requirements) and standard TLS deployment experience
- OneGate distribution: MEDIUM - OneGate API is well-documented but attribute size limits are undocumented; PEM certs are small enough that this is LOW risk
- Certificate generation: HIGH - OpenSSL commands verified against Flower's generate.sh and standard OpenSSL documentation

**Research date:** 2026-02-07
**Valid until:** 2026-05-07 (90 days -- Flower TLS interface is stable; OpenSSL and OneGate APIs are stable)
