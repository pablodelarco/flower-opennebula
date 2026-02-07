# ML Framework Variant Strategy

**Requirement:** APPL-05
**Phase:** 03 - ML Framework Variants and Use Cases
**Status:** Specification

---

## 1. Purpose and Scope

This section defines the appliance variant strategy for the Flower SuperNode: three framework-specific Docker images extending `flwr/supernode`, each pre-baked into a framework-specific QCOW2 image. The variant strategy enables deployers to select the right ML framework for their federated learning workload without carrying unused framework dependencies.

**What this section covers:**
- Three SuperNode Docker image variants (PyTorch, TensorFlow, scikit-learn) with complete Dockerfiles.
- Image size targets for both Docker images and QCOW2 appliances.
- The `ML_FRAMEWORK` contextualization variable behavior and `configure.sh` selection logic.
- QCOW2 build strategy for framework-specific marketplace appliances.
- Decision record justifying the variant approach over a single fat image.

**What this section does NOT cover:**
- Pre-built use case templates and FAB delivery (Phase 3, Plan 2 -- see `spec/07-use-case-templates.md`).
- GPU-enabled framework images with CUDA (Phase 6 -- all variants in this section are CPU-only).
- Custom user-provided Docker images (out of scope; users extend the provided variants).

**Requirement traceability:** This document satisfies APPL-05 (appliance variants for ML frameworks with image size targets).

**Relationship to base SuperNode spec:** The base SuperNode appliance (`spec/02-supernode-appliance.md`) ships with `flwr/supernode:1.25.0` -- the bare Flower client runtime with Python 3.13 and no ML framework. The variants defined here extend that base image with framework-specific Python packages. The base QCOW2 image described in Phase 1 remains valid as a "bring your own code" option where users supply their own extended Docker image.

---

## 2. Variant Strategy Overview

Three framework-specific Docker images extend the base `flwr/supernode:1.25.0` image. Each variant is pre-pulled into a dedicated QCOW2 image and listed as a separate marketplace appliance.

| Property | PyTorch Variant | TensorFlow Variant | scikit-learn Variant |
|----------|----------------|--------------------|---------------------|
| **Docker image name** | `flower-supernode-pytorch:{FLOWER_VERSION}` | `flower-supernode-tensorflow:{FLOWER_VERSION}` | `flower-supernode-sklearn:{FLOWER_VERSION}` |
| **Base image** | `flwr/supernode:1.25.0` | `flwr/supernode:1.25.0` | `flwr/supernode:1.25.0` |
| **Key packages** | torch, torchvision, flwr-datasets[vision], tqdm, bitsandbytes, peft, transformers | tensorflow-cpu, flwr-datasets[vision], tqdm | scikit-learn, pandas, flwr-datasets |
| **Est. Docker image size** | ~800 MB - 1.2 GB | ~500 - 700 MB | ~300 - 400 MB |
| **Est. QCOW2 size** | ~4 - 5 GB | ~3 - 4 GB | ~2.5 - 3 GB |
| **Primary use cases** | Image classification, deep learning, LLM fine-tuning (FlowerTune) | Image classification, Keras workflows, enterprise ML | Tabular data, anomaly detection, lightweight/traditional ML |
| **ML_FRAMEWORK value** | `pytorch` | `tensorflow` | `sklearn` |

**Naming convention:** Custom images use the `flower-supernode-{framework}:{FLOWER_VERSION}` pattern to distinguish them from official Flower images (`flwr/supernode`). The `flower-` prefix signals these are project-built images, not upstream Flower releases.

**CPU-only in Phase 3:** All three variants install CPU-only framework builds. GPU-enabled variants (CUDA wheels, NVIDIA runtime) are deferred to Phase 6. This keeps image sizes manageable and avoids CUDA dependency conflicts in the base images.

---

## 3. Dockerfile Specifications

Each Dockerfile follows the official Flower pattern for extending the SuperNode image. All Dockerfiles use `--no-cache-dir` for pip installs to minimize image layers and follow Flower's non-root `app` user convention.

### 3a. PyTorch Variant

The PyTorch variant is the largest image because it includes both core PyTorch and LLM fine-tuning dependencies (bitsandbytes, peft, transformers). This avoids introducing a fourth variant while covering the two most common deep learning use cases: image classification and LLM fine-tuning.

```dockerfile
FROM flwr/supernode:1.25.0

# Install build dependencies as root
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Switch to app user for pip installs (matches Flower non-root pattern)
USER app

# Core PyTorch (CPU-only to avoid CUDA bloat)
RUN python -m pip install --no-cache-dir \
    torch==2.5.0+cpu \
    torchvision==0.20.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# Flower datasets and utilities
RUN python -m pip install --no-cache-dir \
    "flwr-datasets[vision]>=0.4.0" \
    tqdm

# LLM fine-tuning dependencies (FlowerTune pattern)
# Adds ~500 MB but avoids a fourth variant image
RUN python -m pip install --no-cache-dir \
    bitsandbytes \
    peft \
    transformers
```

**Package breakdown:**

| Package | Purpose | Size Impact |
|---------|---------|-------------|
| `torch` (CPU) | Core PyTorch tensor library | ~200 MB |
| `torchvision` (CPU) | Image transforms, pretrained models | ~30 MB |
| `flwr-datasets[vision]` | Federated dataset loading with image support | ~20 MB |
| `tqdm` | Training progress bars | <1 MB |
| `bitsandbytes` | 4-bit/8-bit quantization for LLM fine-tuning | ~50 MB |
| `peft` | Parameter-Efficient Fine-Tuning (LoRA, DoRA) | ~10 MB |
| `transformers` | Hugging Face model loading and tokenization | ~400 MB (with transitive deps) |

**LLM dependency size note:** The `transformers` package and its transitive dependencies (tokenizers, safetensors, huggingface_hub) account for approximately 500 MB of additional image size. This is a significant addition to the PyTorch variant. The decision to include these in the PyTorch variant rather than creating a separate LLM variant is documented in Section 7 (Decision Record).

**CPU-only index URL:** The `--index-url https://download.pytorch.org/whl/cpu` flag ensures pip downloads CPU-only PyTorch wheels. Without this flag, pip defaults to CUDA-enabled wheels that add 2+ GB to the image.

### 3b. TensorFlow Variant

The TensorFlow variant installs the CPU-only TensorFlow package. The `tensorflow-cpu` package (not `tensorflow`) avoids bundling CUDA stubs that add ~300 MB to the image.

```dockerfile
FROM flwr/supernode:1.25.0

# Install build dependencies as root
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Switch to app user for pip installs
USER app

# TensorFlow CPU-only (NOT tensorflow -- avoids CUDA stubs)
RUN python -m pip install --no-cache-dir \
    tensorflow-cpu

# Flower datasets and utilities
RUN python -m pip install --no-cache-dir \
    "flwr-datasets[vision]>=0.4.0" \
    tqdm
```

**Package breakdown:**

| Package | Purpose | Size Impact |
|---------|---------|-------------|
| `tensorflow-cpu` | Core TensorFlow with Keras (CPU-only) | ~260 MB |
| `flwr-datasets[vision]` | Federated dataset loading with image support | ~20 MB |
| `tqdm` | Training progress bars | <1 MB |

**Why `tensorflow-cpu` and not `tensorflow`:** The default `tensorflow` package includes CUDA stubs and GPU support libraries even when no GPU is present. These stubs add ~300 MB to the image and serve no purpose in CPU-only environments. The `tensorflow-cpu` package is the correct choice for Phase 3. Phase 6 (GPU) will define a GPU-enabled variant using the full `tensorflow` package.

### 3c. scikit-learn Variant

The scikit-learn variant is the lightest image, targeting tabular data and traditional ML workloads.

```dockerfile
FROM flwr/supernode:1.25.0

# No build dependencies needed for scikit-learn
# Switch to app user for pip installs
USER app

# scikit-learn with pandas for tabular data
RUN python -m pip install --no-cache-dir \
    scikit-learn \
    pandas

# Flower datasets (no vision extra needed for tabular data)
RUN python -m pip install --no-cache-dir \
    flwr-datasets
```

**Package breakdown:**

| Package | Purpose | Size Impact |
|---------|---------|-------------|
| `scikit-learn` | Classical ML algorithms (LogReg, SVM, IsolationForest, etc.) | ~30 MB |
| `pandas` | DataFrame handling for tabular data | ~20 MB |
| `flwr-datasets` | Federated dataset loading (base, no vision extras) | ~10 MB |

**Why no `build-essential`:** scikit-learn ships precompiled wheels for Python 3.13 on linux/amd64. No C compilation is needed, so the `build-essential` apt package is omitted to keep the image smaller.

**Why no `flwr-datasets[vision]`:** The scikit-learn variant targets tabular data workloads. The `[vision]` extra installs Pillow and torchvision dependencies that are unnecessary for tabular data. If a user needs image processing with scikit-learn, they should use the PyTorch variant instead.

---

## 4. Image Size Targets

These are soft targets to be validated during the QCOW2 build process. Actual sizes depend on exact package versions and transitive dependencies at build time.

### Docker Image Sizes

| Variant | Base Image | Framework Additions | LLM Additions | Total Estimate |
|---------|-----------|--------------------:|---------------:|---------------:|
| PyTorch | ~190 MB | ~250 MB | ~500 MB | **~800 MB - 1.2 GB** |
| TensorFlow | ~190 MB | ~280 MB | -- | **~500 - 700 MB** |
| scikit-learn | ~190 MB | ~60 MB | -- | **~300 - 400 MB** |

### QCOW2 Image Sizes

| Variant | Base QCOW2 Components | Framework Docker Image | Total Estimate |
|---------|----------------------|----------------------:|---------------:|
| PyTorch | ~2 GB (Ubuntu + Docker + base Flower image) | ~800 MB - 1.2 GB | **~4 - 5 GB** |
| TensorFlow | ~2 GB | ~500 - 700 MB | **~3 - 4 GB** |
| scikit-learn | ~2 GB | ~300 - 400 MB | **~2.5 - 3 GB** |

**Comparison with single fat image:** A single image containing all three frameworks plus LLM dependencies would be approximately 5-7 GB (QCOW2), significantly larger than the largest single variant.

**Validation plan:** During implementation, measure actual image sizes after building each Dockerfile. If any variant exceeds the target by more than 50%, investigate transitive dependencies and consider pinning package versions or using multi-stage builds.

---

## 5. ML_FRAMEWORK Variable Behavior

The `ML_FRAMEWORK` contextualization variable (already defined as a Phase 3 placeholder in `spec/03-contextualization-reference.md`, Section 6) selects which framework-specific Docker image the SuperNode runs at boot time.

### Variable Definition

| Property | Value |
|----------|-------|
| **Variable name** | `ML_FRAMEWORK` |
| **USER_INPUT** | `O\|list\|ML framework\|pytorch,tensorflow,sklearn\|pytorch` |
| **Type** | list (single-select dropdown in Sunstone) |
| **Default** | `pytorch` |
| **Valid values** | `pytorch`, `tensorflow`, `sklearn` |
| **Appliance** | SuperNode only |

### Selection Logic in configure.sh

The configure.sh script uses `ML_FRAMEWORK` to determine which Docker image tag to use when starting the SuperNode container. This replaces the direct `flwr/supernode:{FLOWER_VERSION}` reference from Phase 1.

```bash
# ML_FRAMEWORK image selection (Phase 3)
# Determines which framework-specific Docker image to run.
# Default: pytorch (most common for FL workloads)

case "${ML_FRAMEWORK:-pytorch}" in
    pytorch)    IMAGE_TAG="flower-supernode-pytorch:${FLOWER_VERSION}" ;;
    tensorflow) IMAGE_TAG="flower-supernode-tensorflow:${FLOWER_VERSION}" ;;
    sklearn)    IMAGE_TAG="flower-supernode-sklearn:${FLOWER_VERSION}" ;;
    *)          log "ERROR" "Unknown ML_FRAMEWORK: '${ML_FRAMEWORK}'"
                log "ERROR" "Valid options: pytorch, tensorflow, sklearn"
                exit 1 ;;
esac

log "INFO" "Selected ML framework: ${ML_FRAMEWORK:-pytorch}"
log "INFO" "Docker image: ${IMAGE_TAG}"
```

### Docker Run Command Update

The Phase 1 Docker run command (from `spec/02-supernode-appliance.md`, Section 8) changes from:

```bash
# Phase 1 (base SuperNode):
flwr/supernode:${FLOWER_VERSION:-1.25.0}
```

to:

```bash
# Phase 3 (framework-specific):
${IMAGE_TAG}
```

The rest of the Docker run command (flags, mounts, environment) remains unchanged:

```bash
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  -v /opt/flower/data:/app/data:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  ${IMAGE_TAG} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES:-0} \
  --max-wait-time ${FL_MAX_WAIT_TIME:-0}
```

### Fallback Behavior

If the selected framework image is not pre-baked in the QCOW2, Docker attempts to pull it. This follows the same version override pattern from Phase 1 (`spec/02-supernode-appliance.md`, Section 4):

```bash
# Check if selected framework image exists locally
if ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
    log "WARN" "Framework image ${IMAGE_TAG} not found locally"
    log "INFO" "Attempting to pull ${IMAGE_TAG}..."
    if docker pull "${IMAGE_TAG}"; then
        log "INFO" "Successfully pulled ${IMAGE_TAG}"
    else
        log "ERROR" "Failed to pull ${IMAGE_TAG}"
        log "ERROR" "This QCOW2 may not include the '${ML_FRAMEWORK}' variant."
        log "ERROR" "Deploy the correct framework-specific QCOW2 or ensure network access."
        exit 1
    fi
fi
```

**Key difference from Phase 1 fallback:** In Phase 1, the fallback uses the pre-baked version (same image, different tag). For framework variants, there is no sensible fallback -- a PyTorch QCOW2 cannot fall back to a TensorFlow image. The bootstrap script exits with an error if the requested framework image is unavailable.

### Validation Rule

The configure.sh validation (see `spec/03-contextualization-reference.md`, Section 8) adds a check for `ML_FRAMEWORK`:

```bash
# ML_FRAMEWORK validation
case "${ML_FRAMEWORK:-pytorch}" in
    pytorch|tensorflow|sklearn) ;;
    *) log "ERROR" "Unknown ML_FRAMEWORK: '${ML_FRAMEWORK}'. Valid options: pytorch, tensorflow, sklearn."
       errors=$((errors + 1)) ;;
esac
```

---

## 6. QCOW2 Build Strategy

Each framework variant produces a separate QCOW2 image for the OpenNebula marketplace. This section defines the build process and marketplace listing strategy.

### Build Process

Three separate QCOW2 images are built, one per framework variant. Each QCOW2 includes the base SuperNode components (from Phase 1) plus the framework-specific Docker image.

**Build steps for each variant:**

```
1. Start from base SuperNode QCOW2 (Ubuntu 24.04 + Docker CE + flwr/supernode:1.25.0)
2. Build the framework-specific Docker image from its Dockerfile:
     docker build -t flower-supernode-{framework}:1.25.0 \
       -f docker/supernode-{framework}/Dockerfile .
3. Pre-pull the built image into the local Docker cache:
     (Image is already local from the build step)
4. Record the pre-baked framework in /opt/flower/PREBAKED_FRAMEWORK:
     echo "{framework}" > /opt/flower/PREBAKED_FRAMEWORK
5. Clean up build artifacts (dangling layers, apt cache)
6. Export the QCOW2 image
```

**What each QCOW2 contains:**

| Component | Base SuperNode QCOW2 | PyTorch QCOW2 | TensorFlow QCOW2 | scikit-learn QCOW2 |
|-----------|---------------------|---------------|-------------------|-------------------|
| Ubuntu 24.04 | Y | Y | Y | Y |
| Docker CE | Y | Y | Y | Y |
| `flwr/supernode:1.25.0` | Y | Y | Y | Y |
| `flower-supernode-pytorch:1.25.0` | -- | Y | -- | -- |
| `flower-supernode-tensorflow:1.25.0` | -- | -- | Y | -- |
| `flower-supernode-sklearn:1.25.0` | -- | -- | -- | Y |
| Contextualization scripts | Y | Y | Y | Y |

The base `flwr/supernode:1.25.0` image remains in all QCOW2 variants because the framework-specific images are built `FROM flwr/supernode:1.25.0`. Docker layer sharing means the base image layers are not duplicated -- only the added framework layers consume additional disk space.

### Marketplace Listing

Three separate appliance entries in the OpenNebula marketplace:

| Marketplace Entry | QCOW2 | Default ML_FRAMEWORK | Description |
|-------------------|-------|---------------------|-------------|
| **Flower SuperNode - PyTorch** | `flower-supernode-pytorch.qcow2` | `pytorch` | Deep learning and LLM fine-tuning. Includes PyTorch, torchvision, and FlowerTune dependencies. |
| **Flower SuperNode - TensorFlow** | `flower-supernode-tensorflow.qcow2` | `tensorflow` | TensorFlow/Keras workflows. Includes tensorflow-cpu and Flower datasets. |
| **Flower SuperNode - scikit-learn** | `flower-supernode-sklearn.qcow2` | `sklearn` | Lightweight ML for tabular data. Includes scikit-learn, pandas, and Flower datasets. |

**Marketplace naming convention:** Each appliance name includes the framework to avoid confusion. A user searching for "Flower" sees three distinct entries and can select the one matching their workload.

**Base SuperNode appliance:** The base SuperNode QCOW2 (from Phase 1) remains available in the marketplace for users who bring their own custom Docker image. It ships with only `flwr/supernode:1.25.0` and no framework dependencies.

### Version Coupling

When `FLOWER_VERSION` is overridden, the framework-specific image tag also changes:

```
FLOWER_VERSION=1.26.0, ML_FRAMEWORK=pytorch
  -> IMAGE_TAG=flower-supernode-pytorch:1.26.0
```

If the QCOW2 was built with Flower 1.25.0, the image `flower-supernode-pytorch:1.26.0` does not exist locally. The bootstrap script attempts to pull it. In air-gapped environments, this pull will fail. To use a different Flower version in air-gapped mode, the QCOW2 must be rebuilt with the new version.

---

## 7. Decision Record: Variant Strategy

### DR-01: Why Multiple Variants Over a Single Fat Image

**Context:** The SuperNode appliance needs ML framework dependencies to run ClientApp code in subprocess isolation mode. The two options are: (A) a single QCOW2 image containing all frameworks, or (B) separate QCOW2 images per framework.

**Decision:** Separate QCOW2 images per framework (Option B).

**Arguments:**

| Factor | Single Fat Image (A) | Multiple Variants (B) |
|--------|---------------------|----------------------|
| QCOW2 download size | ~5-7 GB (all frameworks) | ~2.5-5 GB each (only needed framework) |
| Disk usage per VM | ~5-7 GB (unused frameworks waste space) | ~2.5-5 GB (no waste) |
| Framework version conflicts | PyTorch and TensorFlow can have conflicting numpy or protobuf versions | Isolated by image; no conflicts possible |
| Marketplace clarity | Single confusing entry ("Flower SuperNode - All Frameworks") | Clear entries: "PyTorch", "TensorFlow", "scikit-learn" |
| Build complexity | One complex Dockerfile managing multiple frameworks | Three simple Dockerfiles, each single-purpose |
| Update agility | Updating one framework requires rebuilding the entire fat image | Update only the affected variant |
| Air-gapped deployment | Download one large image even if only one framework is needed | Download only the variant you need |
| Docker layer caching | Poor; framework layers cannot be shared | Each variant shares the base `flwr/supernode` layers |

**Status:** Accepted.

### DR-02: Why These Three Frameworks

**Context:** The Flower framework supports many ML backends (PyTorch, TensorFlow, JAX, scikit-learn, XGBoost, and others). The variant strategy must select which frameworks to provide as pre-built appliance images.

**Decision:** PyTorch, TensorFlow, and scikit-learn.

**Arguments:**

| Framework | Justification | Flower Ecosystem Support |
|-----------|---------------|--------------------------|
| **PyTorch** | Most popular ML framework for research and federated learning. Required for LLM fine-tuning (PEFT/bitsandbytes). Dominant in Flower examples and baselines. | Quickstart examples, FlowerTune, all baselines are PyTorch-first. |
| **TensorFlow** | Strong enterprise adoption. Keras API is accessible for applied ML. Mobile/edge inference path (TF Lite). | Quickstart TensorFlow/Keras example; MobileNetV2 on CIFAR-10. |
| **scikit-learn** | Lightweight; covers tabular data and traditional ML. Smallest image for resource-constrained environments. | Quickstart sklearn example (LogisticRegression on iris). |

**Why not others:**

| Framework | Reason for Exclusion |
|-----------|---------------------|
| **JAX** | Niche adoption, primarily Google research. Limited Flower example coverage. Can be added as a future variant without architectural changes. |
| **XGBoost** | Gradient boosting is a specific use case, not a general-purpose framework. Users needing XGBoost can install it in the scikit-learn variant or build a custom image. |
| **Hugging Face Transformers** | Not a framework -- it is a library that runs on PyTorch or TensorFlow. Already included in the PyTorch variant for LLM fine-tuning. |

**Extensibility:** The three-variant architecture does not prevent adding future variants. A JAX or XGBoost variant can be added by creating a new Dockerfile, building a new QCOW2, and adding a new value to the `ML_FRAMEWORK` list. No existing variants or spec sections need to change.

**Status:** Accepted.

### DR-03: Why Include LLM Dependencies in the PyTorch Variant

**Context:** LLM fine-tuning (FlowerTune pattern) requires PyTorch plus additional packages: bitsandbytes (quantization), peft (LoRA/DoRA), and transformers (model loading). These add approximately 500 MB to the Docker image. The question is whether to create a fourth variant (`flower-supernode-llm`) or include LLM dependencies in the PyTorch variant.

**Decision:** Include LLM dependencies in the PyTorch variant.

**Arguments for (include in PyTorch):**
- LLM fine-tuning always requires PyTorch. There is no TensorFlow or scikit-learn LLM path in the Flower ecosystem.
- Three variants are easier to communicate and maintain than four.
- Users who do not use LLM fine-tuning pay a ~500 MB size penalty but gain the ability to try it without switching images.
- The PyTorch variant is already the largest; the proportional increase (~60%) is significant but does not cross a critical threshold.

**Arguments against (separate LLM variant):**
- The PyTorch variant grows from ~600 MB to ~1.2 GB Docker image.
- The QCOW2 grows from ~3-4 GB to ~4-5 GB.
- Users who only need PyTorch for image classification carry unused LLM dependencies.

**Mitigating factor:** The `transformers` library and its dependencies are the primary size contributor. If image size becomes problematic during implementation, the LLM dependencies can be split into a fourth variant without changing the `ML_FRAMEWORK` selection mechanism (add `llm` to the valid values list).

**Status:** Accepted with monitoring. Revisit if PyTorch QCOW2 exceeds 5 GB during implementation.

---

## 8. Interaction with Existing Spec Sections

### 8a. SuperNode Appliance (spec/02-supernode-appliance.md)

**Section 2 (Image Components):** The base SuperNode QCOW2 ships with `flwr/supernode:1.25.0`. Framework-specific QCOW2 variants additionally include the extended Docker image (`flower-supernode-{framework}:{FLOWER_VERSION}`). The base image table in Section 2 remains accurate -- framework variants add to it, they do not replace it.

**Section 7 (Boot Sequence, Step 9):** The version override mechanism in bootstrap.sh now checks for both `FLOWER_VERSION` overrides AND `ML_FRAMEWORK` image availability. The Phase 1 logic (`docker pull flwr/supernode:${VERSION}`) is extended to handle framework-specific image tags.

**Section 8 (Docker Container Configuration):** The Docker run command replaces the image reference from `flwr/supernode:${FLOWER_VERSION}` to `${IMAGE_TAG}` as resolved by the `ML_FRAMEWORK` selection logic (Section 5 of this document). All other flags, mounts, and environment variables remain unchanged.

### 8b. Contextualization Reference (spec/03-contextualization-reference.md)

**Section 6 (Phase 2+ Placeholder Parameters):** The `ML_FRAMEWORK` variable transitions from "placeholder -- not functional in Phase 1" to fully functional in Phase 3. Its USER_INPUT definition remains unchanged:

```
ML_FRAMEWORK = "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch"
```

The validation rule (Section 8 of the contextualization reference) now applies at boot time: the value must be one of `pytorch`, `tensorflow`, `sklearn`.

### 8c. Boot Sequence Impact

The framework selection integrates into the existing SuperNode boot sequence at **Step 6** (Docker image loading / version override). The modified step:

| Step | Phase 1 Behavior | Phase 3 Behavior |
|------|-----------------|-----------------|
| 5 (Configure) | Generate `supernode.env` with `flwr/supernode:{VERSION}` | Generate `supernode.env`; resolve `IMAGE_TAG` from `ML_FRAMEWORK` |
| 9 (Bootstrap) | Check version override for `flwr/supernode:{VERSION}` | Check version override for `${IMAGE_TAG}`; verify framework image exists locally |

No new boot steps are introduced. The framework selection logic is absorbed into existing steps.

### 8d. Subprocess Mode Dependency

The default isolation mode is `subprocess` (see `spec/02-supernode-appliance.md`, Section 8). In subprocess mode, the ClientApp runs inside the SuperNode container. This means ALL Python dependencies required by the ClientApp must be pre-installed in the SuperNode Docker image. This is the primary reason framework-specific images exist: the ClientApp needs `import torch` or `import sklearn` to function, and those packages must be in the same container.

If `FL_ISOLATION=process` is used instead, the ClientApp runs in a separate container with its own image. In that mode, framework dependencies could be in the ClientApp image instead of the SuperNode image. However, subprocess mode remains the default and recommended configuration for simplicity.

---

*Specification for APPL-05: ML Framework Variant Strategy*
*Phase: 03 - ML Framework Variants and Use Cases*
*Version: 1.0*
