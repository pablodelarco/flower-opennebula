---
phase: 04-single-site-orchestration
verified: 2026-02-07T23:30:00Z
status: passed
score: 11/11 must-haves verified
re_verification: false
---

# Phase 4: Single-Site Orchestration Verification Report

**Phase Goal:** The spec defines the OneFlow service template that deploys a complete Flower cluster (1 SuperLink + N SuperNodes) with automatic dependency ordering, OneGate service discovery, and configurable cardinality

**Verified:** 2026-02-07T23:30:00Z
**Status:** PASSED
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

All truths from both plans (04-01 and 04-02) verified against actual spec content.

#### Plan 04-01 Truths (Service Template Definition)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The spec includes a complete OneFlow service template JSON with superlink parent role (cardinality 1) and supernode child role (cardinality N) | ✓ VERIFIED | Section 3 lines 135-201: Complete JSON with both roles defined. SuperLink role at line 149-174, SuperNode role at line 175-200. SuperLink cardinality: 1 (line 153), SuperNode cardinality: 2 (line 179). |
| 2 | The spec defines straight deployment ordering with ready_status_gate: true | ✓ VERIFIED | Line 138: `"deployment": "straight"`, Line 139: `"ready_status_gate": true`. Line 212-213 explains straight deployment: "Roles deploy sequentially in array order. SuperLink (index 0) deploys first; SuperNode (index 1) deploys after SuperLink is ready." |
| 3 | The spec maps service-level user_inputs (shared: FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL) and role-level user_inputs (SuperLink: strategy/rounds, SuperNode: framework/use-case) | ✓ VERIFIED | Service-level user_inputs lines 142-146: FLOWER_VERSION, FL_TLS_ENABLED, FL_LOG_LEVEL. SuperLink role user_inputs lines 158-164: FL_NUM_ROUNDS, FL_STRATEGY, FL_MIN_FIT_CLIENTS, FL_MIN_EVALUATE_CLIENTS, FL_MIN_AVAILABLE_CLIENTS. SuperNode role user_inputs lines 185-189: ML_FRAMEWORK, FL_USE_CASE, FL_NODE_CONFIG. Section 2 (lines 71-114) explains the three-level hierarchy and why each variable is at its level. |
| 4 | The spec defines SuperLink cardinality hard-constrained to 1 (min_vms:1, max_vms:1) and SuperNode default cardinality 2, min 2, max 10 | ✓ VERIFIED | SuperLink: line 154 `"min_vms": 1`, line 155 `"max_vms": 1`. SuperNode: line 179 `"cardinality": 2`, line 180 `"min_vms": 2`, line 181 `"max_vms": 10`. Section 4 (lines 268-329) explains the singleton constraint rationale and cardinality ranges. |
| 5 | The spec defines per-SuperNode FL_NODE_CONFIG differentiation via VM index for partition-id assignment | ✓ VERIFIED | Section 5 (lines 332-408) titled "Per-SuperNode Differentiation (FL_NODE_CONFIG)". Lines 342-350 explain the mechanism. Lines 358-382 provide pseudocode for auto-computing partition-id from OneGate service response using VM's 0-based index in the nodes array. |

#### Plan 04-02 Truths (Deployment Sequence and Lifecycle)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 6 | The spec defines the end-to-end deployment sequence from user clicking Deploy to service reaching RUNNING state | ✓ VERIFIED | Section 6 (lines 411-548) titled "Deployment Sequence" provides 12-step walkthrough from instantiation (line 417) to service RUNNING (line 511). Includes timing diagram lines 515-543 with approximate timestamps for each stage. |
| 7 | The spec explains how ready_status_gate: true gates SuperNode deployment on SuperLink application-level readiness (resolving Open Question #1 from overview) | ✓ VERIFIED | Step 6 of deployment sequence (lines 469-473) titled "ready_status_gate satisfied -- SuperLink role becomes RUNNING (CRITICAL)". Line 471: "OneFlow's definition of 'running' requires BOTH the hypervisor reporting the VM as running AND the VM's user template containing READY=YES." Line 473: "The ready_status_gate ensures this transition happens only after the SuperLink application is genuinely ready to accept connections." Overview updated at line 207 with resolution: "Resolved: YES ... See spec/08-single-site-orchestration.md Section 6." |
| 8 | The spec defines the OneGate coordination protocol in the context of a OneFlow service, tying together SuperLink publication and SuperNode discovery from Phases 1-2 | ✓ VERIFIED | Section 7 (lines 551-738) titled "OneGate Coordination Protocol (Service Context)". Lines 557-582 show data flow diagram. Lines 587-609 explain SuperLink publication (FL_READY, FL_ENDPOINT, FL_TLS, FL_CA_CERT) with timing relative to ready_status_gate. Lines 611-698 explain SuperNode discovery with jq filter examples and OneGate /service response structure. |
| 9 | A reader can understand what happens at each stage when deploying a 1+N Flower cluster | ✓ VERIFIED | Section 6 provides step-by-step walkthrough with 12 numbered steps (lines 417-511) covering: user instantiation, SuperLink VM creation, SuperLink boot sequence, OneGate publication, ready_status_gate satisfaction, SuperNode VM creation, SuperNode boot and discovery, and service RUNNING. Timing diagram (lines 515-543) shows temporal flow with approximate timestamps. |
| 10 | The spec defines scaling operations (scale up, scale down) and service lifecycle commands (deploy, undeploy, shutdown) | ✓ VERIFIED | Section 8 (lines 740-833) "Scaling Operations": scale up (lines 746-763), scale down (lines 769-787), SuperLink cannot be scaled (lines 790-798). Section 9 (lines 836-952) "Service Lifecycle Management": service states (lines 842-861), deploy commands (lines 863-882), show status (885-890), undeploy with reverse ordering (lines 892-904), shutdown action (lines 907-915), failure handling (lines 917-952). |
| 11 | The spec defines cardinality configuration and how it maps to OneFlow scaling | ✓ VERIFIED | Section 4 (lines 268-329) "Cardinality Configuration" explains SuperLink singleton (lines 270-286), SuperNode elastic range (lines 288-304), interaction with FL_MIN_AVAILABLE_CLIENTS (lines 299-304), cardinality override at instantiation (lines 306-316), and summary table (lines 318-329). Section 8 references these constraints in scaling operations (lines 748-798). |

**Score:** 11/11 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `spec/08-single-site-orchestration.md` | OneFlow service template definition with roles, user_inputs, cardinality, deployment sequence, coordination protocol, scaling, lifecycle | ✓ VERIFIED | File exists (974 lines). Contains all 10 sections: (1) Purpose and Scope, (2) Service Template Architecture, (3) Complete Service Template JSON, (4) Cardinality Configuration, (5) Per-SuperNode Differentiation, (6) Deployment Sequence, (7) OneGate Coordination Protocol, (8) Scaling Operations, (9) Service Lifecycle Management, (10) Anti-Patterns and Pitfalls. Spec footer present at lines 970-974. |
| `spec/00-overview.md` | Updated overview with Phase 4 section reference and resolved Open Question #1 | ✓ VERIFIED | File updated. Line 123: Phase 4 entry in Spec Sections table. Line 207: Open Question #1 marked "Resolved: YES" with reference to spec/08 Section 6. Header updated to include Phase 4 (line 4). Version 1.2 (line 245). |

### Key Link Verification

All key links verified by checking cross-references in the spec.

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| spec/08 | spec/01 | SuperLink role references SuperLink appliance VM template | ✓ WIRED | Line 27: Cross-reference to `spec/01-superlink-appliance.md`. Line 440: References SuperLink boot sequence Section 6. Line 587: References SuperLink publication Section 10. Multiple references throughout deployment sequence. |
| spec/08 | spec/02 | SuperNode role references SuperNode appliance VM template | ✓ WIRED | Line 28: Cross-reference to `spec/02-supernode-appliance.md`. Line 342: References SuperNode boot sequence Section 7. Line 495: References discovery model Section 6c-6d. Multiple references in deployment sequence and coordination protocol. |
| spec/08 | spec/03 | User_inputs reference contextualization variable definitions | ✓ WIRED | Line 29: Cross-reference to `spec/03-contextualization-reference.md`. Service template JSON uses USER_INPUT format defined in spec/03. |
| spec/08 | spec/04 | TLS publication contract | ✓ WIRED | Line 30: Cross-reference to `spec/04-tls-certificate-lifecycle.md`. Line 446: References TLS certificate setup Step 7a. Line 587: References TLS publication in Section 7. |
| spec/08 | spec/05 | SuperNode TLS trust | ✓ WIRED | Line 31: Cross-reference to `spec/05-supernode-tls-trust.md`. Line 488: References TLS mode detection Step 7b. |
| spec/08 | spec/06 | ML_FRAMEWORK variable | ✓ WIRED | Line 32: Cross-reference to `spec/06-ml-framework-variants.md`. Line 186: ML_FRAMEWORK in SuperNode user_inputs. |
| spec/08 | spec/07 | FL_USE_CASE variable | ✓ WIRED | Line 33: Cross-reference to `spec/07-use-case-templates.md`. Line 187: FL_USE_CASE in SuperNode user_inputs. Line 407: References use case templates in FL_NODE_CONFIG scope. |
| spec/00 | spec/08 | Phase 4 section reference | ✓ WIRED | Line 123: Table entry linking to `spec/08-single-site-orchestration.md` with summary. |

### Requirements Coverage

| Requirement | Status | Evidence |
|-------------|--------|----------|
| ORCH-01: Spec defines OneFlow service template with SuperLink parent role and SuperNode child roles, "straight" deployment ordering, and cardinality configuration | ✓ SATISFIED | Complete service template JSON in Section 3 with both roles, straight deployment (line 138), ready_status_gate (line 139), SuperLink singleton constraint (lines 154-155), SuperNode elastic range (lines 179-181), parents dependency (line 182). |

### Anti-Patterns Found

Section 10 (lines 954-968) documents 8 anti-patterns with severity and mitigation. All are informational (prevent user errors), none are blockers in the spec itself.

| Pattern | Severity | Impact |
|---------|----------|--------|
| Setting ready_status_gate: false | ⚠️ Warning | Deployment race condition, wasted retry time |
| SuperLink cardinality > 1 | ⚠️ Warning | Split-brain federation |
| Duplicating user_inputs at both levels | ⚠️ Warning | Version mismatch risk |
| Missing TOKEN=YES | 🛑 Blocker (for deployment) | All OneGate calls fail |
| Putting infrastructure vars in user_inputs | ℹ️ Info | User confusion |
| Setting FL_SUPERLINK_ADDRESS in OneFlow | ⚠️ Warning | Bypasses orchestration |
| Elasticity policies on superlink | ⚠️ Warning | Auto-scaling singleton |
| Using deployment: "none" | ⚠️ Warning | Race condition |

All anti-patterns are user-facing configuration mistakes, not spec defects. The spec correctly documents how to avoid them.

### Human Verification Required

None. All verification can be performed programmatically by checking spec content against must-haves.

## Gaps Summary

No gaps found. All must-haves verified, all artifacts substantive and wired, all success criteria met.

---

## Detailed Verification Evidence

### Artifact Level Verification

**spec/08-single-site-orchestration.md**

- **Level 1 (Exists):** ✓ File exists at expected path
- **Level 2 (Substantive):** ✓ 974 lines, comprehensive content
  - No TODO/FIXME/placeholder patterns found
  - Complete service template JSON (Section 3)
  - Detailed deployment sequence (Section 6)
  - Comprehensive coordination protocol (Section 7)
  - Full scaling and lifecycle coverage (Sections 8-9)
  - Anti-patterns section (Section 10)
- **Level 3 (Wired):** ✓ Cross-referenced from spec/00-overview.md line 123
  - References to spec/01, spec/02, spec/03, spec/04, spec/05, spec/06, spec/07
  - All cross-references validated

**spec/00-overview.md**

- **Level 1 (Exists):** ✓ File exists
- **Level 2 (Substantive):** ✓ Updated with Phase 4 content
  - Phase 4 section added to table (line 123)
  - Open Question #1 resolved (line 207)
  - Version bumped to 1.2 (line 245)
- **Level 3 (Wired):** ✓ Links to spec/08-single-site-orchestration.md

### Success Criteria Verification

All 4 success criteria from ROADMAP.md verified:

1. **✓ The spec includes a complete OneFlow service template (or template skeleton) with SuperLink parent role, SuperNode child roles, and "straight" deployment ordering**
   - Evidence: Section 3, lines 135-201, complete JSON template
   - SuperLink role: lines 149-174, no parents (root role)
   - SuperNode role: lines 175-200, parents: ["superlink"] (line 182)
   - deployment: "straight" (line 138)

2. **✓ The spec defines the OneGate coordination protocol -- SuperLink readiness signaling, endpoint advertisement, and SuperNode discovery polling with backoff**
   - Evidence: Section 7, lines 551-738
   - SuperLink publication: lines 587-609 (FL_READY, FL_ENDPOINT, FL_TLS, FL_CA_CERT)
   - SuperNode discovery: lines 611-698 (GET /service, jq filter, retry loop)
   - ready_status_gate timing: lines 600-608

3. **✓ A reader can understand how to deploy a 1+N Flower cluster from the marketplace and what happens at each stage of the deployment sequence**
   - Evidence: Section 6, lines 411-548, 12-step deployment walkthrough
   - Each step numbered and explained with approximate timing
   - Timeline diagram: lines 515-543
   - Critical gate explanation: lines 469-473

4. **✓ The spec defines cardinality configuration (min, max, default SuperNode count) and how it maps to OneFlow scaling**
   - Evidence: Section 4, lines 268-329, cardinality configuration
   - SuperLink singleton: lines 270-286 (min:1, max:1, rationale)
   - SuperNode elastic: lines 288-304 (default:2, min:2, max:10)
   - Scaling operations: Section 8, lines 740-833

---

**Verification Complete**

All must-haves verified. Phase goal achieved. No gaps found. Ready to proceed to Phase 5.

---

_Verified: 2026-02-07T23:30:00Z_
_Verifier: Claude (gsd-verifier)_
