# Phase 3: ML Framework Variants and Use Cases - Research

**Researched:** 2026-02-07
**Domain:** Flower Docker image variants, ML framework packaging, federated learning use case templates
**Confidence:** HIGH (core architecture verified via official Flower docs, Docker patterns confirmed)

## Summary

This phase requires specifying two things: (1) an appliance variant strategy that defines framework-specific SuperNode QCOW2 images (PyTorch, TensorFlow, scikit-learn), and (2) pre-built use case templates that can be deployed purely through contextualization variables.

The key architectural insight is that Flower's base `flwr/supernode` image is minimal (~190 MB compressed) and does NOT include any ML framework. Framework dependencies must be added by extending the base image via a Dockerfile (`FROM flwr/supernode:1.25.0` + `pip install torch`). This is the official Flower pattern -- there are no pre-built framework-specific `flwr/supernode` tags on Docker Hub. The appliance variant strategy therefore means building custom Docker images that bundle framework dependencies into the `flwr/supernode` base, then pre-baking these into framework-specific QCOW2 images.

For use case templates, Flower's current architecture (1.25+) delivers ClientApp code via FAB (Flower App Bundle) files through the SuperLink. The `--app-dir` flag has been removed. In subprocess mode (our default), the SuperNode runs ClientApp code from the FAB delivered by SuperLink, but FAB dependencies must be pre-installed in the SuperNode image. This means use case templates must be pre-packaged as FABs and the required Python dependencies pre-installed in the framework-specific Docker image.

**Primary recommendation:** Define three framework-specific Docker images (extending `flwr/supernode`) that are pre-pulled into three QCOW2 variants. Use case templates are delivered as pre-built FABs installed in the image via `flwr install`, with the `ML_FRAMEWORK` contextualization variable selecting which Docker image to run.

## Standard Stack

The established libraries/tools for this domain:

### Core ML Framework Sizes (CPU-only, pip install)

| Framework | Key Packages | Approx. Size (CPU) | Approx. Size (GPU/CUDA) | Use Case Fit |
|-----------|-------------|---------------------|--------------------------|-------------|
| PyTorch 2.x | torch, torchvision | ~200 MB | ~2-3 GB (with CUDA) | Image classification, deep learning, LLM fine-tuning |
| TensorFlow 2.x | tensorflow-cpu | ~260 MB | ~600 MB (tensorflow includes CUDA stubs) | Image classification, Keras workflows |
| scikit-learn | scikit-learn, numpy, scipy | ~60 MB | N/A (CPU-only) | Tabular data, anomaly detection, lightweight ML |

### Framework-Specific Docker Image Sizing

| Variant | Base Image | Added Packages | Est. Docker Image Size | Est. QCOW2 Size |
|---------|-----------|----------------|----------------------|-----------------|
| PyTorch | `flwr/supernode:1.25.0` (~190 MB) | torch, torchvision, flwr-datasets | ~600-800 MB | ~3-4 GB |
| TensorFlow | `flwr/supernode:1.25.0` (~190 MB) | tensorflow-cpu, flwr-datasets | ~500-700 MB | ~3-4 GB |
| scikit-learn (lightweight) | `flwr/supernode:1.25.0` (~190 MB) | scikit-learn, flwr-datasets, pandas | ~300-400 MB | ~2.5-3 GB |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| flwr-datasets | latest | Dataset download, partitioning, preprocessing | All use cases - provides `FederatedDataset` and `IidPartitioner` |
| bitsandbytes | latest | Quantization for LLM fine-tuning (4-bit, 8-bit) | LLM fine-tuning use case only |
| peft | latest | Parameter-Efficient Fine-Tuning (LoRA, DoRA) | LLM fine-tuning use case only |
| transformers | latest | Hugging Face model loading | LLM fine-tuning use case only |
| tqdm | latest | Progress bars for training | All PyTorch/TensorFlow use cases |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Three separate QCOW2 images | Single fat image with all frameworks | Fat image would be 5-7 GB QCOW2 vs 3-4 GB each; wastes disk on unused frameworks; longer download |
| Pre-built FABs in image | Runtime FAB delivery from external source | Breaks air-gapped/network-free boot guarantee from Phase 1 |
| CPU-only framework images | GPU-enabled (CUDA) framework images | CUDA adds 2+ GB per image; Phase 6 handles GPU -- keep Phase 3 CPU-only |

## Architecture Patterns

### Recommended Project Structure

The spec should define these new artifacts:

```
spec/
    06-ml-framework-variants.md          # APPL-05: Variant strategy, Dockerfiles, image sizing
    07-use-case-templates.md             # ML-03: Three use case template specifications

# Conceptual image build structure (spec defines, does not implement):
docker/
    supernode-pytorch/
        Dockerfile                       # FROM flwr/supernode:1.25.0 + PyTorch
    supernode-tensorflow/
        Dockerfile                       # FROM flwr/supernode:1.25.0 + TensorFlow
    supernode-sklearn/
        Dockerfile                       # FROM flwr/supernode:1.25.0 + scikit-learn

# Use case FABs (pre-built, installed in images):
use-cases/
    image-classification/               # PyTorch + ResNet + CIFAR-10
        pyproject.toml
        client_app.py
        server_app.py
        task.py
    anomaly-detection/                   # scikit-learn + IsolationForest/LogReg + tabular IoT data
        pyproject.toml
        client_app.py
        server_app.py
        task.py
    llm-fine-tuning/                     # PyTorch + PEFT + FlowerTune pattern
        pyproject.toml
        client_app.py
        server_app.py
        task.py
```

### Pattern 1: Framework-Specific Docker Image Extension

**What:** Build custom Docker images that extend `flwr/supernode` with framework dependencies
**When to use:** Always -- this is the only way to add ML frameworks to the Flower SuperNode container
**Source:** Official Flower Docker documentation

```dockerfile
# Example: PyTorch variant Dockerfile
FROM flwr/supernode:1.25.0

USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential && \
    rm -rf /var/lib/apt/lists/*

USER app
RUN python -m pip install --no-cache-dir \
    torch==2.5.0+cpu \
    torchvision==0.20.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

RUN python -m pip install --no-cache-dir \
    "flwr-datasets[vision]>=0.4.0" \
    tqdm
```

### Pattern 2: FAB Pre-installation for Use Case Templates

**What:** Build FABs from use case template code and install them into the Docker image using `flwr install`
**When to use:** For delivering pre-built use case templates that work without network access
**Source:** Flower CLI docs (flwr build, flwr install)

```dockerfile
# Install pre-built FABs into the image
COPY use-cases/image-classification.fab /tmp/
RUN flwr install /tmp/image-classification.fab --flwr-dir /app/.flwr
```

### Pattern 3: ML_FRAMEWORK Variable Selecting Docker Image

**What:** The `ML_FRAMEWORK` contextualization variable selects which pre-pulled Docker image to run
**When to use:** Boot-time decision in the SuperNode configure.sh script
**Source:** Phase 1 spec (placeholder `ML_FRAMEWORK` variable already defined)

```bash
# In configure.sh:
case "${ML_FRAMEWORK:-pytorch}" in
    pytorch)    IMAGE_TAG="flower-supernode-pytorch:${FLOWER_VERSION}" ;;
    tensorflow) IMAGE_TAG="flower-supernode-tensorflow:${FLOWER_VERSION}" ;;
    sklearn)    IMAGE_TAG="flower-supernode-sklearn:${FLOWER_VERSION}" ;;
    *)          log "ERROR" "Unknown ML_FRAMEWORK: '${ML_FRAMEWORK}'"; exit 1 ;;
esac
```

### Pattern 4: Use Case Template Selection via FL_USE_CASE Variable

**What:** A new contextualization variable (`FL_USE_CASE`) selects which pre-installed FAB to activate
**When to use:** When the user wants a specific pre-built use case deployed without writing any code
**Rationale:** Complements `ML_FRAMEWORK` -- the framework selects the Docker image, the use case selects the FAB

```bash
# Proposed new context variable:
# FL_USE_CASE = "O|list|Pre-built use case template|none,image-classification,anomaly-detection,llm-fine-tuning|none"
```

### Anti-Patterns to Avoid

- **Runtime pip install of frameworks:** Never install PyTorch/TensorFlow at boot time. These are 200+ MB downloads that break the network-free boot guarantee and add minutes to startup.
- **Single fat image with all frameworks:** PyTorch + TensorFlow + scikit-learn in one image wastes 400+ MB of disk per VM for unused frameworks and increases QCOW2 download time.
- **Using --app-dir:** This flag has been removed in Flower 1.25+. Do not spec it. FABs are delivered by SuperLink or pre-installed.
- **Requiring code changes for use cases:** The spec requires "deploy by setting only contextualization variables." Use case templates must be fully self-contained in the pre-installed FAB.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Data partitioning | Custom data splitting code | `flwr-datasets` with `IidPartitioner` or `DirichletPartitioner` | Handles download, partitioning, preprocessing; integrates with node config `partition-id` |
| Model parameter serialization | Custom numpy/pickle serialization | Flower's `ArrayRecord` + `to_torch_state_dict()` | Built-in, handles all frameworks, compatible with aggregation strategies |
| LLM quantization | Custom quantization code | `bitsandbytes` + `peft` (LoRA/DoRA) | Industry standard; FlowerTune pattern uses this exact stack |
| Training loop management | Custom training orchestration | Flower's `@app.train()` and `@app.evaluate()` decorators | Handles parameter distribution, result collection, metrics aggregation |
| Federated strategy configuration | Custom aggregation code | Flower built-in strategies (FedAvg, FedProx, FedAdam) | Already spec'd in Phase 1 via `FL_STRATEGY` variable |
| Docker image building | Manual layer management | Multi-stage Dockerfile with `--no-cache-dir` | Flower's official pattern; keeps images small |

**Key insight:** The use case templates should be thin wrappers around Flower's existing example patterns (quickstart-pytorch, quickstart-sklearn, flowertune-llm). The innovation is in the packaging (FABs in QCOW2 images) and contextualization (deploy via variables), not in the ML code itself.

## Common Pitfalls

### Pitfall 1: CUDA Dependencies in CPU-Only Images
**What goes wrong:** Including CUDA/cuDNN in the framework Docker images even though Phase 3 is CPU-only. This bloats images by 2-4 GB.
**Why it happens:** PyTorch's default pip install pulls CUDA-enabled wheels. TensorFlow's default package includes CUDA stubs.
**How to avoid:** Explicitly install CPU-only variants:
- PyTorch: `--index-url https://download.pytorch.org/whl/cpu`
- TensorFlow: `pip install tensorflow-cpu` (not `tensorflow`)
**Warning signs:** Docker image size exceeding 2 GB for a single framework variant.

### Pitfall 2: FAB Dependencies Not Pre-installed
**What goes wrong:** The FAB is installed in the image but its Python dependencies are not. At runtime, the ClientApp fails to import required modules.
**Why it happens:** `flwr install` installs the FAB (code bundle) but does NOT install pip dependencies. Those must be in the Docker image already.
**How to avoid:** The Dockerfile must `pip install` all Python packages that the use case's `pyproject.toml` requires, BEFORE the FAB is installed.
**Warning signs:** `ModuleNotFoundError` at runtime when the ClientApp runs.

### Pitfall 3: Framework/Use Case Mismatch
**What goes wrong:** User selects `ML_FRAMEWORK=sklearn` but `FL_USE_CASE=image-classification` (which requires PyTorch).
**Why it happens:** Framework and use case are two separate variables with no built-in coupling.
**How to avoid:** Define a compatibility matrix in the spec and add boot-time validation that checks the combination. Some use cases should only be available with certain frameworks.
**Warning signs:** ClientApp import errors for missing framework modules.

### Pitfall 4: Image Size Explosion from Transitive Dependencies
**What goes wrong:** Installing `transformers` for LLM fine-tuning pulls in 500+ MB of transitive dependencies (tokenizers, safetensors, huggingface_hub, etc.).
**Why it happens:** Hugging Face ecosystem has many dependencies.
**How to avoid:** Pin exact versions and use `--no-cache-dir`. Consider a separate LLM-specific image variant rather than including LLM deps in the base PyTorch variant.
**Warning signs:** PyTorch variant QCOW2 exceeding 5 GB.

### Pitfall 5: Data Provisioning Confusion
**What goes wrong:** Use case template expects data at `/app/data` but no data provisioning is specified.
**Why it happens:** The spec defines the mount point but not how data arrives for demo use cases.
**How to avoid:** For demo use cases, use `flwr-datasets` to download data programmatically (with network), OR pre-bake demo datasets into the Docker image. Clearly distinguish "demo mode" (auto-download) from "production mode" (pre-provisioned data).
**Warning signs:** Empty `/app/data` directory at runtime; ClientApp crashes on missing data.

### Pitfall 6: Subprocess Mode Requires Dependencies in SuperNode Image
**What goes wrong:** In subprocess isolation mode (our default), the ClientApp runs INSIDE the SuperNode container. If framework dependencies aren't in that container, the ClientApp fails.
**Why it happens:** Confusion between subprocess mode (deps in SuperNode) and process mode (deps in separate ClientApp container).
**How to avoid:** Explicitly state in the spec that because we use `--isolation subprocess`, ALL ClientApp dependencies must be in the extended SuperNode Docker image. This is the primary reason for framework-specific images.
**Warning signs:** ImportError at ClientApp launch time.

## Code Examples

### Use Case 1: Image Classification (PyTorch + ResNet/CNN + CIFAR-10)

This is the canonical Flower quickstart example, adapted for our appliance.

**Framework:** PyTorch
**Model:** Simple CNN (or ResNet-18 for advanced variant)
**Dataset:** CIFAR-10 via flwr-datasets
**Source:** Flower quickstart-pytorch example

```python
# client_app.py (simplified from Flower quickstart)
from flwr.client import ClientApp
from flwr.common import ArrayRecord

app = ClientApp()

@app.train()
def train(message):
    # Load model, apply received weights
    model = Net()
    state_dict = to_torch_state_dict(message.content.array_records["model"])
    model.load_state_dict(state_dict)

    # Load partition data using node config
    partition_id = message.context.node_config["partition-id"]
    trainloader = load_data(int(partition_id))

    # Train locally
    train_model(model, trainloader, epochs=1)

    # Return updated weights
    updated = from_torch_state_dict(model.state_dict())
    return message.create_reply(ArrayRecord({"model": updated}))
```

**Contextualization parameters for deployment:**
```
ML_FRAMEWORK = pytorch
FL_USE_CASE = image-classification
FL_NODE_CONFIG = "partition-id=0 num-partitions=2"
FL_NUM_ROUNDS = 3
FL_STRATEGY = FedAvg
```

### Use Case 2: Anomaly Detection (scikit-learn + LogisticRegression/IsolationForest + Tabular IoT Data)

**Framework:** scikit-learn
**Model:** LogisticRegression (federated parameter exchange via coefficient extraction) or IsolationForest
**Dataset:** Tabular IoT sensor data (or iris for demo)
**Source:** Flower quickstart-sklearn example, FL anomaly detection literature

```python
# client_app.py (simplified scikit-learn pattern)
from flwr.client import ClientApp
import numpy as np
from sklearn.linear_model import LogisticRegression

app = ClientApp()

@app.train()
def train(message):
    model = LogisticRegression(max_iter=1, warm_start=True)

    # Extract parameters from message
    params = message.content.array_records["model"]
    model.coef_ = params["coef"]
    model.intercept_ = params["intercept"]

    # Load local data partition
    X_train, y_train = load_partition_data(message.context.node_config)

    # Fit on local data
    model.fit(X_train, y_train)

    # Return updated parameters
    updated = {"coef": model.coef_, "intercept": model.intercept_}
    return message.create_reply(ArrayRecord({"model": updated}))
```

**Contextualization parameters for deployment:**
```
ML_FRAMEWORK = sklearn
FL_USE_CASE = anomaly-detection
FL_NODE_CONFIG = "partition-id=0 num-partitions=4"
FL_NUM_ROUNDS = 10
FL_STRATEGY = FedAvg
```

### Use Case 3: LLM Fine-Tuning (PyTorch + PEFT/LoRA + FlowerTune Pattern)

**Framework:** PyTorch (with bitsandbytes, peft, transformers)
**Model:** OpenLLaMA 3B (4-bit quantized) or similar small LLM
**Dataset:** Task-specific instruction dataset
**Source:** FlowerTune LLM example from Flower

**VRAM requirements per client (from official FlowerTune docs):**

| Model | Quantization | VRAM Required |
|-------|-------------|---------------|
| 3B | 4-bit | ~10.6 GB |
| 3B | 8-bit | ~13.5 GB |
| 7B | 4-bit | ~16.5 GB |
| 7B | 8-bit | ~22 GB |

**Contextualization parameters for deployment:**
```
ML_FRAMEWORK = pytorch
FL_USE_CASE = llm-fine-tuning
FL_NODE_CONFIG = "partition-id=0 num-partitions=2 model-name=openllama-3b quantization=4bit"
FL_NUM_ROUNDS = 100
FL_STRATEGY = FedAvg
FL_GPU_ENABLED = YES  # Phase 6 -- LLM fine-tuning requires GPU
```

**Note:** LLM fine-tuning requires GPU (Phase 6) and significantly more resources than the other two use cases. The spec should note this as a constraint and define the LLM use case template parameters, but acknowledge that actual LLM deployment depends on Phase 6 (GPU passthrough) being complete.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `flower-supernode <app-dir>` (load local code) | FAB delivery via SuperLink | Flower 1.13+ (2024) | Cannot mount ClientApp code directly; must use FABs |
| flwr/server + flwr/client images | flwr/superlink + flwr/supernode + flwr/superexec | Flower 1.9+ (2024) | Image names changed; architecture split |
| FABs without wheels | FABs include wheel files | Flower 1.13+ (2024) | Enables air-gapped FAB installation via `flwr install` |
| pip-based FAB install | Lighter FAB install (no pip) | Flower 1.21+ (2025) | Smaller FABs, faster install, but deps still need pre-install |
| Framework-specific Flower images | Base image + Dockerfile extension | Current | No official `flwr/supernode:1.25.0-pytorch` tag exists; you build custom images |

**Deprecated/outdated:**
- `--app-dir` flag: Removed. SuperNode loads FABs from SuperLink, not local directories.
- `flwr/client` image name: Renamed to `flwr/supernode`.
- `flwr/server` image name: Renamed to `flwr/superlink`.

## Decision Record Inputs

The spec requires a decision record for the variant strategy. Key arguments to document:

### Why Multiple Variants (Not a Single Fat Image)

| Factor | Single Fat Image | Multiple Variants |
|--------|-----------------|-------------------|
| QCOW2 download size | ~5-7 GB | ~3-4 GB each |
| Disk usage per VM | ~5-7 GB | ~3-4 GB |
| Framework conflicts | PyTorch/TensorFlow version conflicts possible | Isolated by image |
| Marketplace clarity | "one size fits all" -- confusing | Clear: "PyTorch SuperNode", "TensorFlow SuperNode" |
| Build complexity | One Dockerfile, more complex | Three Dockerfiles, simpler each |
| Update agility | Update one framework requires rebuilding everything | Update only affected variant |
| Air-gapped deployment | Download one large image | Download only needed variant |

### Why These Three Frameworks

| Framework | Justification | Flower Ecosystem Support |
|-----------|---------------|--------------------------|
| **PyTorch** | Most popular ML framework for research/FL; required for LLM fine-tuning (PEFT/bitsandbytes) | Quickstart examples, FlowerTune, baselines all PyTorch-first |
| **TensorFlow** | Enterprise adoption; Keras API is accessible; strong mobile/edge inference path | Quickstart TensorFlow/Keras example; MobileNetV2 on CIFAR-10 |
| **scikit-learn** | Lightweight; covers tabular data, traditional ML, anomaly detection; smallest image | Quickstart sklearn example (LogisticRegression on iris) |

### Why Not Others (JAX, XGBoost, etc.)

- JAX: Niche adoption, primarily Google research
- XGBoost: Gradient boosting is a specific use case, not a general framework
- Hugging Face Transformers: Not a framework -- it's a library that runs ON PyTorch/TensorFlow
- These can be added as future variants without changing the architecture

## Open Questions

Things that could not be fully resolved:

1. **Docker image tag naming convention for custom images**
   - What we know: Official Flower images use `flwr/supernode:VERSION-pyPYVER-DISTRO` pattern
   - What's unclear: What should our custom framework images be named? Options: `flower-supernode-pytorch:1.25.0`, `flwr-supernode-pytorch:1.25.0`, or a completely custom namespace
   - Recommendation: Use a descriptive naming pattern like `flower-supernode-pytorch:1.25.0` to distinguish from official Flower images while maintaining clarity

2. **LLM fine-tuning variant: separate image or extension of PyTorch?**
   - What we know: LLM fine-tuning requires PyTorch + bitsandbytes + peft + transformers (~500+ MB additional). It also requires GPU (Phase 6).
   - What's unclear: Should this be a fourth variant (`llm`), or should the PyTorch variant include these dependencies?
   - Recommendation: Include LLM dependencies in the PyTorch variant for simplicity (three variants, not four), but document the size impact. Alternatively, define it as a PyTorch "extended" sub-variant.

3. **Data provisioning for demo use cases**
   - What we know: `flwr-datasets` can download CIFAR-10/iris automatically. Our appliance default is network-free boot.
   - What's unclear: Should demo use cases auto-download data (requires network) or should demo data be pre-baked?
   - Recommendation: Use `flwr-datasets` with auto-download as the default (demos are not air-gapped), but document the data size impact and how to pre-provision data for air-gapped deployments.

4. **FAB delivery mechanism in subprocess mode**
   - What we know: In subprocess mode, FABs are delivered from SuperLink. Dependencies must be pre-installed. The `flwr install` command can pre-install FABs.
   - What's unclear: In subprocess mode, does the SuperNode automatically pull the FAB from SuperLink at runtime, or must it be pre-installed? Flower docs are ambiguous here.
   - Recommendation: Spec both paths: (1) pre-installed FABs for "zero-config" use cases, (2) runtime FAB delivery for custom ClientApps. The pre-installed path is for our use case templates; the runtime path is for users bringing their own code.

5. **Exact QCOW2 image sizes**
   - What we know: Estimates based on base OS (~1.5 GB) + Docker CE (~0.5 GB) + framework Docker image size
   - What's unclear: Actual compressed QCOW2 sizes can only be determined by building the images
   - Recommendation: Set soft targets in the spec (3-4 GB for PyTorch/TF, 2.5-3 GB for sklearn) and validate during implementation

## Sources

### Primary (HIGH confidence)
- [Flower Docker quickstart docs](https://flower.ai/docs/framework/docker/tutorial-quickstart-docker.html) - Docker run commands, image extension pattern
- [Flower subprocess mode docs](https://flower.ai/docs/framework/docker/run-as-subprocess.html) - FAB dependency pre-installation requirement
- [Flower CLI reference](https://flower.ai/docs/framework/ref-api-cli.html) - flwr install, flwr build, flower-supernode flags
- [Flower network communication docs](https://flower.ai/docs/framework/ref-flower-network-communication.html) - FAB delivery flow, port assignments, isolation modes
- [Flower architecture docs](https://flower.ai/docs/framework/explanation-flower-architecture.html) - SuperNode/ClientApp/SuperExec relationship
- [Flower quickstart-pytorch](https://flower.ai/docs/framework/tutorial-quickstart-pytorch.html) - ClientApp code structure, CIFAR-10 example
- [Flower quickstart-sklearn](https://flower.ai/docs/examples/quickstart-sklearn.html) - scikit-learn FL example
- [FlowerTune LLM example](https://flower.ai/docs/examples/flowertune-llm.html) - PEFT/LoRA/bitsandbytes configuration, VRAM requirements
- [Flower Docker image announcement](https://flower.ai/blog/2024-06-20-announcing-flower-docker/) - Image architecture, size reduction, non-root user

### Secondary (MEDIUM confidence)
- [Flower Docker Compose complete example](https://github.com/adap/flower/blob/main/framework/docker/complete/compose.yml) - Real-world Docker Compose patterns
- [Flower changelog](https://flower.ai/docs/framework/ref-changelog.html) - FAB wheel inclusion (1.13), --app-dir removal
- [PyTorch Forums](https://discuss.pytorch.org/) - CPU-only install sizes, Docker optimization
- [TensorFlow pip](https://pypi.org/project/tensorflow-cpu/) - CPU-only wheel sizes

### Tertiary (LOW confidence)
- Docker image size estimates: Based on general knowledge of PyTorch/TensorFlow wheel sizes, not measured for our specific image configuration. Needs validation during build.
- QCOW2 size targets: Extrapolated from Phase 1 base image estimate (~2-3 GB) plus framework additions. Not measured.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Framework choices and Docker extension pattern verified via official Flower docs
- Architecture: HIGH - FAB delivery, subprocess mode, image extension pattern all confirmed in official docs
- Use case templates: MEDIUM - Based on official Flower examples, but adapted for our contextualization-only deployment model
- Image size estimates: LOW - Calculated from pip package sizes, not from actual Docker image builds
- Pitfalls: HIGH - Well-documented in Flower community (CUDA bloat, dep pre-installation requirement)

**Research date:** 2026-02-07
**Valid until:** 2026-03-07 (30 days -- Flower release cycle is ~monthly, but core Docker patterns are stable)
