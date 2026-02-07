---
phase: 02-security-and-certificate-automation
verified: 2026-02-07T19:15:00Z
status: passed
score: 5/5 must-haves verified
---

# Phase 2: Security and Certificate Automation Verification Report

**Phase Goal:** The spec fully defines the TLS certificate lifecycle -- generation on server boot, automated distribution to clients via OneGate, correct file permissions for Flower containers, and the trust chain model

**Verified:** 2026-02-07T19:15:00Z
**Status:** PASSED
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The spec defines the exact certificate generation sequence (CA creation, server cert signing, file paths, and ownership set to UID 49999) | ✓ VERIFIED | `spec/04-tls-certificate-lifecycle.md` Section 3 contains complete 8-step OpenSSL sequence with RSA 4096-bit keys, SHA-256 signing, dynamic SAN with VM IP, ownership commands (ca.key root:root 0600, ca.crt/server.pem/server.key 49999:49999), and chain verification |
| 2 | The spec defines how the SuperLink publishes its CA certificate to OneGate and how SuperNodes retrieve and trust it | ✓ VERIFIED | Spec 04 Section 7 defines OneGate publication (FL_TLS=YES, FL_CA_CERT as base64-encoded ca.crt). Spec 05 Section 2 defines jq extraction paths for FL_TLS and FL_CA_CERT from OneGate service JSON, decode to /opt/flower/certs/ca.crt with 49999:49999 ownership |
| 3 | A reader can trace the complete TLS handshake path from SuperNode boot through certificate retrieval to authenticated gRPC connection | ✓ VERIFIED | Spec 05 Section 8 provides complete 9-step end-to-end walkthrough: SuperLink boot -> cert gen -> container start with TLS flags -> OneGate publication -> SuperNode discovery -> CA cert retrieval -> validation -> container start with --root-certificates -> gRPC TLS handshake (ClientHello, ServerHello+cert, chain+SAN verification) -> encrypted channel. Includes ASCII sequence diagram |
| 4 | The spec defines dual provisioning paths (auto-generation and operator-provided) with clear decision logic | ✓ VERIFIED | Spec 04 Section 4 defines decision flowchart: FL_TLS_ENABLED check -> FL_SSL_CA_CERTFILE check -> auto-gen (generate-certs.sh) or decode (all three FL_SSL_* vars required). Includes decode function spec and validation. Spec 05 Section 3 defines static SuperNode provisioning |
| 5 | The spec defines boot sequence modifications with step insertions and updates | ✓ VERIFIED | Spec 04 Section 5: SuperLink Step 7a inserted (TLS cert setup), Steps 8 and 12 updated. Spec 05 Section 6: SuperNode Step 7 updated (TLS discovery), Step 7b inserted (cert validation), Step 10 updated (Docker TLS flags). Both presented as deltas to Phase 1 with NEW/UPDATED markers |

**Score:** 5/5 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `spec/04-tls-certificate-lifecycle.md` | SuperLink TLS: cert generation, file layout, dual provisioning, boot changes, Docker flags, OneGate publication | ✓ VERIFIED | 770 lines, 10 sections + appendix. Contains complete OpenSSL commands, file permission table, dual provisioning flowchart, boot sequence delta, Docker run commands (insecure vs TLS), OneGate curl commands, 4 USER_INPUT definitions, 9 failure modes, security considerations |
| `spec/05-supernode-tls-trust.md` | SuperNode TLS: CA cert retrieval, static provisioning, TLS detection, validation, boot changes, Docker flags, end-to-end handshake | ✓ VERIFIED | 835 lines, 11 sections + appendix. Contains jq extraction paths, retrieve_ca_cert function spec, static decode procedure, 4-case TLS mode detection flowchart, validation commands, boot sequence delta, Docker run commands, 9-step handshake walkthrough with sequence diagram, 2 USER_INPUT definitions, 9 failure modes |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| spec/04 | spec/01-superlink-appliance.md | Boot sequence references | ✓ WIRED | Spec 04 Section 5 references Phase 1 boot sequence steps 7, 8, 12 by number. Step 7a insertion documented. Appendix A cross-references spec 01 |
| spec/04 | spec/03-contextualization-reference.md | Variable definitions | ✓ WIRED | Spec 04 Section 8 defines FL_TLS_ENABLED, FL_SSL_CA_CERTFILE, FL_SSL_CERTFILE, FL_SSL_KEYFILE with USER_INPUT format. Grep confirms these exist in spec 03 (lines 184-187, 195-198, 517-520) |
| spec/05 | spec/04-tls-certificate-lifecycle.md | OneGate attributes | ✓ WIRED | Spec 05 Section 2 extracts FL_TLS and FL_CA_CERT. Spec 05 Section 1 line 26 references spec 04 Sections 3, 4, 7 for SuperLink certificate generation and publication. Appendix A confirms bidirectional dependency |
| spec/05 | spec/02-supernode-appliance.md | Boot sequence references | ✓ WIRED | Spec 05 Section 6 references Phase 1 SuperNode boot sequence steps 7, 8-9, 10, 11-13 by number. Step 7b insertion documented. Appendix A cross-references spec 02 |
| spec/00-overview.md | Phase 2 specs | Navigation | ✓ WIRED | Line 77 describes TLS mode with references to specs 04 and 05. Lines 109-110 in section table include both Phase 2 specs with APPL-04 requirement mapping |

### Requirements Coverage

| Requirement | Status | Blocking Issue |
|-------------|--------|----------------|
| APPL-04: TLS certificate automation | ✓ SATISFIED | None - both SuperLink (spec 04) and SuperNode (spec 05) sides fully specified. Certificate generation sequence, distribution via OneGate, container permissions (UID 49999), and trust chain all defined |

### Anti-Patterns Found

No anti-patterns detected. Grep for "TODO|FIXME|placeholder|not implemented|coming soon|TBD" found only historical references to "Phase 1 placeholders" that are now fully specified in Phase 2.

---

## Detailed Verification

### Truth 1: Certificate Generation Sequence

**Spec Location:** `spec/04-tls-certificate-lifecycle.md`, Section 3 (lines 85-259)

**Verified Content:**
- Complete 8-step OpenSSL command sequence with exact parameters
- Step 1: `openssl genrsa -out ca.key 4096` (CA private key)
- Step 2: `openssl req -new -x509` with subject `/O=Flower FL/CN=Flower CA` (self-signed CA cert)
- Step 3: `openssl genrsa -out server.key 4096` (server private key)
- Step 4: `openssl req -new` with dynamic SAN config via process substitution, VM IP detected via `hostname -I | awk '{print $1}'`
- Step 5: `openssl x509 -req` signing server cert with CA (365 days, SHA-256)
- Step 6: Cleanup of CSR and serial files
- Step 7: Ownership and permissions:
  - `ca.key`: root:root 0600 (NOT container-accessible)
  - `ca.crt`: 49999:49999 0644
  - `server.pem`: 49999:49999 0644
  - `server.key`: 49999:49999 0600
- Step 8: Chain verification with `openssl verify -CAfile ca.crt server.pem`
- SAN configuration table (lines 222-232): DNS.1=localhost, IP.1=127.0.0.1, IP.2=::1, IP.3=${VM_IP}

**Assessment:** SUBSTANTIVE - Not a stub. Contains executable OpenSSL commands with precise parameters, file path specifications, ownership/permission commands, and verification logic.

### Truth 2: OneGate Publication and Retrieval

**Spec Location:**
- Publication: `spec/04-tls-certificate-lifecycle.md`, Section 7 (lines 548-631)
- Retrieval: `spec/05-supernode-tls-trust.md`, Section 2 (lines 30-128)

**Verified Content (Publication):**
- OneGate PUT command (lines 561-578) with FL_TLS=YES and FL_CA_CERT=(base64 -w0 ca.crt)
- Base64 encoding rationale (lines 617-622): -w0 for single-line, preserves PEM structure through XML transport
- Complete attribute table (lines 593-602) showing FL_READY, FL_ENDPOINT, FL_VERSION, FL_ROLE (Phase 1) + FL_TLS, FL_CA_CERT (Phase 2)
- Security section (lines 604-614): Explicitly names ca.crt only, NEVER ca.key/server.key/server.pem. Anti-pattern warning against glob patterns

**Verified Content (Retrieval):**
- jq extraction paths (lines 39-55):
  - FL_TLS: `.SERVICE.roles[] | select(.name == "superlink") | .nodes[0].vm_info.VM.USER_TEMPLATE.FL_TLS`
  - FL_CA_CERT: same path with `.FL_CA_CERT`
- Retrieval logic (lines 60-79): IF FL_TLS=YES -> IF FL_CA_CERT non-empty -> decode with `base64 -d` -> write to /opt/flower/certs/ca.crt -> chown 49999:49999, chmod 0644
- FATAL error if FL_TLS=YES but FL_CA_CERT missing (prevents silent security downgrade)
- retrieve_ca_cert() function specification (lines 83-124)

**Assessment:** WIRED - Not just specification of attributes, but complete implementation specification including exact jq paths, decode commands, error handling, and security anti-patterns.

### Truth 3: End-to-End TLS Handshake Path

**Spec Location:** `spec/05-supernode-tls-trust.md`, Section 8 (lines 521-683)

**Verified Content:**
- 9-step walkthrough covering entire lifecycle:
  1. SuperLink boots with FL_TLS_ENABLED=YES
  2. Certificate generation (references spec 04 Section 3 steps)
  3. SuperLink container start with TLS flags (--ssl-ca-certfile, --ssl-certfile, --ssl-keyfile)
  4. OneGate publication (FL_READY, FL_ENDPOINT, FL_TLS, FL_CA_CERT)
  5. SuperNode discovery via OneGate, extraction of FL_TLS=YES and FL_CA_CERT, decode to ca.crt
  6. SuperNode CA cert validation (openssl x509 -in ca.crt -noout)
  7. SuperNode container start with --root-certificates ca.crt
  8. gRPC TLS handshake: ClientHello -> ServerHello+server.pem -> verification (chain, SAN, expiry) -> key exchange -> success
  9. Encrypted gRPC channel with TLS 1.2+, model weights/gradients/control encrypted
- ASCII sequence diagram (lines 632-681) showing temporal flow across SuperLink VM, OneGate, and SuperNode VM with arrows indicating data flow
- SAN mismatch failure case documented (lines 629-630)

**Assessment:** COMPLETE - A reader can trace every step from VM boot through encrypted communication. Not a high-level overview but a detailed technical walkthrough with specific artifacts at each stage.

### Truth 4: Dual Provisioning Model

**Spec Location:** `spec/04-tls-certificate-lifecycle.md`, Section 4 (lines 260-357)

**Verified Content:**
- Decision flowchart (lines 264-283): FL_TLS_ENABLED check -> YES -> FL_SSL_CA_CERTFILE check -> YES (operator path) or NO (auto-gen path)
- Auto-generation trigger (lines 285-291): FL_TLS_ENABLED=YES AND FL_SSL_CA_CERTFILE empty -> run generate-certs.sh
- Operator-provided trigger (lines 293-295): FL_TLS_ENABLED=YES AND FL_SSL_CA_CERTFILE set -> decode all three FL_SSL_* vars (all-or-none rule)
- decode_context_certs() function spec (lines 299-323): base64 decode for CA cert, server cert, server key -> set ownership/permissions
- Post-decode validation (lines 326-347): openssl x509/rsa validation, chain verification with `openssl verify -CAfile ca.crt server.pem`
- Use cases for operator-provided certs (lines 349-353): PKI infrastructure, longer validity, trusted CA, compliance

**Assessment:** DECISION LOGIC SPECIFIED - Not just "there are two paths" but complete flowchart, trigger conditions, validation rules, and failure modes for each path.

### Truth 5: Boot Sequence Modifications

**Spec Location:**
- SuperLink: `spec/04-tls-certificate-lifecycle.md`, Section 5 (lines 359-451)
- SuperNode: `spec/05-supernode-tls-trust.md`, Section 6 (lines 344-433)

**Verified Content (SuperLink):**
- NEW Step 7a specification (lines 363-395): Complete pseudocode for TLS certificate setup inserted between Phase 1 steps 7 and 8
- UPDATED Step 8 (lines 397-416): Systemd unit and Docker run command conditionally modified based on TLS_MODE flag
- UPDATED Step 12 (lines 418-438): OneGate publication extended with FL_TLS and FL_CA_CERT attributes
- Boot sequence diagram (lines 440-449) showing Step 7a insertion

**Verified Content (SuperNode):**
- Step 7 UPDATED (lines 348-377): Discovery extended with TLS detection, retrieve_ca_cert() call if FL_TLS=YES, TLS mode determination
- NEW Step 7b specification (lines 379-397): CA cert validation with openssl, FATAL on failure, FL_NODE_READY=NO publication
- Step 10 UPDATED (lines 401-418): Container start conditionally adds `-v /opt/flower/certs/ca.crt:/app/ca.crt:ro` and `--root-certificates ca.crt`
- Updated boot sequence summary (lines 420-431): 13-step Phase 1 sequence becomes 14 steps (+ Step 7b)

**Assessment:** DELTA SPECIFICATION - Not a rewrite of Phase 1 but precise identification of which steps change, what gets inserted, and how each modified step behaves. Uses NEW/UPDATED markers consistently.

---

## Substantive Checks

### Line Count Analysis

| File | Lines | Assessment |
|------|-------|------------|
| spec/04-tls-certificate-lifecycle.md | 770 | Substantive (far exceeds 15-line minimum for spec documents) |
| spec/05-supernode-tls-trust.md | 835 | Substantive (far exceeds 15-line minimum for spec documents) |

### Stub Pattern Analysis

Grep for "TODO|FIXME|placeholder|not implemented|coming soon|TBD" found only:
- References to "Phase 1 placeholders" (historical context, stating these were placeholders in Phase 1 but are NOW fully specified in Phase 2)
- No actual TODOs, FIXMEs, or incomplete sections detected

### Export/Content Verification

Both files are markdown specification documents, not code. Content verification:
- Spec 04 has 10 numbered sections + 1 appendix (11 major sections total) - MATCHES plan requirement
- Spec 05 has 11 numbered sections + 1 appendix (12 major sections total) - MATCHES plan requirement
- Both specs contain code blocks with executable commands (OpenSSL, bash, curl)
- Both specs contain tables, diagrams, decision flowcharts
- Both specs contain USER_INPUT definitions matching spec 03 format

---

## Cross-References and Wiring

### Spec 04 -> Other Specs

| Target | Reference Location | Purpose | Status |
|--------|-------------------|---------|--------|
| spec/01-superlink-appliance.md | Lines 361, 550, 760 | Boot sequence modification, OneGate extension | ✓ WIRED |
| spec/03-contextualization-reference.md | Lines 635, 762 | Variable definitions | ✓ WIRED |
| spec/02-supernode-appliance.md | Line 761 | SuperNode retrieval reference | ✓ WIRED |

### Spec 05 -> Other Specs

| Target | Reference Location | Purpose | Status |
|--------|-------------------|---------|--------|
| spec/04-tls-certificate-lifecycle.md | Lines 11, 26, 36, 529, 827 | Consumption of OneGate attributes, generation reference | ✓ WIRED |
| spec/02-supernode-appliance.md | Lines 32, 346, 687, 825 | Boot sequence modification | ✓ WIRED |
| spec/03-contextualization-reference.md | Lines 687, 826 | Variable definitions | ✓ WIRED |

### Integration into Spec Overview

Grep verification:
- Line 77 of spec/00-overview.md describes TLS mode with references to both specs
- Lines 109-110 include Phase 2 section table entries with APPL-04 mapping
- Navigation structure updated to include Phase 2 sections

---

## Must-Haves from Plan Frontmatter

### Plan 02-01 Must-Haves

**Truths (from plan frontmatter):**
1. ✓ "A reader can identify the exact certificate generation sequence" - VERIFIED (Section 3, 8-step OpenSSL sequence)
2. ✓ "A reader can identify file paths, ownership (UID 49999), and permissions" - VERIFIED (Section 2 table, Section 3 Step 7)
3. ✓ "A reader can determine how SuperLink publishes CA to OneGate" - VERIFIED (Section 7, base64-encoded FL_CA_CERT)
4. ✓ "A reader can follow both provisioning paths" - VERIFIED (Section 4 flowchart, auto-gen vs operator)
5. ✓ "A reader can see updated Docker run command with --ssl-* flags" - VERIFIED (Section 6, Phase 1 vs Phase 2 side-by-side)

**Artifacts:**
- ✓ spec/04-tls-certificate-lifecycle.md exists (770 lines)
- ✓ Contains "Certificate Generation Sequence" section (Section 3)

**Key Links:**
- ✓ spec/04 -> spec/01 via boot sequence references (grep confirms "Step 7a.*TLS")
- ✓ spec/04 -> spec/03 via FL_TLS_ENABLED and other variables (grep confirms "FL_TLS_ENABLED")

### Plan 02-02 Must-Haves

**Truths (from plan frontmatter):**
1. ✓ "A reader can trace complete path: boot -> discovery -> retrieval -> decode -> container start -> handshake" - VERIFIED (Section 8, 9-step walkthrough)
2. ✓ "A reader can identify both CA acquisition paths" - VERIFIED (Section 2 OneGate, Section 3 static)
3. ✓ "A reader can follow end-to-end TLS handshake" - VERIFIED (Section 8, ClientHello through encrypted channel)
4. ✓ "A reader can see updated Docker run with --root-certificates" - VERIFIED (Section 7, Phase 1 vs Phase 2)
5. ✓ "A reader can deploy TLS cluster using only the spec" - VERIFIED (complete deployment path documented)

**Artifacts:**
- ✓ spec/05-supernode-tls-trust.md exists (835 lines)
- ✓ Contains "End-to-End TLS Handshake" section (Section 8)

**Key Links:**
- ✓ spec/05 -> spec/04 via FL_CA_CERT reference (grep confirms "FL_CA_CERT")
- ✓ spec/05 -> spec/02 via boot sequence references (grep confirms "Step 7.*discovery.*UPDATED")
- ✓ spec/05 -> spec/03 via FL_TLS_ENABLED (grep confirms "FL_TLS_ENABLED")

---

## Phase Success Criteria (from ROADMAP.md)

| Criterion | Status | Evidence |
|-----------|--------|----------|
| 1. The spec defines the exact certificate generation sequence (CA creation, server cert signing, file paths, and ownership set to UID 49999) | ✓ ACHIEVED | Spec 04 Section 3 contains 8-step OpenSSL sequence with CA key/cert generation, server key/CSR/cert, ownership commands (49999:49999 for container-accessible files, root:root 0600 for ca.key), file paths in /opt/flower/certs/ |
| 2. The spec defines how the SuperLink publishes its CA certificate to OneGate and how SuperNodes retrieve and trust it | ✓ ACHIEVED | Spec 04 Section 7: OneGate PUT with FL_TLS=YES and FL_CA_CERT=(base64 ca.crt). Spec 05 Section 2: jq extraction, base64 decode, file write with correct ownership |
| 3. A reader can trace the complete TLS handshake path from SuperNode boot through certificate retrieval to authenticated gRPC connection | ✓ ACHIEVED | Spec 05 Section 8 provides 9-step walkthrough with ASCII sequence diagram showing SuperLink boot -> cert gen -> OneGate publish -> SuperNode discovery -> retrieval -> validation -> container start -> TLS handshake -> encrypted channel |

**All 3 success criteria ACHIEVED.**

---

## Requirement APPL-04 Coverage

**Requirement:** "Spec defines TLS certificate automation — generation on server boot, distribution to clients via OneGate, correct file ownership for Flower containers (UID 49999)"

**Coverage:**
- ✓ Generation on server boot: Spec 04 Section 3 (8-step sequence), Section 5 (Step 7a boot insertion)
- ✓ Distribution via OneGate: Spec 04 Section 7 (publication), Spec 05 Section 2 (retrieval)
- ✓ Correct file ownership UID 49999: Spec 04 Section 2 (permissions table), Section 3 Step 7 (chown commands)
- ✓ Trust chain model: Spec 04 Section 1 (trust chain diagram), Spec 05 Section 8 (end-to-end handshake)

**Requirement Status:** SATISFIED

---

## Verification Conclusion

**Phase 2: Security and Certificate Automation** has **PASSED** verification.

**Summary:**
- All 5 observable truths verified with substantive evidence
- Both required artifacts exist (770 and 835 lines) with complete, non-stub content
- All key links wired (cross-references, boot sequence modifications, variable definitions)
- All 3 phase success criteria from ROADMAP.md achieved
- Requirement APPL-04 fully satisfied (both SuperLink and SuperNode sides specified)
- No anti-patterns, TODOs, or incomplete sections detected
- Phase 1 integration maintained (delta specifications, not rewrites)

**Phase Goal Achievement:** The spec fully defines the TLS certificate lifecycle including generation on server boot (8-step OpenSSL sequence), automated distribution to clients via OneGate (FL_TLS and FL_CA_CERT attributes with jq extraction paths), correct file permissions for Flower containers (UID 49999 for container-accessible files, root:root 0600 for CA key), and the trust chain model (self-signed CA -> server cert with VM IP SAN -> OneGate distribution -> SuperNode retrieval -> TLS handshake verification).

**Next Steps:** Phase 2 is complete. Ready to proceed to Phase 3 (ML Framework Variants and Use Cases) or Phase 4 (Single-Site Orchestration) as both depend only on Phase 1.

---

_Verified: 2026-02-07T19:15:00Z_
_Verifier: Claude (gsd-verifier)_
_Verification Mode: Initial (no previous VERIFICATION.md)_
