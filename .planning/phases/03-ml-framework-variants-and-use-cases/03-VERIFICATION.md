---
phase: 03-ml-framework-variants-and-use-cases
verified: 2026-02-07T21:00:00Z
status: passed
score: 10/10 must-haves verified
---

# Phase 3: ML Framework Variants and Use Cases Verification Report

**Phase Goal:** The spec defines appliance variant strategy (which ML frameworks get dedicated images, with size targets) and provides at least three pre-built use case templates deployable purely through contextualization

**Verified:** 2026-02-07T21:00:00Z
**Status:** PASSED
**Re-verification:** No - initial verification

## Goal Achievement

### Observable Truths

#### Plan 03-01: ML Framework Variant Strategy

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The spec defines exactly three appliance variants (PyTorch, TensorFlow, scikit-learn) with distinct Docker images extending flwr/supernode | ✓ VERIFIED | Section 2 defines variant table with three variants. Each has distinct image name pattern `flower-supernode-{framework}:{FLOWER_VERSION}`. All Dockerfiles start with `FROM flwr/supernode:1.25.0` (lines 60, 111, 147) |
| 2 | Each variant has a documented image size target and the packages it installs | ✓ VERIFIED | Section 2 table includes "Est. Docker image size" and "Est. QCOW2 size" for all three variants. Section 3 provides complete package breakdown tables for each variant with size impact per package |
| 3 | The spec includes a decision record explaining why multiple variants over a single fat image, and why these three frameworks | ✓ VERIFIED | Section 7 contains three formal decision records: DR-01 (why variants vs fat image), DR-02 (why these three frameworks), DR-03 (why LLM deps in PyTorch) with arguments table and status |
| 4 | The ML_FRAMEWORK contextualization variable selects which variant Docker image the SuperNode runs | ✓ VERIFIED | Section 5 defines ML_FRAMEWORK variable with USER_INPUT format and valid values (pytorch, tensorflow, sklearn). Default is "pytorch" |
| 5 | The spec defines how configure.sh uses ML_FRAMEWORK to select the correct Docker image tag at boot | ✓ VERIFIED | Section 5.2 provides complete case statement (lines 227-234) showing IMAGE_TAG selection based on ML_FRAMEWORK value. Includes error handling for unknown values |

**Score:** 5/5 truths verified for Plan 03-01

#### Plan 03-02: Pre-Built Use Case Templates

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | The spec defines three pre-built use case templates: image classification (PyTorch+ResNet/CNN+CIFAR-10), anomaly detection (scikit-learn+LogisticRegression+tabular), LLM fine-tuning (PyTorch+PEFT/LoRA) | ✓ VERIFIED | Section 4 (image-classification with SimpleCNN on CIFAR-10), Section 5 (anomaly-detection with LogisticRegression on iris/tabular), Section 6 (llm-fine-tuning with LoRA/PEFT on OpenLLaMA). All three fully specified |
| 2 | Each use case template specifies its required contextualization parameters and expected outputs | ✓ VERIFIED | Each use case section includes "Contextualization Parameters for Deployment" subsection with complete variable settings and "Expected Outputs" subsection with metrics table |
| 3 | A reader can deploy any use case by setting only FL_USE_CASE and ML_FRAMEWORK plus standard FL_* variables -- no SSH, no code changes | ✓ VERIFIED | Section 1 states key constraint explicitly. Each use case shows contextualization-only deployment with FL_USE_CASE, ML_FRAMEWORK, FL_NODE_CONFIG, FL_NUM_ROUNDS, FL_STRATEGY. Client code is pre-installed in FABs |
| 4 | A framework/use-case compatibility matrix prevents invalid combinations at boot | ✓ VERIFIED | Section 3 provides compatibility table and complete validation pseudocode (lines 92-132) with boot-time failure on incompatible combinations and clear error messages |
| 5 | The spec defines how use case FABs are pre-installed in Docker images and activated at runtime | ✓ VERIFIED | Section 7 defines build pipeline and Dockerfile addition pattern with `COPY .fab + flwr install` commands. Section 8 defines runtime activation flow with configure.sh logic |

**Score:** 5/5 truths verified for Plan 03-02

### Combined Phase Score: 10/10 Must-Haves Verified

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `spec/06-ml-framework-variants.md` | Complete appliance variant strategy specification (APPL-05) | ✓ VERIFIED | Exists, 487 lines, contains all 8 required sections including Dockerfiles, size targets, decision records |
| `spec/07-use-case-templates.md` | Complete use case template specification (ML-03) | ✓ VERIFIED | Exists, 978 lines, contains all 10 required sections including three use case templates, compatibility matrix, FAB lifecycle |

### Artifact Verification Details

#### spec/06-ml-framework-variants.md

- **Exists:** YES (487 lines)
- **Substantive:** YES (complete Dockerfiles for all three variants, decision records with arguments, detailed package breakdowns)
- **Wired:** YES (referenced by use case template spec, extends Phase 1 SuperNode spec)
- **Contains requirement tag:** YES (APPL-05 on line 3)
- **Key sections present:**
  - Section 1: Purpose and Scope ✓
  - Section 2: Variant Strategy Overview ✓
  - Section 3: Dockerfile Specifications (3a PyTorch, 3b TensorFlow, 3c scikit-learn) ✓
  - Section 4: Image Size Targets ✓
  - Section 5: ML_FRAMEWORK Variable Behavior ✓
  - Section 6: QCOW2 Build Strategy ✓
  - Section 7: Decision Record (DR-01, DR-02, DR-03) ✓
  - Section 8: Interaction with Existing Spec Sections ✓

#### spec/07-use-case-templates.md

- **Exists:** YES (978 lines)
- **Substantive:** YES (complete client_app.py code examples for all three use cases, compatibility matrix with validation pseudocode, FAB lifecycle specification)
- **Wired:** YES (references framework variant spec for ML_FRAMEWORK compatibility, references Phase 1 SuperNode for data mount path)
- **Contains requirement tag:** YES (ML-03 on line 3)
- **Key sections present:**
  - Section 1: Purpose and Scope ✓
  - Section 2: FL_USE_CASE Contextualization Variable ✓
  - Section 3: Framework/Use-Case Compatibility Matrix ✓
  - Section 4: Use Case 1: Image Classification ✓
  - Section 5: Use Case 2: Anomaly Detection ✓
  - Section 6: Use Case 3: LLM Fine-Tuning ✓
  - Section 7: FAB Pre-Installation Process ✓
  - Section 8: FAB Activation at Runtime ✓
  - Section 9: Data Provisioning Strategy ✓
  - Section 10: New Contextualization Variables Summary ✓

## Key Link Verification

### Plan 03-01 Key Links

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| spec/06-ml-framework-variants.md | spec/02-supernode-appliance.md | Extends SuperNode image components with framework-specific Docker images | ✓ WIRED | Section 8a references SuperNode Section 2 (Image Components) and explains variant images extend base. Pattern "flwr/supernode" appears 50+ times |
| spec/06-ml-framework-variants.md | spec/03-contextualization-reference.md | References ML_FRAMEWORK placeholder variable and defines its runtime behavior | ✓ WIRED | Section 8b states ML_FRAMEWORK transitions from placeholder to functional. Section 5 defines complete behavior |

### Plan 03-02 Key Links

| From | To | Via | Status | Details |
|------|----|----|--------|---------|
| spec/07-use-case-templates.md | spec/06-ml-framework-variants.md | Use cases require specific framework variants to be deployed | ✓ WIRED | Section 3 compatibility matrix cross-checks FL_USE_CASE against ML_FRAMEWORK. References variant packages for dependency availability |
| spec/07-use-case-templates.md | spec/03-contextualization-reference.md | Defines new FL_USE_CASE variable extending the contextualization reference | ✓ WIRED | Section 2 defines FL_USE_CASE with USER_INPUT format. Section 10 updates total variable count to 30 |
| spec/07-use-case-templates.md | spec/02-supernode-appliance.md | Use case FABs are pre-installed in SuperNode variant images | ✓ WIRED | Section 7 references /app/.flwr FAB directory and data mount path /app/data from Phase 1 SuperNode spec |

## Requirements Coverage

### Requirements Verified

| Requirement | Status | Supporting Evidence |
|-------------|--------|---------------------|
| APPL-05: Spec defines appliance variants for ML frameworks with image size targets | ✓ SATISFIED | spec/06-ml-framework-variants.md defines three variants (PyTorch, TensorFlow, scikit-learn) with Docker image size targets (~800MB-1.2GB, ~500-700MB, ~300-400MB) and QCOW2 size targets (~4-5GB, ~3-4GB, ~2.5-3GB) |
| ML-03: Spec defines pre-built use case templates with contextualization-only deployment | ✓ SATISFIED | spec/07-use-case-templates.md defines three use case templates deployable by setting FL_USE_CASE + ML_FRAMEWORK + standard FL_* variables. No SSH or code changes required |

## Success Criteria Verification

### Phase Goal Success Criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| 1 | The spec defines at least three appliance variants (PyTorch-focused, TensorFlow-focused, lightweight/scikit-learn) with image size targets and justification for the split | ✓ MET | spec/06-ml-framework-variants.md Section 2 defines three variants with image size targets in Section 4. Section 7 provides decision records justifying variant approach |
| 2 | Each use case template (image classification, anomaly detection, LLM fine-tuning) is defined with its required contextualization parameters and expected outputs | ✓ MET | spec/07-use-case-templates.md Sections 4, 5, 6 define all three use cases with complete contextualization parameters and expected output tables |
| 3 | A reader can deploy any use case template by setting only contextualization variables -- no SSH, no code changes | ✓ MET | Each use case template provides complete contextualization parameter examples. FABs are pre-installed in Docker images (Section 7) and activated by FL_USE_CASE at boot (Section 8) |
| 4 | The spec includes a decision record for the variant strategy (why these frameworks, why not a single fat image) | ✓ MET | spec/06-ml-framework-variants.md Section 7 contains three formal decision records addressing variant strategy, framework selection, and LLM dependency placement |

**All 4 success criteria MET**

## Anti-Patterns Found

No blocking anti-patterns detected. Both spec files are complete specifications with:
- Substantive technical content (487 and 978 lines respectively)
- Complete code examples (Dockerfiles, client_app.py implementations, validation pseudocode)
- Formal decision records with arguments
- Cross-references to prior phase specifications
- Requirement traceability

## Phase 3 Completion Assessment

### Spec Completeness

**Plan 03-01 (ML Framework Variants):**
- Three framework-specific Docker images fully specified with complete Dockerfiles
- Image size targets documented for both Docker images and QCOW2 appliances
- ML_FRAMEWORK variable behavior defined with configure.sh case statement
- QCOW2 build strategy and marketplace listing approach defined
- Three decision records justify variant approach with clear arguments

**Plan 03-02 (Use Case Templates):**
- Three use case templates fully specified (image classification, anomaly detection, LLM fine-tuning)
- FL_USE_CASE variable defined with USER_INPUT format
- Framework/use-case compatibility matrix with boot-time validation prevents invalid configurations
- FAB lifecycle from build to pre-installation to runtime activation fully specified
- Data provisioning strategy covers both demo (auto-download) and production (pre-provisioned) modes
- Each use case includes complete contextualization parameters and expected outputs

### Implementation Readiness

A reader with the spec can:
1. Build all three framework-specific Docker images from the provided Dockerfiles
2. Create QCOW2 images with pre-pulled framework variants
3. List three separate appliances in OpenNebula marketplace
4. Build and pre-install use case FABs in framework Docker images
5. Deploy any use case by setting contextualization variables without SSH or code changes
6. Validate framework/use-case compatibility at boot time

### Outstanding Items

None. All must-haves verified, all success criteria met, all requirements satisfied.

**Note:** LLM fine-tuning use case has explicit dependency on Phase 6 (GPU Acceleration). This is correctly documented in spec/07-use-case-templates.md Section 6.2 ("GPU Dependency (Phase 6)").

---

**Verification Status: PASSED**

All Phase 3 must-haves verified. Both appliance variant strategy (APPL-05) and use case templates (ML-03) specifications are complete and implementation-ready. Phase goal achieved.

---

_Verified: 2026-02-07T21:00:00Z_
_Verifier: Claude (gsd-verifier)_
