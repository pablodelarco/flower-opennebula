---
phase: 07-multi-site-federation
verified: 2026-02-09T10:29:17Z
status: passed
score: 8/8 must-haves verified
re_verification: false
---

# Phase 7: Multi-Site Federation Verification Report

**Phase Goal:** The spec defines how to deploy a Flower federation across multiple OpenNebula zones with cross-zone networking, certificate trust, and gRPC connection resilience

**Verified:** 2026-02-09T10:29:17Z
**Status:** passed
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A reader can identify the 3-zone reference topology: SuperLink in Zone A, SuperNodes in Zones B/C, with per-zone OneFlow services | ✓ VERIFIED | Section 2 of spec/12 contains complete ASCII diagram showing Zone A (Coordinator), Zone B (Training Site 1), Zone C (Training Site 2), with per-zone OneFlow services clearly labeled. Zone roles documented in subsection with SuperLink singleton in Zone A, SuperNode VMs in Zones B/C. |
| 2 | A reader can choose between WireGuard VPN and direct public IP for cross-zone networking, understanding trade-offs of each | ✓ VERIFIED | Section 4 covers WireGuard with gateway placement options, configuration templates, MTU, firewall rules. Section 5 covers direct public IP with TLS SAN handling. Section 6 provides complete "Selection Criteria" decision matrix with 7 criteria rows (security, infrastructure, TLS cert management, number of zones, firewall policy, operational complexity, recommended for). |
| 3 | A reader knows the recommended gRPC keepalive values (60s time, 20s timeout) and why they are needed for WAN paths | ✓ VERIFIED | Section 7 "gRPC Keepalive Configuration" documents keepalive_time=60s, keepalive_timeout=20s with rationale table showing enterprise firewalls (60-600s timeout), Azure (240s), AWS (350s). Client-side and server-side gRPC options tables include grpc.keepalive_time_ms=60000 and grpc.keepalive_timeout_ms=20000. |
| 4 | A reader understands that OneGate is zone-local and FL_SUPERLINK_ADDRESS + FL_SSL_CA_CERTFILE become mandatory cross-zone | ✓ VERIFIED | Section 1 states "Critical architectural constraint: OneGate and OneFlow are zone-local services." Section 2.3 "Key Architectural Constraints" table lists constraint #2 "OneGate is zone-local" with implication "auto-discovery path does not work cross-zone. Static configuration required." Section 3.2 training site template shows FL_SUPERLINK_ADDRESS and FL_SSL_CA_CERTFILE both marked "M|text" and "M|text64" (mandatory). |
| 5 | A reader can plan a 3-zone federation deployment using only this spec section (end-to-end walkthrough) | ✓ VERIFIED | Section 9 "3-Zone Deployment Walkthrough" provides complete procedure: Prerequisites (5 items), Phase 1 (Steps 1-5: deploy coordinator, extract CA cert), Phase 2 (Steps 6-7: configure training sites), Phase 3 (Steps 8-9: deploy training sites), Phase 4 (Steps 10-12: verify federation). Includes deployment timeline diagram and verification commands summary table. |
| 6 | FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, and FL_CERT_EXTRA_SAN appear in the contextualization reference with complete definitions | ✓ VERIFIED | spec/03-contextualization-reference.md contains FL_GRPC_KEEPALIVE_TIME (29 occurrences), FL_GRPC_KEEPALIVE_TIMEOUT (appears in both SuperLink table row #21 and SuperNode table row #12), FL_CERT_EXTRA_SAN (16 occurrences, SuperLink table row #22). Version updated to 1.3. Total variable count updated to 42. |
| 7 | The single-site orchestration spec references multi-site federation and directs readers to spec/12 | ✓ VERIFIED | spec/08-single-site-orchestration.md contains 3 references to spec/12-multi-site-federation.md: (1) Section 1 "What this section does NOT cover" links to spec/12, (2) Section 1 cross-references lists multi-site federation with link, (3) Section 10 Anti-Patterns table "Setting FL_SUPERLINK_ADDRESS" row references "cross-zone federation (see spec/12)". |
| 8 | The overview document lists Phase 7 multi-site federation in its scope | ✓ VERIFIED | spec/00-overview.md includes: (1) Header "Phases: ...07 - Multi-Site Federation", (2) "Requirements: ...ORCH-02", (3) "What this specification covers" lists "Multi-site federation: cross-zone deployment...", (4) Spec document table row for spec/12-multi-site-federation.md with ORCH-02, (5) Reading order mentions "For multi-site federation, read Phase 7 (12)". Version updated to 1.4. |

**Score:** 8/8 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| spec/12-multi-site-federation.md | Complete multi-site federation specification, min 400 lines, contains ORCH-02 | ✓ VERIFIED | File exists: 952 lines (exceeds 400 min). Contains requirement tag "**Requirement:** ORCH-02" in header and footer. All 12 sections present: Purpose/Scope, 3-Zone Topology, Per-Zone Templates (JSON), WireGuard, Direct Public IP, Selection Criteria, gRPC Keepalive, TLS Trust, Deployment Walkthrough, Failure Modes, Anti-Patterns, New Variables Summary. |
| spec/03-contextualization-reference.md | Updated with Phase 7 variables | ✓ VERIFIED | Contains FL_GRPC_KEEPALIVE_TIME (row #20-21 SuperLink, #11-12 SuperNode), FL_GRPC_KEEPALIVE_TIMEOUT (same rows), FL_CERT_EXTRA_SAN (row #22 SuperLink only). Validation rules present. USER_INPUT blocks updated. Version 1.3. Total count 42 variables. Phase 7 row in summary table: "Phase 7 gRPC keepalive/cert | 3 | Both/SuperLink". |
| spec/08-single-site-orchestration.md | Cross-reference to multi-site spec | ✓ VERIFIED | 3 cross-references to spec/12-multi-site-federation.md found via grep. Links appear in: (1) scope section "What this section does NOT cover", (2) cross-references list, (3) anti-patterns table for FL_SUPERLINK_ADDRESS. |
| spec/00-overview.md | Updated with Phase 7 scope | ✓ VERIFIED | Phase 7 appears in header phases list. ORCH-02 in requirements list. "Multi-site federation" in "What this specification covers". Spec document table has row for spec/12 with ORCH-02. Reading order mentions Phase 7. Version 1.4. |

**Artifact Status:** All 4 artifacts verified at all 3 levels (existence, substantive, wired)

### Key Link Verification

| From | To | Via | Status | Details |
|------|------|-----|--------|---------|
| spec/12-multi-site-federation.md | spec/04-tls-certificate-lifecycle.md | CA cert distribution extends Phase 2 static provisioning | ✓ WIRED | FL_SSL_CA_CERTFILE appears 19 times in spec/12. Section 8 "TLS Certificate Trust Across Zones" explicitly references "static FL_SSL_CA_CERTFILE path from Phase 2 (spec/05-supernode-tls-trust.md, Section 3) is the cross-zone mechanism." Cross-reference to spec/04 in Section 1. |
| spec/12-multi-site-federation.md | spec/08-single-site-orchestration.md | Per-zone templates derived from single-site template | ✓ WIRED | OneFlow appears 20 times in spec/12. Section 3 "Per-Zone OneFlow Service Templates" states "derived from the single-site template defined in spec/08-single-site-orchestration.md, Section 3." Section 3.3 comparison table shows differences from single-site template. |
| spec/12-multi-site-federation.md | spec/03-contextualization-reference.md | New CONTEXT variables for keepalive and SAN | ✓ WIRED | FL_GRPC_KEEPALIVE appears in spec/12 Section 7 with complete variable definitions. Section 12 states "added to the existing variable reference (spec/03-contextualization-reference.md)". Cross-reference to spec/03 in Section 1. |
| spec/03-contextualization-reference.md | spec/12-multi-site-federation.md | Phase 7 variable definitions reference multi-site spec | ✓ WIRED | grep "spec/12-multi-site-federation" in spec/03 returns references. Variable rows for FL_GRPC_KEEPALIVE_TIME and FL_CERT_EXTRA_SAN include cross-references to spec/12 sections in their descriptions and interaction notes. |
| spec/08-single-site-orchestration.md | spec/12-multi-site-federation.md | Anti-patterns section references multi-site for cross-zone | ✓ WIRED | grep "Phase 7" in spec/08 returns anti-pattern reference. "Setting FL_SUPERLINK_ADDRESS in OneFlow deployment" anti-pattern row states "Static addresses are intended for standalone VM deployments or cross-zone federation (see spec/12-multi-site-federation.md)". |

**Key Links Status:** All 5 key links verified as WIRED

### Requirements Coverage

| Requirement | Status | Supporting Truths |
|-------------|--------|-------------------|
| ORCH-02: Spec defines multi-site federation architecture -- SuperLink in Zone A, SuperNodes across Zones B/C, cross-zone networking (VPN/overlay), certificate trust distribution | ✓ SATISFIED | Supported by truths #1 (topology), #2 (networking options), #3 (keepalive), #4 (cert trust). All supporting truths VERIFIED. Requirement tag present in spec/12 header and footer. |

**Requirements Status:** 1/1 requirement satisfied

### Anti-Patterns Found

No blocker anti-patterns found. The spec documents anti-patterns (Section 11) but the spec itself contains no TODO/FIXME/placeholder stub patterns (grep returned only "Phase 2+ placeholders" in a table describing existing Phase 2 variables).

**Anti-Pattern Scan:** Clean - no stubs, no placeholders, no empty implementations

### Human Verification Required

None. All success criteria are verifiable through spec content inspection. The spec is documentation, not executable code, so functional testing is not applicable.

### Verification Details by Success Criterion

**SC1: Multi-site deployment topology defined**
- ✓ Section 2 "3-Zone Reference Deployment Topology" with ASCII diagram
- ✓ Zone A: SuperLink VM, OneFlow Service A (superlink role, singleton)
- ✓ Zone B: SuperNode VMs, OneFlow Service B (supernode role, no parents)
- ✓ Zone C: SuperNode VMs, OneFlow Service C (same pattern)
- ✓ Networking requirements listed: cross-zone connectivity layer, gRPC connections outbound from SuperNodes
- ✓ Five key architectural constraints documented in table (OneFlow zone-local, OneGate zone-local, FL_SUPERLINK_ADDRESS mandatory, FL_SSL_CA_CERTFILE mandatory, no parents dependency)

**SC2: At least two cross-zone networking options with trade-offs**
- ✓ Section 4: WireGuard site-to-site VPN (6 subsections: when to use, architecture, gateway placement options, configuration templates, infrastructure setup, key generation)
- ✓ Section 5: Direct Public IP (5 subsections: when to use, configuration, TLS SAN consideration with 3 resolution options, FL_CERT_EXTRA_SAN variable definition, trade-offs table)
- ✓ Section 6: Selection Criteria decision matrix with 7 criteria rows and recommendations

**SC3: gRPC keepalive configuration with specific values**
- ✓ Section 7 "gRPC Keepalive Configuration" (8 subsections)
- ✓ Recommended values: keepalive_time=60s, keepalive_timeout=20s, permit_without_calls=true
- ✓ Rationale: firewall idle timeout table showing 60-600s range, gRPC default 2h too long, Flower 210s insufficient
- ✓ Client-side options table: grpc.keepalive_time_ms=60000, grpc.keepalive_timeout_ms=20000
- ✓ Server-side options table: same values plus min_recv_ping_interval_without_data_ms=30000
- ✓ Coordination rule documented: client keepalive_time >= server min_recv_ping_interval

**SC4: TLS certificate trust across zones defined**
- ✓ Section 8 "TLS Certificate Trust Across Zones" (5 subsections)
- ✓ Problem stated: OneGate zone-local, auto-discovery doesn't work cross-zone, static FL_SSL_CA_CERTFILE path is the mechanism
- ✓ Self-signed CA workflow: 4 steps (deploy Zone A, extract CA cert via ssh + base64, configure training sites with FL_SSL_CA_CERTFILE, deploy Zones B/C)
- ✓ Enterprise PKI workflow: 4 steps (generate certs from CA with correct SANs, configure coordinator with operator-provided certs, configure training sites, deploy all zones)
- ✓ FL_CERT_EXTRA_SAN integration with WireGuard documented (add tunnel IP to SAN to avoid mismatch)
- ✓ Decision table: self-signed CA vs enterprise PKI with 6 criteria

**SC5: 3-zone deployment walkthrough**
- ✓ Section 9 "3-Zone Deployment Walkthrough" (6 subsections)
- ✓ Prerequisites: 5 items (zones federated, networking established, VM templates registered, OneFlow templates registered, WireGuard active if used)
- ✓ Phase 1: Deploy coordinator (Steps 1-5 with complete oneflow-template instantiate command, monitoring, verification, CA extraction, address notation)
- ✓ Phase 2: Configure training sites (Steps 6-7 with all required variables listed)
- ✓ Phase 3: Deploy training sites (Steps 8-9 with complete oneflow-template instantiate commands for both zones, parallel deployment noted)
- ✓ Phase 4: Verify federation (Steps 10-12 with docker logs checks, training run submission)
- ✓ Deployment timeline diagram (t=0s to t=165s with all boot sequences)
- ✓ Verification commands summary table (9 rows: service status, container logs, WireGuard, TLS cert SAN, OneGate readiness)

### Substantiveness Check

**Line count verification:**
- spec/12-multi-site-federation.md: 952 lines (target: 400+) ✓ 238% of minimum
- No thin files, no stub patterns

**Export/usage verification:**
- spec/12 is referenced by spec/03, spec/08, spec/00 ✓
- New variables (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN) are defined in spec/03 and used in spec/12 ✓
- All cross-references bidirectional ✓

**Content depth verification:**
- 12 major sections in spec/12 with subsections (average 79 lines/section)
- 2 complete OneFlow JSON templates (coordinator and training site)
- 2 WireGuard configuration templates
- 1 ASCII architecture diagram
- 6 tables (constraints, template comparison, gateway options, trade-offs, decision matrix, failure modes, anti-patterns, variables)
- 12-step deployment walkthrough with timeline
- Pseudocode for FL_CERT_EXTRA_SAN processing
- Bash commands for verification, WireGuard setup, CA extraction

**Conclusion:** All artifacts are substantive. No placeholder content.

---

## Overall Assessment

**Phase Goal Achievement:** ✓ COMPLETE

The spec fully defines multi-site Flower federation across OpenNebula zones with all required components:

1. **3-zone topology:** Section 2 provides complete reference architecture with ASCII diagram, zone roles, and 5 key architectural constraints.

2. **Cross-zone networking:** Two options fully specified (WireGuard in Section 4, direct public IP in Section 5) with trade-offs, selection criteria, and complete configuration procedures.

3. **gRPC keepalive:** Section 7 defines specific values (60s/20s), rationale (firewall idle timeouts), client/server options tables, and coordination rule.

4. **TLS certificate trust:** Section 8 defines both self-signed CA and enterprise PKI workflows, with FL_CERT_EXTRA_SAN for SAN mismatch resolution.

5. **3-zone deployment walkthrough:** Section 9 provides complete end-to-end procedure (12 steps across 4 phases) with commands, timeline, and verification table.

**Cross-cutting integration:** All 3 new variables (FL_GRPC_KEEPALIVE_TIME, FL_GRPC_KEEPALIVE_TIMEOUT, FL_CERT_EXTRA_SAN) are integrated into spec/03 with validation rules and interaction notes. spec/08 and spec/00 contain cross-references to spec/12. ORCH-02 requirement is tagged and satisfied.

**Readability:** A reader with OpenNebula and Flower knowledge can plan and execute a 3-zone federation deployment using only spec/12. All prerequisite knowledge is cross-referenced to earlier phase specs.

**No gaps found.** All must-haves verified. All success criteria satisfied.

---

_Verified: 2026-02-09T10:29:17Z_
_Verifier: Claude (gsd-verifier)_
