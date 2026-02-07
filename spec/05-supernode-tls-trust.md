# SuperNode TLS Trust and End-to-End Handshake

**Requirement:** APPL-04 (SuperNode side)
**Phase:** 02 - Security and Certificate Automation
**Status:** Specification

---

## 1. SuperNode TLS Trust Model

This section specifies how the Flower SuperNode appliance establishes trust with the SuperLink's TLS-secured gRPC server. Combined with `spec/04-tls-certificate-lifecycle.md` (the SuperLink side), this completes the APPL-04 TLS certificate automation requirement.

**SuperNode's role in TLS:** The SuperNode is the gRPC **client** in a server-side TLS connection. It verifies the SuperLink's identity using the CA certificate but does NOT present a client certificate. Flower uses server-side TLS, not mutual TLS (mTLS). The SuperNode's only job is to confirm that the SuperLink's server certificate was signed by a trusted CA.

**Single file needed:** `/opt/flower/certs/ca.crt` -- the CA certificate that signed the SuperLink's server certificate. This is the only TLS artifact on the SuperNode. There are no private keys, no server certificates, no CSRs.

**Two acquisition paths:**

| Path | Mode | Trigger | Source |
|------|------|---------|--------|
| OneGate retrieval | Automatic (default) | SuperNode discovers `FL_TLS=YES` during OneGate service query | `FL_CA_CERT` attribute on SuperLink VM in OneGate |
| CONTEXT variable | Manual (static) | `FL_TLS_ENABLED=YES` and `FL_SSL_CA_CERTFILE` set in VM CONTEXT | Operator provides base64-encoded PEM CA certificate |

**Priority:** If `FL_SSL_CA_CERTFILE` is set in CONTEXT, it takes precedence over OneGate retrieval. This allows operators to override the auto-distributed CA with their own certificate even in OneFlow deployments.

**Reference:** The SuperLink generates and publishes the CA certificate as specified in `spec/04-tls-certificate-lifecycle.md`, Sections 3 (generation), 4 (dual provisioning), and 7 (OneGate publication). The SuperNode consumes what the SuperLink publishes.

---

## 2. CA Certificate Retrieval from OneGate

During the existing discovery phase (Step 7 of the SuperNode boot sequence, defined in `spec/02-supernode-appliance.md`, Section 6c), the SuperNode queries OneGate to find the SuperLink's Fleet API address. In Phase 2, this same query is extended to also check for TLS attributes.

### Extended Discovery Query

The OneGate service query response contains the SuperLink VM's USER_TEMPLATE, which includes the TLS attributes published by the SuperLink (see `spec/04-tls-certificate-lifecycle.md`, Section 7).

**jq extraction for TLS flag:**

```bash
FL_TLS_FLAG=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_TLS // empty
')
```

**jq extraction for CA certificate:**

```bash
FL_CA_CERT_B64=$(echo "$SERVICE_JSON" | jq -r '
  .SERVICE.roles[]
  | select(.name == "superlink")
  | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_CA_CERT // empty
')
```

### Retrieval Logic

```
After discovering FL_ENDPOINT from OneGate:

IF FL_TLS_FLAG == "YES":
    IF FL_CA_CERT_B64 is non-empty:
        Decode: echo "$FL_CA_CERT_B64" | base64 -d > /opt/flower/certs/ca.crt
        Set ownership: chown 49999:49999 /opt/flower/certs/ca.crt
        Set permissions: chmod 0644 /opt/flower/certs/ca.crt
        LOG "CA certificate retrieved from OneGate and written to /opt/flower/certs/ca.crt"
        Set TLS_MODE=enabled
    ELSE:
        LOG "FATAL: SuperLink advertises FL_TLS=YES but FL_CA_CERT not published to OneGate"
        LOG "FATAL: SuperLink may still be publishing, or OneGate publication failed on SuperLink"
        LOG "FATAL: Workaround: set FL_SSL_CA_CERTFILE in SuperNode CONTEXT for static provisioning"
        EXIT 1 (boot aborts)

IF FL_TLS_FLAG != "YES" or empty:
    LOG "SuperLink not advertising TLS (FL_TLS=${FL_TLS_FLAG:-not set}). Using insecure mode."
    TLS_MODE=disabled (proceed with --insecure, Phase 1 behavior)
```

### Retrieval Function Specification

```bash
# Extends the existing discover.sh to handle TLS certificate retrieval
# Called after FL_ENDPOINT has been successfully extracted from service_json

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
            chmod 0644 "${cert_dir}/ca.crt"
            log "INFO" "CA certificate retrieved from OneGate"
            echo "enabled"
            return 0
        else
            log "ERROR" "SuperLink has FL_TLS=YES but FL_CA_CERT not published"
            log "ERROR" "Set FL_SSL_CA_CERTFILE in CONTEXT for static CA provisioning"
            return 1
        fi
    fi

    echo "disabled"
    return 0  # No TLS, no cert needed
}
```

**Error handling:** The FATAL error when `FL_TLS=YES` but `FL_CA_CERT` is missing is intentional. This state means the SuperLink claims TLS is active but failed to publish its CA certificate. Proceeding with `--insecure` would silently downgrade security. The operator must either fix the SuperLink's OneGate publication or provide the CA cert via `FL_SSL_CA_CERTFILE`.

---

## 3. Static CA Certificate Provisioning

For SuperNodes deployed outside OneFlow (no OneGate service context) or with a static `FL_SUPERLINK_ADDRESS`, the CA certificate must be provided explicitly via CONTEXT variables.

### When Static Provisioning Applies

| Deployment Scenario | OneGate Available? | Static Provisioning Required? |
|--------------------|--------------------|-------------------------------|
| OneFlow with OneGate working | Yes | No (OneGate retrieval is default) |
| OneFlow but operator wants own CA | Yes | Optional (overrides OneGate retrieval) |
| Standalone VM with `FL_SUPERLINK_ADDRESS` | No | Yes (only path available) |
| Cross-zone deployment (Phase 7) | Potentially not | Yes (OneGate may not work cross-zone) |

### Static Provisioning Variables

| Variable | Required When | Content |
|----------|--------------|---------|
| `FL_TLS_ENABLED` | Always for static TLS | Must be `YES` to activate TLS processing |
| `FL_SSL_CA_CERTFILE` | `FL_TLS_ENABLED=YES` in static mode | Base64-encoded PEM CA certificate |

### Decode Procedure

```bash
decode_static_ca_cert() {
    local cert_dir="/opt/flower/certs"

    if [ -n "${FL_SSL_CA_CERTFILE:-}" ]; then
        echo "${FL_SSL_CA_CERTFILE}" | base64 -d > "${cert_dir}/ca.crt"
        chown 49999:49999 "${cert_dir}/ca.crt"
        chmod 0644 "${cert_dir}/ca.crt"
        log "INFO" "CA certificate decoded from FL_SSL_CA_CERTFILE CONTEXT variable"
    else
        log "ERROR" "FL_TLS_ENABLED=YES but FL_SSL_CA_CERTFILE not provided"
        log "ERROR" "Static TLS mode requires FL_SSL_CA_CERTFILE (base64-encoded PEM CA cert)"
        exit 1
    fi
}
```

### Decision Logic for Static Mode

```
IF FL_SUPERLINK_ADDRESS is set (static discovery mode):
    IF FL_TLS_ENABLED == YES:
        IF FL_SSL_CA_CERTFILE is set and non-empty:
            Decode FL_SSL_CA_CERTFILE -> /opt/flower/certs/ca.crt
            Set TLS_MODE=enabled
        ELSE:
            FATAL: "Static TLS mode requires FL_SSL_CA_CERTFILE. No OneGate available for auto-retrieval."
            EXIT 1
    ELSE:
        TLS_MODE=disabled (--insecure mode)
```

### Override Behavior in OneFlow Deployments

When `FL_SSL_CA_CERTFILE` is set in CONTEXT, it takes precedence over OneGate retrieval regardless of whether OneGate is available. This means:

1. The discovery query still runs (to find `FL_ENDPOINT`).
2. The `FL_CA_CERT` attribute from OneGate is ignored.
3. The CONTEXT-provided CA certificate is used instead.

This allows operators to use their own CA certificate (from their PKI) even in OneFlow deployments where the SuperLink auto-generates a different CA.

**Note:** If the operator provides their own CA cert on the SuperNode, they must also provide the matching server certificate and key on the SuperLink via `FL_SSL_CA_CERTFILE`, `FL_SSL_CERTFILE`, and `FL_SSL_KEYFILE`. A mismatch (SuperLink auto-generated cert, SuperNode operator-provided CA) causes TLS handshake failure.

---

## 4. TLS Mode Detection Logic

The SuperNode must determine its TLS mode before starting the container. The detection follows a strict priority order with four possible outcomes.

### Decision Flowchart

```
                    FL_TLS_ENABLED in CONTEXT?
                    /                        \
                  YES                        NO or unset
                  |                            |
          TLS mode FORCED ON            OneGate discovery available?
          (explicit operator decision)   /                         \
                  |                   YES                          NO
                  |                    |                            |
                  |              FL_TLS attribute                   |
                  |              on SuperLink VM?                   |
                  |              /              \                   |
                  |           YES               NO                 |
                  |            |                 |                  |
                  v            v                 v                  v
              CASE 1       CASE 2           CASE 3             CASE 4
           Explicit TLS   Auto-detected   Insecure mode     Insecure mode
                           TLS             (OneGate says no)  (no signal)
```

### Four Cases

| Case | Trigger | TLS Mode | CA Cert Source | Docker Flag |
|------|---------|----------|---------------|-------------|
| 1 | `FL_TLS_ENABLED=YES` in CONTEXT | Enabled | `FL_SSL_CA_CERTFILE` (CONTEXT) or OneGate `FL_CA_CERT` | `--root-certificates ca.crt` |
| 2 | `FL_TLS_ENABLED` not set; OneGate `FL_TLS=YES` | Enabled | OneGate `FL_CA_CERT` | `--root-certificates ca.crt` |
| 3 | `FL_TLS_ENABLED` not set; OneGate `FL_TLS!=YES` | Disabled | None | `--insecure` |
| 4 | `FL_TLS_ENABLED` not set; No OneGate available | Disabled | None | `--insecure` |

### Priority Order

```
1. Explicit CONTEXT (FL_TLS_ENABLED=YES)     -- highest priority, forces TLS on
2. Explicit CONTEXT (FL_TLS_ENABLED=NO)      -- forces TLS off (even if SuperLink advertises TLS)
3. OneGate auto-detection (FL_TLS=YES)       -- automatic, zero-config TLS
4. Insecure default                          -- lowest priority, Phase 1 behavior
```

### Detection Pseudocode

```bash
determine_tls_mode() {
    # Priority 1: Explicit CONTEXT variable
    if [ "${FL_TLS_ENABLED:-}" = "YES" ]; then
        log "INFO" "TLS explicitly enabled via FL_TLS_ENABLED=YES"
        echo "enabled"
        return 0
    fi

    if [ "${FL_TLS_ENABLED:-}" = "NO" ]; then
        log "INFO" "TLS explicitly disabled via FL_TLS_ENABLED=NO"
        echo "disabled"
        return 0
    fi

    # Priority 2: OneGate auto-detection (only if OneGate discovery was used)
    if [ -n "${ONEGATE_TLS_FLAG:-}" ]; then
        if [ "$ONEGATE_TLS_FLAG" = "YES" ]; then
            log "INFO" "TLS auto-detected from OneGate (FL_TLS=YES on SuperLink)"
            echo "enabled"
            return 0
        fi
    fi

    # Priority 3: Insecure default
    log "INFO" "TLS not enabled. Using --insecure mode (Phase 1 behavior)."
    echo "disabled"
    return 0
}
```

### TLS Mode Mismatch Warning

If `FL_TLS_ENABLED=NO` is explicitly set on a SuperNode but the SuperLink advertises `FL_TLS=YES`, the SuperNode will attempt to connect in insecure mode to a TLS-enabled SuperLink. This will fail at runtime with a gRPC connection error.

This is documented as an **operator error**, not a bug. The explicit `FL_TLS_ENABLED=NO` setting means the operator intentionally disabled TLS on this SuperNode. The spec does not override this decision -- it respects operator intent even when it leads to a connection failure.

**Log message on mismatch detection:**

```
[WARN] FL_TLS_ENABLED=NO but SuperLink advertises FL_TLS=YES via OneGate.
[WARN] This SuperNode will connect in insecure mode. Connection will fail if SuperLink requires TLS.
[WARN] Remove FL_TLS_ENABLED=NO or set FL_TLS_ENABLED=YES to match SuperLink TLS mode.
```

---

## 5. Certificate Validation on SuperNode

After acquiring the CA certificate (from either OneGate or CONTEXT), the SuperNode validates it before proceeding to container startup.

### Validation Command

```bash
openssl x509 -in /opt/flower/certs/ca.crt -noout 2>/dev/null
```

This verifies that the file contains a valid PEM-encoded X.509 certificate. It does NOT verify:
- Certificate chain (SuperNode only has the CA cert; chain verification requires the server cert, which arrives during handshake).
- Certificate expiry (checked at TLS handshake time by gRPC).
- Certificate purpose/extensions (gRPC handles this during handshake).

### Validation Procedure

```bash
validate_ca_cert() {
    local cert_path="/opt/flower/certs/ca.crt"

    if [ ! -f "$cert_path" ]; then
        log "ERROR" "CA certificate file not found at ${cert_path}"
        exit 1
    fi

    if ! openssl x509 -in "$cert_path" -noout 2>/dev/null; then
        log "ERROR" "CA certificate at ${cert_path} is not valid PEM format"
        log "ERROR" "Check FL_SSL_CA_CERTFILE encoding or SuperLink FL_CA_CERT publication"
        log "ERROR" "Expected: base64-encoded PEM certificate (-----BEGIN CERTIFICATE-----)"
        exit 1
    fi

    log "INFO" "CA certificate validated: $(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null)"
}
```

### Failure Behavior

Validation failure is **FATAL**. If the CA certificate is invalid:

1. Boot sequence aborts at Step 7b.
2. VM does not report ready.
3. Error is logged with clear remediation guidance.
4. If OneGate is reachable, `FL_NODE_READY=NO` is published.

**Common causes of validation failure:**
- `FL_SSL_CA_CERTFILE` contains raw PEM instead of base64-encoded PEM (double encoding is required).
- `FL_CA_CERT` on OneGate was corrupted during publication (transport encoding issue).
- Operator provided the wrong file (server cert instead of CA cert, private key instead of cert).

---

## 6. SuperNode Boot Sequence Modification

This section describes changes to the Phase 1 SuperNode boot sequence (defined in `spec/02-supernode-appliance.md`, Section 7). Changes are presented as a delta -- Phase 1 steps not mentioned here remain unchanged.

### Step 7 (Discovery): UPDATED

**Phase 1 behavior:** Query OneGate, extract `FL_ENDPOINT`, set `SUPERLINK_ADDRESS`.

**Phase 2 addition:** After extracting `FL_ENDPOINT`, also extract TLS attributes and determine TLS mode.

```
Step 7 (UPDATED): SuperLink Discovery with TLS Detection

    Phase 1 behavior (unchanged):
        Execute discovery (static or OneGate)
        Resolve SUPERLINK_ADDRESS

    NEW Phase 2 additions:
        IF using OneGate discovery:
            Extract FL_TLS from SuperLink VM USER_TEMPLATE
            Extract FL_CA_CERT from SuperLink VM USER_TEMPLATE
            Call retrieve_ca_cert() if FL_TLS=YES

        Determine TLS mode using priority logic (Section 4):
            Check FL_TLS_ENABLED (CONTEXT) first
            Then check OneGate FL_TLS
            Then default to insecure

        IF TLS mode enabled:
            Acquire CA cert (OneGate or FL_SSL_CA_CERTFILE)
            Set TLS_MODE=enabled flag for Steps 7b and 10
        ELSE:
            Set TLS_MODE=disabled (Phase 1 behavior)
```

### NEW Step 7b: TLS Certificate Validation

Inserted between Step 7 (Discovery) and Step 8 (Wait for Docker daemon).

```
Step 7b (NEW): TLS Certificate Validation

    IF TLS_MODE == enabled:
        Validate CA cert: openssl x509 -in /opt/flower/certs/ca.crt -noout
        IF validation fails:
            LOG "FATAL: CA certificate is invalid PEM format"
            LOG "FATAL: Check FL_SSL_CA_CERTFILE or SuperLink FL_CA_CERT publication"
            Publish FL_NODE_READY=NO to OneGate (if reachable)
            EXIT 1 (boot aborts)
        LOG "CA certificate validated successfully"
    ELSE:
        SKIP (no TLS, no validation needed)
```

**Failure behavior:** Any failure in Step 7b is FATAL. The boot sequence aborts. The VM does not report ready.

### Step 10 (Container Start): UPDATED

**Phase 1 behavior:** Start container with `--insecure` flag.

**Phase 2 change:** Conditionally modify Docker run command based on TLS mode.

```
Step 10 (UPDATED): Create and Start Flower SuperNode Container

    IF TLS_MODE == enabled:
        Docker run command:
            - REMOVE: --insecure
            - ADD: -v /opt/flower/certs/ca.crt:/app/ca.crt:ro
            - ADD: --root-certificates ca.crt
    ELSE:
        Docker run command: unchanged from Phase 1 (includes --insecure)

    Start container via systemctl start flower-supernode
```

### Updated Boot Sequence Summary

```
Phase 1 Steps 1-6: unchanged
Step 7:  Discovery with TLS detection    <-- UPDATED
Step 7b: TLS certificate validation      <-- NEW
Steps 8-9: unchanged
Step 10: Container start (conditional TLS) <-- UPDATED
Steps 11-13: unchanged
```

The SuperNode boot sequence becomes effectively 14 steps (13 from Phase 1 + Step 7b).

---

## 7. SuperNode Docker Run Command (TLS Mode)

### Phase 1 Command (Insecure Mode -- Reference)

```bash
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  -v /opt/flower/data:/app/data:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES:-0} \
  --max-wait-time ${FL_MAX_WAIT_TIME:-0}
```

### Phase 2 Command (TLS Mode)

```bash
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
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

### Differences Summary

| Aspect | Phase 1 (Insecure) | Phase 2 (TLS) |
|--------|-------------------|---------------|
| TLS flag | `--insecure` | (removed) |
| Root certificates | -- | `--root-certificates ca.crt` |
| CA cert volume | -- | `-v /opt/flower/certs/ca.crt:/app/ca.crt:ro` |
| Port / connection | Same | Same (gRPC+TLS uses the same port 9092) |

**Single-file mount:** The SuperNode mounts only `ca.crt`, not the entire `/opt/flower/certs/` directory. This is different from the SuperLink, which mounts the full directory (because it needs `ca.crt`, `server.pem`, and `server.key`). The SuperNode needs only the CA certificate.

**Mount path:** `/opt/flower/certs/ca.crt:/app/ca.crt:ro` -- the CA cert appears at `/app/ca.crt` inside the container. The `--root-certificates ca.crt` flag uses a path relative to the container working directory (`/app/`), resolving to `/app/ca.crt`.

**Read-only mount:** The `:ro` flag prevents the container from modifying the CA certificate. Defense-in-depth: even if the container process is compromised, it cannot tamper with the trust anchor.

### Systemd Unit File (TLS Mode)

```ini
[Unit]
Description=Flower SuperNode (Federated Learning Client)
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=5s
ExecStartPre=-/usr/bin/docker rm -f flower-supernode
ExecStart=/usr/bin/docker run \
  --name flower-supernode \
  --rm \
  -v /opt/flower/data:/app/data:ro \
  -v /opt/flower/certs/ca.crt:/app/ca.crt:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL} \
  flwr/supernode:${FLOWER_VERSION} \
  --root-certificates ca.crt \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES} \
  --max-wait-time ${FL_MAX_WAIT_TIME}
ExecStop=/usr/bin/docker stop -t 30 flower-supernode

[Install]
WantedBy=multi-user.target
```

---

## 8. End-to-End TLS Handshake Walkthrough

This section traces the complete TLS lifecycle from SuperLink boot through encrypted gRPC communication. This walkthrough satisfies Phase 2 success criterion #3: "a reader can follow the complete TLS handshake path."

### Step-by-Step Flow

**Step 1: SuperLink boots with TLS enabled**

The SuperLink VM starts with `FL_TLS_ENABLED=YES` in its CONTEXT variables. During boot Step 7a (see `spec/04-tls-certificate-lifecycle.md`, Section 5), the configure script detects TLS mode and initiates certificate setup.

**Step 2: SuperLink generates self-signed CA and server certificate**

If no operator-provided certificates are present (`FL_SSL_CA_CERTFILE` is empty), the SuperLink runs `generate-certs.sh`:

1. Generates 4096-bit RSA CA private key (`ca.key`).
2. Creates self-signed CA certificate (`ca.crt`, valid 365 days, subject `/O=Flower FL/CN=Flower CA`).
3. Generates 4096-bit RSA server private key (`server.key`).
4. Creates server CSR with dynamic SAN (includes the SuperLink VM's IP address).
5. Signs server certificate with CA (`server.pem`, valid 365 days).
6. Verifies chain: `openssl verify -CAfile ca.crt server.pem`.
7. Sets ownership: `ca.crt`, `server.pem`, `server.key` owned by 49999:49999; `ca.key` owned by root:root (0600).

**Step 3: SuperLink starts container with TLS certificates**

The SuperLink Docker run command includes:

```bash
-v /opt/flower/certs:/app/certificates:ro
--ssl-ca-certfile certificates/ca.crt
--ssl-certfile certificates/server.pem
--ssl-keyfile certificates/server.key
```

Flower's gRPC server loads the certificate chain. The Fleet API on port 9092 now requires TLS connections.

**Step 4: SuperLink publishes TLS state and CA certificate to OneGate**

After the health check passes (port 9092 listening), the SuperLink publishes to OneGate:

```
FL_READY=YES
FL_ENDPOINT=192.168.1.100:9092
FL_VERSION=1.25.0
FL_ROLE=superlink
FL_TLS=YES
FL_CA_CERT=<base64-encoded ca.crt>
```

The CA certificate is encoded with `base64 -w0` for single-line OneGate transport.

**Step 5: SuperNode boots and discovers SuperLink with TLS**

The SuperNode queries OneGate during Step 7 (discovery). It extracts:
- `FL_ENDPOINT=192.168.1.100:9092` (the SuperLink address).
- `FL_TLS=YES` (TLS is active).
- `FL_CA_CERT=<base64>` (the CA certificate).

The SuperNode decodes the CA certificate:

```bash
echo "$FL_CA_CERT_B64" | base64 -d > /opt/flower/certs/ca.crt
chown 49999:49999 /opt/flower/certs/ca.crt
```

**Step 6: SuperNode validates CA certificate format**

During Step 7b (new), the SuperNode validates the CA certificate:

```bash
openssl x509 -in /opt/flower/certs/ca.crt -noout
```

If valid, boot continues. If invalid, boot aborts with a FATAL error.

**Step 7: SuperNode starts container with CA certificate**

The SuperNode Docker run command includes:

```bash
-v /opt/flower/certs/ca.crt:/app/ca.crt:ro
--root-certificates ca.crt
```

Flower's gRPC client loads the CA certificate as its trust anchor. The `--insecure` flag is NOT present.

**Step 8: gRPC TLS handshake**

The SuperNode initiates a gRPC connection to `192.168.1.100:9092`:

1. **ClientHello:** SuperNode sends TLS ClientHello message to SuperLink.
2. **ServerHello + Certificate:** SuperLink responds with its server certificate (`server.pem`).
3. **Certificate verification:** SuperNode's gRPC TLS layer verifies:
   - `server.pem` was signed by the CA in `ca.crt` (chain validation).
   - The server certificate's SAN includes the IP address `192.168.1.100` (the address the SuperNode connected to).
   - The certificate has not expired (within 365-day validity window).
4. **Key exchange:** Standard TLS key exchange completes.
5. **Handshake success:** Both sides have a shared session key.

**Step 9: Encrypted gRPC channel established**

The gRPC channel is now encrypted with TLS 1.2+ (protocol version negotiated by gRPC's transport layer). All subsequent communication is encrypted:

- Model weights sent from SuperLink to SuperNode (for local training initialization).
- Updated model weights/gradients sent from SuperNode back to SuperLink (training results).
- Control messages (round assignments, evaluation requests, completion signals).

**Data privacy is preserved:** Training data never leaves the SuperNode VM. Only encrypted model updates traverse the network. An observer monitoring network traffic sees only encrypted TLS packets.

**SAN mismatch failure case:** If the SuperLink's IP address changed between certificate generation and the SuperNode's connection attempt (e.g., VM migration, elastic IP reassignment), the SAN in `server.pem` will not match the connection IP. The TLS handshake fails with "certificate verify failed" in gRPC logs. Resolution: redeploy the SuperLink to regenerate certificates with the new IP.

### Sequence Diagram

```
   SuperLink VM                     OneGate                     SuperNode VM
   ============                     =======                     ============

   1. Boot (FL_TLS_ENABLED=YES)
      |
   2. Generate certs:
      ca.key, ca.crt,
      server.key, server.pem
      |
   3. Start container with
      --ssl-ca-certfile
      --ssl-certfile
      --ssl-keyfile
      |
      | Health check passes
      |
   4. PUT FL_TLS=YES ------------>  Store FL_TLS,
      PUT FL_CA_CERT=<b64> ------>  FL_CA_CERT,
      PUT FL_ENDPOINT=ip:9092 --->  FL_ENDPOINT
                                                               5. Boot
                                                                  |
                                    GET /service <--------------- Query OneGate
                                    Return FL_ENDPOINT,  -------> Extract FL_TLS=YES
                                    FL_TLS, FL_CA_CERT            Decode FL_CA_CERT
                                                                  -> /opt/flower/certs/ca.crt
                                                                  |
                                                               6. Validate CA cert
                                                                  openssl x509 -in ca.crt -noout
                                                                  |
                                                               7. Start container with
                                                                  --root-certificates ca.crt
                                                                  |
   <============== TLS Handshake (gRPC over port 9092) ===========>
   |                                                               |
   8. Server presents server.pem                                   |
      |                                                            |
      |                            8. Client verifies:
      |                               server.pem signed by ca.crt?
      |                               SAN matches connection IP?
      |                               Certificate not expired?
      |                                                            |
   <================== Encrypted gRPC Channel ===================>
   |                                                               |
   9. Model weights <-- encrypted --> Training results             |
      Control msgs  <-- encrypted --> Status updates               |
      |                                                            |
      |            Data NEVER leaves SuperNode VM                  |
```

---

## 9. SuperNode Contextualization Variable Updates

Phase 1 defined `FL_TLS_ENABLED` and `FL_SSL_CA_CERTFILE` as placeholder variables for the SuperNode (see `spec/02-supernode-appliance.md`, Section 13, "Phase 2+ Placeholder Variables"). These are now fully specified.

### Fully Specified SuperNode TLS Variables

| # | Context Variable | USER_INPUT Definition | Type | Default | Validation Rule | Purpose |
|---|------------------|----------------------|------|---------|-----------------|---------|
| 1 | `FL_TLS_ENABLED` | `O\|boolean\|Enable TLS encryption\|\|NO` | boolean | `NO` | Must be `YES` or `NO` (case-insensitive). Any other value is rejected. | Master switch for TLS mode on SuperNode. `YES` forces TLS on (requires CA cert). `NO` forces insecure mode. Unset allows OneGate auto-detection. |
| 2 | `FL_SSL_CA_CERTFILE` | `O\|text64\|CA certificate (base64 PEM)` | text64 | (empty) | If set: must decode (`base64 -d`) to valid PEM (`openssl x509 -in - -noout`) | Base64-encoded PEM CA certificate for TLS trust verification. Used as `--root-certificates`. Bypasses OneGate retrieval when set. |

### USER_INPUT Definitions

```
# Phase 2: TLS (SuperNode)
FL_TLS_ENABLED = "O|boolean|Enable TLS encryption||NO"
FL_SSL_CA_CERTFILE = "O|text64|CA certificate (base64 PEM)"
```

### SuperNode-Specific Notes

- `FL_SSL_CERTFILE` and `FL_SSL_KEYFILE` are **SuperLink-only** variables. They are NOT used on the SuperNode because the SuperNode does not present a server certificate (no mTLS).
- `FL_SSL_CA_CERTFILE` on the SuperNode serves a different purpose than on the SuperLink:
  - **SuperLink:** Decision variable for auto-gen vs operator-provided path. When set, triggers decode of all three `FL_SSL_*` vars.
  - **SuperNode:** CA certificate override. When set, used directly as the trust anchor for `--root-certificates`.

### Validation Rules

| Variable | Rule | Error on Violation |
|----------|------|--------------------|
| `FL_TLS_ENABLED` | Must be `YES` or `NO` (case-insensitive) | `"Invalid FL_TLS_ENABLED: '${VALUE}'. Must be YES or NO."` |
| `FL_SSL_CA_CERTFILE` | If set: must decode via `base64 -d` and pass `openssl x509 -in - -noout` | `"FL_SSL_CA_CERTFILE does not contain a valid base64-encoded PEM certificate."` |

### Consistency Rules

| Rule | Scope | Enforcement |
|------|-------|-------------|
| If using static discovery (`FL_SUPERLINK_ADDRESS` set) with TLS, `FL_SSL_CA_CERTFILE` is required | Static deployments | Fatal error at boot if missing. No OneGate to retrieve CA cert from. |
| If `FL_TLS_ENABLED=YES` explicitly, CA cert must come from either `FL_SSL_CA_CERTFILE` or OneGate | All deployments | Fatal error if neither source provides a CA cert. |
| `FL_TLS_ENABLED=NO` overrides OneGate `FL_TLS=YES` | OneGate deployments | Warning logged, insecure mode used. Connection will fail if SuperLink requires TLS. |

### Transition from Phase 1 Placeholders

In Phase 1, the configure script recognizes `FL_TLS_ENABLED` and `FL_SSL_CA_CERTFILE` but logs:

```
"Variable FL_TLS_ENABLED is a Phase 2 feature; ignoring in current appliance version."
```

In Phase 2, these variables are fully functional. The configure script processes them as specified in this document.

---

## 10. Failure Modes

### Failure Classification Table

| # | Failure | Trigger | Severity | Boot Continues? | Symptom | Recovery Action |
|---|---------|---------|----------|-----------------|---------|-----------------|
| 1 | FL_TLS=YES but FL_CA_CERT missing from OneGate | SuperLink published TLS flag but not the CA cert (publication partial failure) | Fatal | No | Boot aborts at Step 7 with error: "SuperLink has FL_TLS=YES but FL_CA_CERT not published" | Fix SuperLink OneGate publication. Or set `FL_SSL_CA_CERTFILE` in SuperNode CONTEXT for static provisioning. |
| 2 | Base64 decode failure | `FL_SSL_CA_CERTFILE` or `FL_CA_CERT` contains invalid base64 | Fatal | No | `base64 -d` produces empty or corrupt output. `openssl x509` validation fails in Step 7b. | Verify encoding: `cat ca.crt \| base64 -w0` produces valid base64. Check for truncation or extra whitespace. |
| 3 | Invalid PEM certificate | Decoded content is not a valid X.509 PEM certificate | Fatal | No | `openssl x509 -in ca.crt -noout` returns non-zero in Step 7b. | Check that the source file is a PEM certificate (starts with `-----BEGIN CERTIFICATE-----`). Verify it is the CA cert, not a private key or server cert. |
| 4 | TLS mode mismatch: SuperLink TLS, SuperNode insecure | SuperNode connects with `--insecure` to a TLS-enabled SuperLink | Runtime | Yes (container starts) | SuperNode logs: "SSL handshake failed" or "Connection refused" immediately after gRPC connect attempt. Container stays running but cannot train. | Set `FL_TLS_ENABLED=YES` on SuperNode or remove explicit `FL_TLS_ENABLED=NO`. In OneFlow, set at service level. |
| 5 | TLS mode mismatch: SuperLink insecure, SuperNode TLS | SuperNode connects with `--root-certificates` to an insecure SuperLink | Runtime | Yes (container starts) | SuperNode logs: gRPC connection error, unexpected plaintext response. Container stays running but cannot train. | Remove `FL_TLS_ENABLED=YES` from SuperNode or enable TLS on SuperLink. |
| 6 | SAN mismatch | SuperNode connects to an IP not in the server certificate's SAN | Runtime | Yes (container starts) | SuperNode gRPC logs: "certificate verify failed" or "hostname mismatch". Handshake fails. | Verify SuperLink IP matches SAN in server cert. If SuperLink IP changed, redeploy SuperLink to regenerate certs with new IP. |
| 7 | Missing FL_SSL_CA_CERTFILE in static mode | `FL_TLS_ENABLED=YES` and `FL_SUPERLINK_ADDRESS` set, but no `FL_SSL_CA_CERTFILE` | Fatal | No | Boot aborts: "Static TLS mode requires FL_SSL_CA_CERTFILE" | Provide `FL_SSL_CA_CERTFILE` in CONTEXT with base64-encoded PEM CA certificate from the SuperLink's `/opt/flower/certs/ca.crt`. |
| 8 | Certificate expired (after 365 days) | Auto-generated certificate validity period exceeded | Runtime | n/a (occurs after long uptime) | SuperNode gRPC logs: "certificate has expired". New connections fail. Existing connections may continue until renegotiation. | Redeploy the SuperLink (generates fresh 365-day certs). Or provide longer-lived operator certs via `FL_SSL_*` variables. |
| 9 | CA cert / server cert mismatch | SuperNode has CA cert from operator; SuperLink uses auto-generated cert (or vice versa) | Runtime | Yes (container starts) | SuperNode gRPC logs: "certificate verify failed" (server cert not signed by the CA the SuperNode trusts). | Ensure the same CA signed the server cert and is provided to SuperNodes. In operator-provided mode, all `FL_SSL_*` vars must be consistent across SuperLink and SuperNodes. |

### Error Log Examples

**Fatal errors (boot aborts):**

```
[2026-02-07 10:15:33] [ERROR] [flower-configure] SuperLink has FL_TLS=YES but FL_CA_CERT not published to OneGate
[2026-02-07 10:15:33] [ERROR] [flower-configure] Set FL_SSL_CA_CERTFILE in CONTEXT for static CA provisioning
[2026-02-07 10:15:33] [FATAL] [flower-configure] Boot sequence aborted at Step 7 (TLS Discovery)
```

```
[2026-02-07 10:15:33] [ERROR] [flower-configure] CA certificate at /opt/flower/certs/ca.crt is not valid PEM format
[2026-02-07 10:15:33] [FATAL] [flower-configure] Boot sequence aborted at Step 7b (TLS Certificate Validation)
```

**Runtime errors (container running but connection fails):**

```
WARNING flower.client:grpc_transport.py - SSL handshake failed: certificate verify failed
ERROR flower.client:grpc_transport.py - Failed to connect to 192.168.1.100:9092
```

---

## 11. Security Considerations

### What the SuperNode Sees and Does NOT See

| Artifact | SuperNode Has Access? | Rationale |
|----------|----------------------|-----------|
| CA certificate (`ca.crt`) | Yes (mounted into container) | Required for `--root-certificates` to verify SuperLink identity |
| CA private key (`ca.key`) | No | Retained on SuperLink with root:root 0600. Never published, never distributed. |
| Server certificate (`server.pem`) | No (until handshake) | Received during TLS handshake from SuperLink. Not pre-distributed. |
| Server private key (`server.key`) | No | Never leaves SuperLink VM. Only the SuperLink process reads this. |

### OneGate as Trust Distribution Channel

OneGate is the mechanism for distributing the CA certificate from SuperLink to SuperNodes.

**Protection model:**
- OneGate access requires a valid `X-ONEGATE-TOKEN` (generated per-VM by OpenNebula contextualization when `TOKEN=YES`).
- The `/service` endpoint returns data only for VMs within the same OneFlow service.
- A VM in Service A cannot read attributes from VMs in Service B.
- The `FL_CA_CERT` attribute is a public certificate (not a secret), but OneGate's access control prevents unauthorized VMs from reading it.

**Limitation:** OneGate tokens are per-VM and scoped to the OneFlow service. If an attacker compromises a VM within the same service, they can read `FL_CA_CERT`. However, since `FL_CA_CERT` is a public CA certificate (not a private key), this does not compromise the TLS security. The attacker cannot forge server certificates without the CA private key, which is protected on the SuperLink.

### Cross-Zone Considerations

For cross-zone deployments (Phase 7 scope), OneGate may not work across zones. In this case:

- SuperNodes in remote zones cannot query OneGate to retrieve `FL_CA_CERT`.
- The CA certificate must be provided via `FL_SSL_CA_CERTFILE` in the SuperNode's CONTEXT variables.
- The operator extracts `ca.crt` from the SuperLink VM and encodes it: `base64 -w0 /opt/flower/certs/ca.crt`.
- This base64 string is set as the `FL_SSL_CA_CERTFILE` value in the remote SuperNode's VM template.

### Data Privacy

TLS encryption protects model weights and gradients in transit. However, the primary privacy guarantee of federated learning is architectural: training data never leaves the SuperNode VM. TLS adds transport-layer confidentiality on top of this architectural guarantee.

With TLS enabled:
- An observer monitoring network traffic between SuperNode and SuperLink sees only encrypted TLS packets.
- Without TLS (Phase 1 `--insecure`), the observer could reconstruct model weights from the plaintext gRPC traffic. This does not reveal raw training data but may enable model inversion attacks.

---

## Appendix A: Relationship to Other Spec Sections

| Spec Section | Relationship | Key Dependencies |
|-------------|-------------|------------------|
| `spec/01-superlink-appliance.md` | SuperLink is the TLS server. SuperNode trusts the CA that signed the SuperLink's server certificate. The server cert is presented during the TLS handshake (Step 8 of the end-to-end walkthrough). | SuperLink must be TLS-configured before SuperNodes can connect with TLS. |
| `spec/02-supernode-appliance.md` | This document modifies the SuperNode boot sequence: Step 7 updated (TLS discovery), Step 7b inserted (cert validation), Step 10 updated (Docker run with `--root-certificates`). The Phase 1 13-step sequence becomes 14 steps. | Phase 1 steps 1-6, 8-9, 11-13 remain unchanged. |
| `spec/03-contextualization-reference.md` | `FL_TLS_ENABLED` and `FL_SSL_CA_CERTFILE` placeholders from Section 6 are now fully specified for SuperNode. Variable definitions in this document take precedence per the source-of-truth hierarchy. | Variable count updated: 2 of 6 placeholders are now active for SuperNode. |
| `spec/04-tls-certificate-lifecycle.md` | This document consumes what `04` produces: OneGate `FL_TLS` and `FL_CA_CERT` attributes (Section 7), contextualization variable definitions (Section 8), and the dual provisioning model (Section 4). Together, they form the complete APPL-04 specification. | The `FL_CA_CERT` attribute name, base64 encoding format, and jq extraction path must match between SuperLink publication and SuperNode retrieval. |
| Phase 4 (OneFlow Orchestration) | In OneFlow service templates, `FL_TLS_ENABLED` SHOULD be set at the service level for TLS mode consistency across all roles. The SuperNode auto-detects TLS from OneGate when `FL_TLS_ENABLED` is not set. | Depends on TLS mode detection logic (Section 4) and OneGate retrieval (Section 2). |
| Phase 7 (Multi-Site Federation) | Cross-zone SuperNodes cannot use OneGate for CA cert retrieval. Static provisioning via `FL_SSL_CA_CERTFILE` is the only path. The CA key retained on the SuperLink (root:root 0600) may be needed to sign additional server certs. | Depends on static provisioning (Section 3) and cross-zone considerations (Section 11). |

---

*Specification for APPL-04: SuperNode TLS Trust and End-to-End Handshake*
*Phase: 02 - Security and Certificate Automation*
*Version: 1.0*
