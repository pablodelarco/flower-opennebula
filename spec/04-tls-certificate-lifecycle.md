# TLS Certificate Lifecycle

**Requirement:** APPL-04
**Phase:** 02 - Security and Certificate Automation
**Status:** Specification

---

## 1. TLS Security Overview

This section specifies how the Flower SuperLink appliance transitions from Phase 1's `--insecure` mode to TLS-encrypted gRPC communication. TLS protects model weights and gradients in transit between SuperLink and SuperNodes.

**TLS model:** Flower uses **server-side TLS** (NOT mutual TLS / mTLS). The SuperLink presents a TLS server certificate to prove its identity. SuperNodes verify the SuperLink's identity using the CA certificate. SuperNodes do NOT present client certificates -- Flower does not use mTLS at the transport layer.

**Flower SuperNode authentication:** Flower has a separate, optional authentication layer for SuperNodes based on ECDSA key pairs (`--enable-supernode-auth`). This sits ON TOP of TLS and is a distinct security mechanism. SuperNode authentication is out of scope for APPL-04. TLS must be enabled before SuperNode authentication can be used.

**Master switch:** `FL_TLS_ENABLED=YES` activates TLS mode. When set to `NO` (the default), Phase 1 `--insecure` behavior applies and all TLS-related processing is skipped.

**Certificate artifacts:**

| Artifact | SuperLink | SuperNode | Purpose |
|----------|-----------|-----------|---------|
| CA certificate (`ca.crt`) | Yes | Yes | Trust anchor. SuperNodes use this to verify the SuperLink's server certificate. |
| Server certificate (`server.pem`) | Yes | No | Presented by SuperLink during TLS handshake. Contains VM IP as SAN. |
| Server private key (`server.key`) | Yes | No | Signs TLS handshake on SuperLink side. Never leaves SuperLink VM. |
| CA private key (`ca.key`) | Yes (retained) | No | Used to sign the server certificate at generation time. Retained with root-only permissions. |

**Trust chain:**

```
Self-signed CA (generated at SuperLink boot)
    |
    +-- signs --> Server Certificate (CN=${VM_IP}, SAN includes VM IP)
    |
    +-- distributed to --> SuperNode (via OneGate FL_CA_CERT or CONTEXT FL_SSL_CA_CERTFILE)
                           Used as --root-certificates to verify SuperLink identity
```

**Protocol:** Flower's `--ssl-*` CLI flags use legacy "SSL" naming, but the actual protocol is TLS 1.2+ as negotiated by gRPC's underlying transport layer.

---

## 2. Certificate File Layout

### Host Paths (SuperLink VM)

```
/opt/flower/certs/                  # Directory: 49999:49999, mode 0700
    ca.key                          # CA private key (root:root, 0600)
    ca.crt                          # CA certificate (49999:49999, 0644)
    server.pem                      # Server certificate signed by CA (49999:49999, 0644)
    server.key                      # Server private key (49999:49999, 0600)
```

### File Permissions Detail

| File | Owner | Mode | Rationale |
|------|-------|------|-----------|
| `/opt/flower/certs/` | 49999:49999 | 0700 | Directory created in Phase 1. Only the Flower UID and root can list contents. |
| `ca.key` | root:root | 0600 | CA private key. NOT owned by 49999. NOT mounted into container. Root-only access prevents container escape from reading it. |
| `ca.crt` | 49999:49999 | 0644 | CA certificate is public information. Readable by container process and published to OneGate. |
| `server.pem` | 49999:49999 | 0644 | Server certificate is presented during TLS handshake (public). Readable by container. |
| `server.key` | 49999:49999 | 0600 | Server private key. Owner-only read. Container runs as UID 49999 and needs to read this for TLS. |

### Container Mount (SuperLink)

The certificate directory is mounted read-only into the SuperLink container:

```
-v /opt/flower/certs:/app/certificates:ro
```

**Container-internal paths:**

| Container Path | Host Path | Purpose |
|---------------|-----------|---------|
| `/app/certificates/ca.crt` | `/opt/flower/certs/ca.crt` | CA certificate for `--ssl-ca-certfile` |
| `/app/certificates/server.pem` | `/opt/flower/certs/server.pem` | Server certificate for `--ssl-certfile` |
| `/app/certificates/server.key` | `/opt/flower/certs/server.key` | Server private key for `--ssl-keyfile` |

**Excluded from mount:** `ca.key` is inside the mounted directory on the host but is owned by `root:root` with mode `0600`. The container process (UID 49999) cannot read it. This provides defense-in-depth -- even with the directory mount, the CA private key is inaccessible to the container.

---

## 3. Certificate Generation Sequence

When `FL_TLS_ENABLED=YES` and no operator-provided certificates are detected (auto-generation path), the SuperLink generates a self-signed CA and server certificate during boot.

### Generation Parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Key algorithm | RSA | Broad compatibility with gRPC TLS implementations. |
| Key size | 4096-bit | Standard strength for CA and server keys. |
| Hash algorithm | SHA-256 | Standard for certificate signing. |
| Validity period | 365 days | Sufficient for FL campaigns (hours to weeks). Redeploy to renew. |
| CA subject | `/O=Flower FL/CN=Flower CA` | Identifies the issuer as Flower-specific. |
| Server CN | `${VM_IP}` | Dynamic: detected at boot via `hostname -I`. |
| SAN entries | DNS.1=localhost, IP.1=127.0.0.1, IP.2=::1, IP.3=${VM_IP} | Covers local testing and production access via VM IP. |

### Step-by-Step Sequence

The certificate generation script (`/opt/flower/scripts/generate-certs.sh`) SHALL execute the following 8 steps:

**Step 1: Generate CA private key (RSA 4096-bit)**

```bash
openssl genrsa -out "${CERT_DIR}/ca.key" 4096 2>/dev/null
```

**Step 2: Generate self-signed CA certificate (365-day validity)**

```bash
openssl req -new -x509 \
    -key "${CERT_DIR}/ca.key" \
    -sha256 \
    -subj "/O=Flower FL/CN=Flower CA" \
    -days 365 \
    -out "${CERT_DIR}/ca.crt" 2>/dev/null
```

**Step 3: Generate server private key (RSA 4096-bit)**

```bash
openssl genrsa -out "${CERT_DIR}/server.key" 4096 2>/dev/null
```

**Step 4: Generate server CSR with dynamic SAN**

The VM IP is detected at runtime using `hostname -I | awk '{print $1}'` and injected into the SAN configuration via bash process substitution:

```bash
VM_IP=$(hostname -I | awk '{print $1}')

openssl req -new \
    -key "${CERT_DIR}/server.key" \
    -out "${CERT_DIR}/server.csr" \
    -config <(cat <<EOF
[req]
default_bits = 4096
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
```

**Step 5: Sign server certificate with CA (365 days, SHA-256)**

```bash
openssl x509 -req \
    -in "${CERT_DIR}/server.csr" \
    -CA "${CERT_DIR}/ca.crt" \
    -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial \
    -out "${CERT_DIR}/server.pem" \
    -days 365 \
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
```

**Step 6: Clean up temporary files**

```bash
rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/ca.srl"
```

The CSR and serial file are intermediate artifacts not needed at runtime.

**Step 7: Set ownership and permissions**

```bash
# CA key: root-only, NOT accessible by container
chown root:root "${CERT_DIR}/ca.key"
chmod 0600 "${CERT_DIR}/ca.key"

# Files accessible by container (UID 49999)
chown 49999:49999 "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.pem" "${CERT_DIR}/server.key"
chmod 0644 "${CERT_DIR}/ca.crt"
chmod 0644 "${CERT_DIR}/server.pem"
chmod 0600 "${CERT_DIR}/server.key"
```

**Step 8: Verify certificate chain**

```bash
if openssl verify -CAfile "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.pem" >/dev/null 2>&1; then
    log "INFO" "Certificate chain verified successfully"
else
    log "ERROR" "Certificate chain verification FAILED"
    exit 1
fi
```

Chain verification ensures the server certificate was correctly signed by the CA. Failure at this step is fatal -- the boot sequence aborts.

### SAN Configuration

The Subject Alternative Name (SAN) extension is critical for TLS verification. gRPC clients verify the server certificate's SAN against the address they connect to. A SAN mismatch causes "certificate verify failed" errors.

| SAN Entry | Value | Purpose |
|-----------|-------|---------|
| DNS.1 | `localhost` | Allows local testing from within the SuperLink VM. |
| IP.1 | `127.0.0.1` | Loopback IPv4 for local access. |
| IP.2 | `::1` | Loopback IPv6 for local access. |
| IP.3 | `${VM_IP}` | The VM's primary network IP. This is what SuperNodes connect to. |

The VM IP is detected dynamically at boot using `hostname -I | awk '{print $1}'`, which returns the primary IP address assigned by OpenNebula contextualization.

### Certificate Validity and Renewal

Certificates are valid for 365 days from generation. There is no rotation mechanism -- the appliance follows the immutable model established in Phase 1.

**Known constraint:** After 365 days, certificates expire and SuperNode connections fail with "certificate has expired" errors. This is acceptable because:
- FL training campaigns typically run for hours to weeks, not years.
- Redeployment (terminate VM, deploy new one) generates fresh certificates.
- Operators with longer-lived deployments can provide their own certificates via `FL_SSL_*` CONTEXT variables with appropriate validity periods.

### CA Key Retention

The CA private key (`ca.key`) is retained on the SuperLink VM after certificate generation, with `root:root` ownership and `0600` permissions. It is NOT mounted into the Docker container.

**Rationale for retention:** The CA key may be needed in future phases:
- Phase 7 (multi-site federation) may require signing additional server certificates for cross-zone SuperLinks.
- Any future certificate renewal capability would need the CA key to sign new server certificates.

**Security posture:** The CA key is protected by:
1. `root:root` ownership -- only root can read it.
2. `0600` permissions -- no group or world access.
3. NOT mounted into the Docker container -- container compromise does not expose the CA key.
4. Never published to OneGate or any external service.

---

## 4. Dual Provisioning Model

The SuperLink supports two paths for obtaining TLS certificates: auto-generation (default) and operator-provided (manual). The decision logic determines which path to follow.

### Decision Flowchart

```
FL_TLS_ENABLED?
    |
    +-- NO (default) --> Skip TLS entirely. Use --insecure (Phase 1 behavior).
    |
    +-- YES --> FL_SSL_CA_CERTFILE set?
                    |
                    +-- YES --> Operator-provided path:
                    |             Decode FL_SSL_CA_CERTFILE -> ca.crt
                    |             Decode FL_SSL_CERTFILE   -> server.pem
                    |             Decode FL_SSL_KEYFILE    -> server.key
                    |             Validate chain
                    |             Set ownership/permissions
                    |
                    +-- NO  --> Auto-generation path:
                                  Run generate-certs.sh
                                  (Steps 1-8 from Section 3)
```

### Auto-Generation Path (Default)

**Trigger:** `FL_TLS_ENABLED=YES` AND `FL_SSL_CA_CERTFILE` is empty/unset.

**Behavior:** Execute the full certificate generation sequence (Section 3). This is the zero-config TLS path -- the operator enables TLS with a single boolean and the appliance handles everything.

**Post-generation:** The CA certificate is published to OneGate (Section 7) so SuperNodes can retrieve it automatically.

### Operator-Provided Path

**Trigger:** `FL_TLS_ENABLED=YES` AND `FL_SSL_CA_CERTFILE` is set (non-empty).

**Prerequisite:** When `FL_SSL_CA_CERTFILE` is set on the SuperLink, `FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` MUST also be set. All three are required together (all-or-none rule). Missing any one of the three is a fatal validation error.

**Decode function specification:**

```bash
decode_context_certs() {
    local cert_dir="/opt/flower/certs"

    # Decode CA certificate
    echo "${FL_SSL_CA_CERTFILE}" | base64 -d > "${cert_dir}/ca.crt"
    log "INFO" "CA certificate decoded from FL_SSL_CA_CERTFILE"

    # Decode server certificate
    echo "${FL_SSL_CERTFILE}" | base64 -d > "${cert_dir}/server.pem"
    log "INFO" "Server certificate decoded from FL_SSL_CERTFILE"

    # Decode server private key
    echo "${FL_SSL_KEYFILE}" | base64 -d > "${cert_dir}/server.key"
    log "INFO" "Server private key decoded from FL_SSL_KEYFILE"

    # Set ownership and permissions
    chown 49999:49999 "${cert_dir}/ca.crt" "${cert_dir}/server.pem" "${cert_dir}/server.key"
    chmod 0644 "${cert_dir}/ca.crt"
    chmod 0644 "${cert_dir}/server.pem"
    chmod 0600 "${cert_dir}/server.key"
}
```

**Post-decode validation:**

```bash
# Verify each file is valid PEM
openssl x509 -in "${cert_dir}/ca.crt" -noout 2>/dev/null || {
    log "ERROR" "FL_SSL_CA_CERTFILE does not contain a valid PEM certificate"
    exit 1
}
openssl x509 -in "${cert_dir}/server.pem" -noout 2>/dev/null || {
    log "ERROR" "FL_SSL_CERTFILE does not contain a valid PEM certificate"
    exit 1
}
openssl rsa -in "${cert_dir}/server.key" -check -noout 2>/dev/null || {
    log "ERROR" "FL_SSL_KEYFILE does not contain a valid PEM private key"
    exit 1
}

# Verify chain: server cert was signed by the provided CA
openssl verify -CAfile "${cert_dir}/ca.crt" "${cert_dir}/server.pem" >/dev/null 2>&1 || {
    log "ERROR" "Server certificate is not signed by the provided CA certificate"
    exit 1
}
```

**Use cases for operator-provided certificates:**
- Organizations with existing PKI infrastructure.
- Certificates with longer validity periods (multi-year).
- Certificates signed by a trusted CA (not self-signed).
- Compliance requirements mandating specific certificate authorities.

**Note on CA key:** When using operator-provided certificates, no `ca.key` is present on the SuperLink VM. The CA key is managed externally by the operator's PKI.

---

## 5. SuperLink Boot Sequence Modification

This section describes changes to the Phase 1 boot sequence (defined in `spec/01-superlink-appliance.md`, Section 6). Changes are presented as a delta -- Phase 1 steps that are not mentioned here remain unchanged.

### NEW Step 7a: TLS Certificate Setup

Inserted between existing Step 7 (Create mount directories with correct ownership) and Step 8 (Generate systemd unit file).

```
Step 7a: TLS Certificate Setup

IF FL_TLS_ENABLED != YES:
    LOG "TLS disabled (FL_TLS_ENABLED=${FL_TLS_ENABLED:-NO}). Using --insecure mode."
    SKIP to Step 8 (no TLS processing)

IF FL_SSL_CA_CERTFILE is set AND non-empty:
    # Operator-provided certificates
    Validate all three FL_SSL_* variables are set (all-or-none rule)
    Decode FL_SSL_CA_CERTFILE -> /opt/flower/certs/ca.crt
    Decode FL_SSL_CERTFILE   -> /opt/flower/certs/server.pem
    Decode FL_SSL_KEYFILE    -> /opt/flower/certs/server.key
    Validate PEM format of all three files
    Verify chain: openssl verify -CAfile ca.crt server.pem
    Set ownership: chown 49999:49999 ca.crt server.pem server.key
    Set permissions: chmod per Section 2 table
    LOG "Operator-provided certificates decoded and validated"
ELSE:
    # Auto-generation
    Detect VM IP: hostname -I | awk '{print $1}'
    IF VM_IP is empty: FATAL "Cannot detect VM IP for certificate SAN"
    Run certificate generation sequence (Section 3, Steps 1-8)
    LOG "Auto-generated certificates with SAN for ${VM_IP}"

Set TLS_MODE=enabled (flag for Steps 8 and 12)
```

**Failure behavior:** Any failure in Step 7a (decode error, PEM validation failure, chain verification failure, OpenSSL error, missing VM IP) is FATAL. The boot sequence aborts. The VM publishes `FL_READY=NO` with `FL_ERROR=tls_setup_failed` to OneGate (if reachable) and does not report ready.

### UPDATED Step 8: Generate Systemd Unit File

The systemd unit and Docker run command are conditionally modified based on `TLS_MODE`:

```
Step 8 (UPDATED): Generate Systemd Unit File

IF TLS_MODE == enabled:
    Docker run command:
      - REMOVE: --insecure
      - ADD: -v /opt/flower/certs:/app/certificates:ro
      - ADD: --ssl-ca-certfile certificates/ca.crt
      - ADD: --ssl-certfile certificates/server.pem
      - ADD: --ssl-keyfile certificates/server.key
ELSE:
    Docker run command: unchanged from Phase 1 (includes --insecure)

Write systemd unit file with the constructed Docker run command.
Run systemctl daemon-reload.
```

### UPDATED Step 12: Publish Readiness to OneGate

The OneGate publication is extended with TLS-related attributes:

```
Step 12 (UPDATED): Publish Readiness to OneGate

Existing attributes (unchanged):
    FL_READY=YES
    FL_ENDPOINT={vm_ip}:9092
    FL_VERSION={flower_version}
    FL_ROLE=superlink

NEW attributes (added when TLS_MODE == enabled):
    FL_TLS=YES
    FL_CA_CERT={base64-encoded CA certificate}

IF TLS_MODE != enabled:
    FL_TLS=NO
    (FL_CA_CERT is NOT published)
```

### Updated Boot Sequence Diagram

```
OS Boot --> Contextualization --> configure.sh --> bootstrap.sh --> READY
  [1]           [2]              [3,4,5,6,7]       [9,10,11,12]
                                      |
                                  [7a: TLS]  <-- NEW
                                      |
                                     [8]     <-- UPDATED
```

---

## 6. SuperLink Docker Run Command (TLS Mode)

### Phase 1 Command (Insecure Mode -- Reference)

```bash
docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --isolation subprocess \
  --fleet-api-address 0.0.0.0:9092 \
  --database state/state.db
```

### Phase 2 Command (TLS Mode)

```bash
docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
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

### Differences Summary

| Aspect | Phase 1 (Insecure) | Phase 2 (TLS) |
|--------|-------------------|---------------|
| TLS flag | `--insecure` | (removed) |
| CA cert | -- | `--ssl-ca-certfile certificates/ca.crt` |
| Server cert | -- | `--ssl-certfile certificates/server.pem` |
| Server key | -- | `--ssl-keyfile certificates/server.key` |
| Cert volume | -- | `-v /opt/flower/certs:/app/certificates:ro` |
| Port mappings | Same | Same (gRPC+TLS uses the same ports) |

**Note on Flower `--ssl-*` flag naming:** The flags use "ssl" prefix for historical reasons. The actual protocol negotiated is TLS 1.2+ -- Flower's gRPC transport does not use SSL 3.0 or earlier.

**Note on certificate paths:** The `--ssl-*` flags accept paths relative to the container's working directory (`/app/`). The value `certificates/ca.crt` resolves to `/app/certificates/ca.crt` inside the container.

### Systemd Unit File (TLS Mode)

```ini
[Unit]
Description=Flower SuperLink (Federated Learning Coordinator)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

ExecStartPre=-/usr/bin/docker rm -f flower-superlink
ExecStart=/usr/bin/docker run \
  --name flower-superlink \
  --rm \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  -v /opt/flower/certs:/app/certificates:ro \
  flwr/superlink:${FLOWER_VERSION} \
  --ssl-ca-certfile certificates/ca.crt \
  --ssl-certfile certificates/server.pem \
  --ssl-keyfile certificates/server.key \
  --isolation subprocess \
  --fleet-api-address ${FL_FLEET_API_ADDRESS} \
  --database ${FL_DATABASE}
ExecStop=/usr/bin/docker stop flower-superlink

[Install]
WantedBy=multi-user.target
```

---

## 7. OneGate Publication Extension

When TLS is enabled, the SuperLink extends its existing OneGate publication (defined in `spec/01-superlink-appliance.md`, Section 10) with two new attributes.

### New Attributes

| Attribute | Value | Type | Purpose |
|-----------|-------|------|---------|
| `FL_TLS` | `YES` or `NO` | string | Whether the SuperLink is running with TLS enabled. SuperNodes use this to determine their connection mode. |
| `FL_CA_CERT` | Base64-encoded PEM CA certificate | string | The CA certificate that SuperNodes need to verify the SuperLink's server certificate. Encoded with `base64 -w0` for single-line output. |

### Updated Publication Command

```bash
MY_IP=$(hostname -I | awk '{print $1}')
ONEGATE_TOKEN=$(cat /run/one-context/token.txt)
VMID=$(grep -oP 'VMID=\K[0-9]+' /run/one-context/one_env)

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

When TLS is NOT enabled, the publication omits `FL_CA_CERT` and sets `FL_TLS=NO`:

```bash
curl -s -X PUT "${ONEGATE_ENDPOINT}/vm" \
  -H "X-ONEGATE-TOKEN: ${ONEGATE_TOKEN}" \
  -H "X-ONEGATE-VMID: ${VMID}" \
  -d "FL_READY=YES" \
  -d "FL_ENDPOINT=${MY_IP}:9092" \
  -d "FL_VERSION=${FLOWER_VERSION}" \
  -d "FL_ROLE=superlink" \
  -d "FL_TLS=NO"
```

### Complete Published Attributes Table (TLS Mode)

| Attribute | Value | Source | Defined In |
|-----------|-------|--------|------------|
| `FL_READY` | `YES` | Health check passed | Phase 1, Section 10 |
| `FL_ENDPOINT` | `{vm_ip}:9092` | VM IP detection | Phase 1, Section 10 |
| `FL_VERSION` | `1.25.0` (or override) | FLOWER_VERSION variable | Phase 1, Section 10 |
| `FL_ROLE` | `superlink` | Fixed | Phase 1, Section 10 |
| `FL_TLS` | `YES` | FL_TLS_ENABLED check | **This section** |
| `FL_CA_CERT` | base64 CA cert | `/opt/flower/certs/ca.crt` | **This section** |

### Security: What Is and Is NOT Published

**PUBLISHED to OneGate:**
- `ca.crt` (CA certificate) -- This is public information. It is the trust anchor that SuperNodes need.

**NEVER published to OneGate:**
- `ca.key` (CA private key) -- Publishing this would allow anyone to forge server certificates.
- `server.key` (server private key) -- Publishing this would allow anyone to impersonate the SuperLink.
- `server.pem` (server certificate) -- Not needed by SuperNodes; they receive it during the TLS handshake.

**Anti-pattern warning:** The publication script MUST explicitly name only `ca.crt` for encoding. Do NOT use glob patterns (e.g., `cat /opt/flower/certs/*`) or iterate over all files in the certificate directory. Accidental publication of private key material is a critical security vulnerability.

### Base64 Encoding Rationale

The CA certificate PEM file is base64-encoded before OneGate publication (`base64 -w0`):

- **`-w0`:** Produces a single line with no line wraps. OneGate attributes are key-value pairs; multi-line values would break the format.
- **Why encode:** PEM files contain `-----BEGIN CERTIFICATE-----` / `-----END CERTIFICATE-----` delimiters and base64-encoded DER data with line breaks. Transmitting raw PEM through OneGate's URL-encoded form data and XML storage can corrupt line breaks. Double base64 encoding (PEM's internal base64 wrapped in transport base64) ensures structure preservation.
- **Approximate size:** A 4096-bit RSA CA certificate is approximately 1.3-2 KB as PEM, approximately 1.7-2.7 KB after base64 encoding. Well within typical XML attribute limits.

### Publication Failure Handling

OneGate publication of `FL_TLS` and `FL_CA_CERT` follows the same best-effort model as Phase 1:
- If OneGate is unreachable, log a warning and continue.
- The SuperLink still functions with TLS -- only automatic CA certificate distribution is affected.
- SuperNodes that cannot retrieve `FL_CA_CERT` from OneGate must use the `FL_SSL_CA_CERTFILE` CONTEXT variable (static provisioning).

---

## 8. New Contextualization Variables (SuperLink)

Phase 1 defined these variables as placeholders (see `spec/03-contextualization-reference.md`, Section 6). This section fully specifies them.

### Variable Definitions

| # | Context Variable | Type | Default | Appliance | Validation Rule | Purpose |
|---|------------------|------|---------|-----------|-----------------|---------|
| 1 | `FL_TLS_ENABLED` | `O\|boolean` | `NO` | Both (SuperLink + SuperNode) | Must be `YES` or `NO` (case-insensitive) | Master switch for TLS mode. `YES` enables certificate processing and TLS Docker flags. `NO` preserves Phase 1 `--insecure` behavior. |
| 2 | `FL_SSL_CA_CERTFILE` | `O\|text64` | (empty) | Both (SuperLink + SuperNode) | If set: must decode (`base64 -d`) to valid PEM (`openssl x509 -in - -noout`) | Base64-encoded PEM CA certificate. On SuperLink: triggers operator-provided path and skips auto-generation. On SuperNode: used as `--root-certificates` (bypasses OneGate retrieval). |
| 3 | `FL_SSL_CERTFILE` | `O\|text64` | (empty) | SuperLink only | If set: must decode to valid PEM certificate. Required when `FL_SSL_CA_CERTFILE` is set on SuperLink. | Base64-encoded PEM server certificate. Decoded to `/opt/flower/certs/server.pem`. |
| 4 | `FL_SSL_KEYFILE` | `O\|text64` | (empty) | SuperLink only | If set: must decode to valid PEM private key. Required when `FL_SSL_CA_CERTFILE` is set on SuperLink. | Base64-encoded PEM server private key. Decoded to `/opt/flower/certs/server.key`. |

### USER_INPUT Definitions

```
# Phase 2: TLS Security
FL_TLS_ENABLED = "O|boolean|Enable TLS encryption||NO"
FL_SSL_CA_CERTFILE = "O|text64|CA certificate (base64 PEM)"
FL_SSL_CERTFILE = "O|text64|Server certificate (base64 PEM)"
FL_SSL_KEYFILE = "O|text64|Server private key (base64 PEM)"
```

### Validation Rules

| Variable | Rule | Error on Violation |
|----------|------|--------------------|
| `FL_TLS_ENABLED` | Must be `YES` or `NO` (case-insensitive). Any other value is rejected. | `"Invalid FL_TLS_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_SSL_CA_CERTFILE` | If set: must successfully decode via `base64 -d` and pass `openssl x509 -in - -noout`. | `"FL_SSL_CA_CERTFILE does not contain a valid base64-encoded PEM certificate."` |
| `FL_SSL_CERTFILE` | Required if `FL_SSL_CA_CERTFILE` is set on SuperLink. Must decode to valid PEM. | `"FL_SSL_CERTFILE is required when FL_SSL_CA_CERTFILE is provided."` |
| `FL_SSL_KEYFILE` | Required if `FL_SSL_CA_CERTFILE` is set on SuperLink. Must decode to valid PEM key. | `"FL_SSL_KEYFILE is required when FL_SSL_CA_CERTFILE is provided."` |

### All-or-None Rule (SuperLink)

On the SuperLink, the three `FL_SSL_*` variables follow an all-or-none rule:

- If `FL_SSL_CA_CERTFILE` is set, then `FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` MUST also be set.
- If `FL_SSL_CA_CERTFILE` is NOT set, then `FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` are ignored (even if provided).
- Setting only `FL_SSL_CERTFILE` or `FL_SSL_KEYFILE` without `FL_SSL_CA_CERTFILE` has no effect.

**Rationale:** The CA certificate is the decision variable. If the operator provides a CA, they must provide the complete certificate chain. If they do not provide a CA, auto-generation creates all three files.

### Consistency Rules

| Rule | Scope | Enforcement |
|------|-------|-------------|
| If `FL_TLS_ENABLED=YES` on SuperLink, ALL SuperNodes MUST have TLS enabled. | Cross-appliance | Not enforced at boot. Mismatch causes gRPC connection failures at runtime. In OneFlow templates, set `FL_TLS_ENABLED` at the service level. |
| If `FL_TLS_ENABLED=NO` on SuperLink, SuperNodes MUST use `--insecure`. | Cross-appliance | Same enforcement as above. |
| SuperNodes using OneGate discovery auto-detect TLS mode from the `FL_TLS` attribute published by SuperLink. | OneGate deployments | Specified in Plan 02-02 (SuperNode TLS trust). |
| SuperNodes using static discovery (`FL_SUPERLINK_ADDRESS`) MUST have `FL_TLS_ENABLED` and `FL_SSL_CA_CERTFILE` set explicitly. | Static deployments | No OneGate to retrieve CA cert from. Operator must provide both. |

---

## 9. Failure Modes

### Failure Classification Table

| # | Failure | Trigger | Severity | Boot Continues? | OneGate Publication | Recovery Action |
|---|---------|---------|----------|-----------------|--------------------|--------------------|
| 1 | Certificate generation failure | `openssl genrsa` or `openssl req` returns non-zero | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | Check `/var/log/one-appliance/flower-configure.log`. Possible causes: disk full, OpenSSL not installed (should not happen on Ubuntu 24.04). |
| 2 | Chain verification failure | `openssl verify -CAfile ca.crt server.pem` fails | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | Indicates a bug in the generation script or corrupted files. Redeploy. |
| 3 | Operator cert decode failure | `base64 -d` fails on `FL_SSL_CA_CERTFILE`, `FL_SSL_CERTFILE`, or `FL_SSL_KEYFILE` | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | Verify that CONTEXT variables contain valid base64-encoded PEM data. Check encoding: `cat cert.pem \| base64 -w0`. |
| 4 | Operator cert PEM validation failure | `openssl x509 -in - -noout` or `openssl rsa -check -noout` fails on decoded file | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | Decoded content is not valid PEM. Verify source certificate files. |
| 5 | Operator cert chain mismatch | `openssl verify` fails: server cert not signed by provided CA | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | Server certificate must be signed by the provided CA. Verify cert chain with `openssl verify -CAfile ca.crt server.pem`. |
| 6 | Missing FL_SSL_CERTFILE or FL_SSL_KEYFILE | `FL_SSL_CA_CERTFILE` is set but one of the other two is missing | Fatal | No | `FL_READY=NO`, `FL_ERROR=config_validation_failed` | All three `FL_SSL_*` variables must be provided together on SuperLink (all-or-none rule). |
| 7 | VM IP detection failure | `hostname -I` returns empty | Fatal | No | `FL_READY=NO`, `FL_ERROR=tls_setup_failed` | VM has no network interface configured. Check contextualization network setup (`NETWORK=YES`). |
| 8 | OneGate FL_CA_CERT publication failure | OneGate PUT fails for TLS attributes | Non-blocking | Yes | Partial (FL_READY published without FL_CA_CERT) | Warning logged. SuperLink functions with TLS. SuperNodes must use `FL_SSL_CA_CERTFILE` for static CA provisioning. |
| 9 | Certificate expiry (365 days) | Runtime: SuperNode connects after cert expires | Runtime | n/a | n/a | Redeploy the SuperLink to generate fresh certificates. Or provide longer-lived certs via `FL_SSL_*` variables. |

### Error Reporting

All TLS-related errors follow the Phase 1 error reporting pattern:

```
[YYYY-MM-DD HH:MM:SS] [ERROR] [flower-configure] TLS certificate generation failed: openssl genrsa returned exit code 1
[YYYY-MM-DD HH:MM:SS] [ERROR] [flower-configure] Boot sequence aborted at Step 7a (TLS Certificate Setup)
```

Errors are written to:
- `/var/log/one-appliance/flower-configure.log` (primary)
- System journal (`journalctl`)

---

## 10. Security Considerations

### Private Key Protection

| Principle | Implementation |
|-----------|---------------|
| Private keys MUST never leave the SuperLink VM | `ca.key` and `server.key` exist only on the SuperLink filesystem. They are never published to OneGate, written to logs, or transmitted over the network. |
| `ca.key` is NOT mounted into the Docker container | The container volume mount (`-v /opt/flower/certs:/app/certificates:ro`) includes the directory, but `ca.key` has `root:root 0600` permissions, making it unreadable by the container process (UID 49999). |
| `server.key` is mounted read-only | The volume mount uses `:ro`. The container can read `server.key` (required for TLS) but cannot modify it. File permissions (`0600`) restrict access to the owner (UID 49999). |
| OneGate publication explicitly names only `ca.crt` | The publication script uses `base64 -w0 /opt/flower/certs/ca.crt` -- an explicit file path, not a glob pattern. No other file from the certificate directory is published. |

### Self-Signed CA Appropriateness

Self-signed CA certificates are appropriate for marketplace appliances because:

1. **No external CA infrastructure required.** The appliance is self-contained and works in any OpenNebula environment without depending on external PKI.
2. **Trust scope is limited.** The CA is trusted only by SuperNodes in the same deployment. It is not added to any system trust store.
3. **Operator override available.** Organizations with PKI infrastructure use the `FL_SSL_*` CONTEXT variables to provide certificates signed by their own CA.
4. **Training campaigns are short-lived.** Most FL campaigns run for hours to weeks. The 365-day certificate validity covers this with large margin.

### Base64 Transport Security

Base64 encoding of PEM certificates for OneGate transport preserves the PEM structure through:
- OneGate's URL-encoded form data (PUT request body).
- OpenNebula's internal XML storage for VM USER_TEMPLATE attributes.
- OneGate's JSON response format (GET response).

Without base64 encoding, PEM line breaks and special characters (`+`, `/`, `=`) can be corrupted during transport. The double encoding (PEM contains base64; the whole PEM is then base64-encoded for transport) is intentional and necessary.

### TLS Mode Consistency

Both sides of the Flower connection MUST agree on TLS mode:
- SuperLink with TLS + SuperNode with `--insecure` = connection failure.
- SuperLink with `--insecure` + SuperNode with `--root-certificates` = connection failure.

In OneFlow service templates, `FL_TLS_ENABLED` SHOULD be set at the service level (applied to all roles) to prevent mismatch. SuperNodes using OneGate discovery can auto-detect TLS mode from the `FL_TLS` attribute, providing an additional safety mechanism.

---

## Appendix A: Relationship to Other Spec Sections

| Spec Section | Relationship | Key Dependencies |
|-------------|-------------|------------------|
| `spec/01-superlink-appliance.md` | This section modifies the SuperLink boot sequence (Step 7a insertion), Docker run command (TLS flags replace `--insecure`), systemd unit (TLS volume mount), and OneGate publication (FL_TLS, FL_CA_CERT). | Phase 1 Steps 7, 8, 12 are updated. The 12-step sequence becomes effectively 13 steps with 7a. |
| `spec/02-supernode-appliance.md` | SuperNode retrieves `FL_CA_CERT` from OneGate during discovery (Step 7) and uses it as `--root-certificates`. Full SuperNode TLS specification is in Plan 02-02. | SuperNode depends on FL_TLS and FL_CA_CERT attributes from Section 7 of this document. |
| `spec/03-contextualization-reference.md` | Four Phase 2 placeholder variables (`FL_TLS_ENABLED`, `FL_SSL_CA_CERTFILE`, `FL_SSL_CERTFILE`, `FL_SSL_KEYFILE`) are fully specified here. Section 6 of the context reference becomes active. | Variable definitions in this document take precedence per the source-of-truth hierarchy in the context reference (Section 1). |
| Phase 4 (OneFlow Orchestration) | OneFlow service templates SHOULD set `FL_TLS_ENABLED` at the service level for consistency across roles. | Depends on FL_TLS_ENABLED variable definition from Section 8. |
| Phase 7 (Multi-Site Federation) | Cross-zone TLS requires CA certificate distribution beyond OneGate (which may not work cross-zone). Static cert provisioning via `FL_SSL_CA_CERTFILE` is the cross-zone path. CA key retention (Section 3) may enable signing additional server certificates. | Depends on dual provisioning model (Section 4) and CA key retention decision. |

---

*Specification for APPL-04: TLS Certificate Lifecycle*
*Phase: 02 - Security and Certificate Automation*
*Version: 1.0*
