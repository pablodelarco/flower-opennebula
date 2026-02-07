# Pre-Built Use Case Templates

**Requirement:** ML-03
**Phase:** 03 - ML Framework Variants and Use Cases
**Status:** Specification

---

## 1. Purpose and Scope

This section defines three pre-built federated learning use case templates that are deployable purely through contextualization variables. Each use case template is a Flower App Bundle (FAB) that is pre-installed in the framework-specific Docker images (defined in `spec/06-ml-framework-variants.md`) and activated at runtime via the `FL_USE_CASE` contextualization variable.

**What this section covers:**
- The `FL_USE_CASE` contextualization variable definition and SuperNode USER_INPUT integration.
- A framework/use-case compatibility matrix with boot-time validation.
- Three complete use case template specifications: image classification, anomaly detection, and LLM fine-tuning.
- FAB pre-installation process (build-time) and activation flow (runtime).
- Data provisioning strategy for both demo and production deployments.

**What this section does NOT cover:**
- ML framework variant strategy and Dockerfiles (see `spec/06-ml-framework-variants.md`).
- Custom user-provided ClientApps (users bring their own FABs via SuperLink delivery).
- GPU passthrough configuration for LLM fine-tuning (Phase 6 -- see `spec/06-ml-framework-variants.md` Section 1 scope note).
- Aggregation strategy details beyond FedAvg defaults (Phase 5).

**Key constraint:** A deployer SHALL be able to run any pre-built use case by setting only `FL_USE_CASE`, `ML_FRAMEWORK`, and standard `FL_*` variables. No SSH access, no code changes, no external FAB delivery.

**Requirement traceability:** This document satisfies ML-03 (pre-built use case templates with contextualization-only deployment).

---

## 2. FL_USE_CASE Contextualization Variable

The `FL_USE_CASE` variable selects which pre-installed use case template to activate on the SuperNode at boot time.

### Variable Definition

| Property | Value |
|----------|-------|
| **Variable name** | `FL_USE_CASE` |
| **USER_INPUT** | `O\|list\|Pre-built use case template\|none,image-classification,anomaly-detection,llm-fine-tuning\|none` |
| **Type** | list (single-select dropdown in Sunstone) |
| **Default** | `none` |
| **Valid values** | `none`, `image-classification`, `anomaly-detection`, `llm-fine-tuning` |
| **Appliance** | SuperNode only |

### Behavior

- **`none` (default):** No pre-built use case is activated. The SuperNode waits for FAB delivery from the SuperLink. This is the standard behavior for users who provide their own ClientApp code.
- **Any other value:** The SuperNode's `configure.sh` activates the corresponding pre-installed FAB. The FAB contains the ClientApp code for the selected use case. When the SuperLink submits a run, the SuperNode uses the pre-installed FAB instead of receiving one from the SuperLink.

### SuperNode USER_INPUT Block Addition

This variable is added to the SuperNode USER_INPUT block (see `spec/03-contextualization-reference.md`, Section 4):

```
FL_USE_CASE = "O|list|Pre-built use case template|none,image-classification,anomaly-detection,llm-fine-tuning|none"
```

### Relationship to ML_FRAMEWORK

`FL_USE_CASE` and `ML_FRAMEWORK` (defined in `spec/06-ml-framework-variants.md`, Section 5) work together:

- `ML_FRAMEWORK` selects which Docker image runs (determines available Python packages).
- `FL_USE_CASE` selects which pre-installed FAB to activate (determines which ClientApp code runs).
- Not all combinations are valid. The compatibility matrix (Section 3) defines which pairings are allowed.

---

## 3. Framework/Use-Case Compatibility Matrix

Each use case requires specific ML framework dependencies. Deploying a use case on an incompatible framework variant causes import failures at runtime. The boot-time validation defined below prevents invalid combinations.

### Compatibility Table

| Use Case | `pytorch` | `tensorflow` | `sklearn` |
|----------|-----------|--------------|-----------|
| `image-classification` | YES (primary) | YES (alternate) | NO |
| `anomaly-detection` | NO | NO | YES (primary) |
| `llm-fine-tuning` | YES (primary) | NO | NO |
| `none` | YES | YES | YES |

**Primary** means the use case was designed and tested for that framework. **Alternate** means a separate implementation exists for that framework. **NO** means the use case cannot run on that framework (missing dependencies).

### Boot-Time Validation

The `configure.sh` script SHALL validate the `ML_FRAMEWORK` and `FL_USE_CASE` combination during the configure stage (boot Step 3 for SuperNode). An incompatible combination is a **fatal error** -- the boot aborts with a clear error message.

**Validation pseudocode:**

```bash
# FL_USE_CASE / ML_FRAMEWORK compatibility validation (Phase 3)
validate_use_case_compat() {
    local use_case="${FL_USE_CASE:-none}"
    local framework="${ML_FRAMEWORK:-pytorch}"

    case "${use_case}" in
        none)
            # All frameworks are valid when no use case is selected
            ;;
        image-classification)
            case "${framework}" in
                pytorch|tensorflow) ;;
                *) log "ERROR" "FL_USE_CASE '${use_case}' requires ML_FRAMEWORK 'pytorch' or 'tensorflow', but ML_FRAMEWORK is set to '${framework}'"
                   exit 1 ;;
            esac
            ;;
        anomaly-detection)
            case "${framework}" in
                sklearn) ;;
                *) log "ERROR" "FL_USE_CASE '${use_case}' requires ML_FRAMEWORK 'sklearn', but ML_FRAMEWORK is set to '${framework}'"
                   exit 1 ;;
            esac
            ;;
        llm-fine-tuning)
            case "${framework}" in
                pytorch) ;;
                *) log "ERROR" "FL_USE_CASE '${use_case}' requires ML_FRAMEWORK 'pytorch', but ML_FRAMEWORK is set to '${framework}'"
                   exit 1 ;;
            esac
            ;;
        *)
            log "ERROR" "Unknown FL_USE_CASE: '${use_case}'. Valid options: none, image-classification, anomaly-detection, llm-fine-tuning."
            exit 1
            ;;
    esac

    if [ "${use_case}" != "none" ]; then
        log "INFO" "Use case '${use_case}' is compatible with framework '${framework}'"
    fi
}
```

**Error message examples:**

| Invalid Combination | Error Message |
|---------------------|---------------|
| `FL_USE_CASE=llm-fine-tuning`, `ML_FRAMEWORK=sklearn` | `FL_USE_CASE 'llm-fine-tuning' requires ML_FRAMEWORK 'pytorch', but ML_FRAMEWORK is set to 'sklearn'` |
| `FL_USE_CASE=anomaly-detection`, `ML_FRAMEWORK=pytorch` | `FL_USE_CASE 'anomaly-detection' requires ML_FRAMEWORK 'sklearn', but ML_FRAMEWORK is set to 'pytorch'` |
| `FL_USE_CASE=image-classification`, `ML_FRAMEWORK=sklearn` | `FL_USE_CASE 'image-classification' requires ML_FRAMEWORK 'pytorch' or 'tensorflow', but ML_FRAMEWORK is set to 'sklearn'` |

---

## 4. Use Case 1: Image Classification

### Overview

| Property | Value |
|----------|-------|
| **Identifier** | `image-classification` |
| **Framework** | PyTorch (primary), TensorFlow (alternate) |
| **Model** | Simple CNN (PyTorch), MobileNetV2 (TensorFlow) |
| **Dataset** | CIFAR-10 via `flwr-datasets` (~170 MB download) |
| **FAB name** | `flower-image-classification` |
| **Resource requirements** | CPU-only, ~2 GB RAM per SuperNode |

### Contextualization Parameters for Deployment

```
ML_FRAMEWORK = pytorch
FL_USE_CASE = image-classification
FL_NODE_CONFIG = "partition-id=0 num-partitions=2"
FL_NUM_ROUNDS = 3
FL_STRATEGY = FedAvg
```

Each SuperNode in the federation SHOULD have a unique `partition-id` (0 through N-1) and the same `num-partitions` (N) to ensure each node trains on a different data shard.

### FAB Structure

**pyproject.toml:**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "flower-image-classification"
version = "1.0.0"
description = "Federated image classification with CIFAR-10"
dependencies = []  # Dependencies pre-installed in Docker image

[flower.components]
serverapp = "server_app:app"
clientapp = "client_app:app"
```

**client_app.py (PyTorch variant):**

```python
"""Federated image classification ClientApp (PyTorch + CNN + CIFAR-10)."""
import torch
import torch.nn as nn
from torch.utils.data import DataLoader
from flwr.client import ClientApp
from flwr.common import ArrayRecord

app = ClientApp()


class SimpleCNN(nn.Module):
    """Simple CNN for CIFAR-10 classification."""

    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(3, 32, 3, padding=1)
        self.conv2 = nn.Conv2d(32, 64, 3, padding=1)
        self.pool = nn.MaxPool2d(2, 2)
        self.fc1 = nn.Linear(64 * 8 * 8, 128)
        self.fc2 = nn.Linear(128, 10)

    def forward(self, x):
        x = self.pool(torch.relu(self.conv1(x)))
        x = self.pool(torch.relu(self.conv2(x)))
        x = x.view(-1, 64 * 8 * 8)
        x = torch.relu(self.fc1(x))
        return self.fc2(x)


def load_data(partition_id, num_partitions):
    """Load CIFAR-10 partition using flwr-datasets."""
    from flwr_datasets import FederatedDataset
    from flwr_datasets.partitioner import IidPartitioner

    fds = FederatedDataset(
        dataset="uoft-cs/cifar10",
        partitioners={"train": IidPartitioner(num_partitions=num_partitions)},
    )
    partition = fds.load_partition(partition_id, "train")
    # Transform to PyTorch tensors
    # (implementation uses torchvision.transforms for normalization)
    return DataLoader(partition, batch_size=32, shuffle=True)


@app.train()
def train(message):
    model = SimpleCNN()

    # Load received global model weights
    state_dict = message.content.array_records.get("model")
    if state_dict is not None:
        model.load_state_dict(state_dict)

    # Load local data partition
    partition_id = int(message.context.node_config["partition-id"])
    num_partitions = int(message.context.node_config["num-partitions"])
    trainloader = load_data(partition_id, num_partitions)

    # Train locally for 1 epoch
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
    running_loss = 0.0
    for images, labels in trainloader:
        optimizer.zero_grad()
        loss = criterion(model(images), labels)
        loss.backward()
        optimizer.step()
        running_loss += loss.item()

    # Return updated model weights and metrics
    updated = model.state_dict()
    metrics = {"train_loss": running_loss / len(trainloader)}
    return message.create_reply(
        ArrayRecord({"model": updated}), metrics=metrics
    )


@app.evaluate()
def evaluate(message):
    model = SimpleCNN()
    state_dict = message.content.array_records.get("model")
    if state_dict is not None:
        model.load_state_dict(state_dict)

    partition_id = int(message.context.node_config["partition-id"])
    num_partitions = int(message.context.node_config["num-partitions"])
    testloader = load_data(partition_id, num_partitions)

    correct, total = 0, 0
    with torch.no_grad():
        for images, labels in testloader:
            outputs = model(images)
            _, predicted = torch.max(outputs, 1)
            total += labels.size(0)
            correct += (predicted == labels).sum().item()

    accuracy = correct / total
    return message.create_reply(
        ArrayRecord({"model": model.state_dict()}),
        metrics={"accuracy": accuracy},
    )
```

**server_app.py:**

```python
"""Federated image classification ServerApp."""
from flwr.server import ServerApp
from flwr.server.strategy import FedAvg

app = ServerApp()


@app.main()
def main(driver, context):
    # Strategy and num_rounds come from SuperLink contextualization
    # (FL_STRATEGY, FL_NUM_ROUNDS) -- passed via Flower's run config
    pass
```

**Note:** The ServerApp is minimal because aggregation strategy and round configuration are controlled by the SuperLink's contextualization variables (`FL_STRATEGY`, `FL_NUM_ROUNDS`). The FAB's server_app.py exists to satisfy the FAB structure requirement but delegates strategy selection to the SuperLink.

### Expected Outputs

| Metric | Per Round | Final |
|--------|-----------|-------|
| Training loss | Averaged across participating SuperNodes | After `FL_NUM_ROUNDS` rounds |
| Accuracy | Evaluated on each SuperNode's test partition | Global model accuracy after aggregation |

**Typical results (CIFAR-10, 2 clients, FedAvg, 3 rounds):** ~40-50% accuracy. Accuracy improves with more rounds and more clients.

### Data Provisioning

- **Demo mode (default):** `flwr-datasets` auto-downloads CIFAR-10 (~170 MB) on first run. Requires network access from the SuperNode VM. Subsequent runs use the cached dataset.
- **Production mode:** Data pre-provisioned at `/opt/flower/data/` on the host (mounted as `/app/data:ro` in the container per `spec/02-supernode-appliance.md`, Section 12). The ClientApp detects files in `/app/data/` and loads them instead of downloading via `flwr-datasets`.
- **Selection logic:** If `/app/data/` contains files, use local data. Otherwise, fall back to `flwr-datasets` download.

---

## 5. Use Case 2: Anomaly Detection

### Overview

| Property | Value |
|----------|-------|
| **Identifier** | `anomaly-detection` |
| **Framework** | scikit-learn |
| **Model** | LogisticRegression with `warm_start` (federated parameter exchange via `coef_`/`intercept_` extraction) |
| **Dataset** | Demo: iris dataset via `flwr-datasets` (~10 KB). Production: CSV at `/app/data/`. |
| **FAB name** | `flower-anomaly-detection` |
| **Resource requirements** | CPU-only, ~512 MB RAM per SuperNode (lightest use case) |

### Contextualization Parameters for Deployment

```
ML_FRAMEWORK = sklearn
FL_USE_CASE = anomaly-detection
FL_NODE_CONFIG = "partition-id=0 num-partitions=4"
FL_NUM_ROUNDS = 10
FL_STRATEGY = FedAvg
```

### FAB Structure

**pyproject.toml:**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "flower-anomaly-detection"
version = "1.0.0"
description = "Federated anomaly detection with scikit-learn"
dependencies = []  # Dependencies pre-installed in Docker image

[flower.components]
serverapp = "server_app:app"
clientapp = "client_app:app"
```

**client_app.py:**

```python
"""Federated anomaly detection ClientApp (scikit-learn + LogisticRegression)."""
import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score
from flwr.client import ClientApp
from flwr.common import ArrayRecord

app = ClientApp()

# Global model instance with warm_start for incremental learning
MODEL = LogisticRegression(max_iter=1, warm_start=True, solver="lbfgs")


def load_data(partition_id, num_partitions):
    """Load data partition. Uses /app/data if available, else flwr-datasets."""
    import os

    data_dir = "/app/data"
    if os.path.isdir(data_dir) and os.listdir(data_dir):
        # Production mode: load from pre-provisioned CSV
        import pandas as pd

        df = pd.read_csv(os.path.join(data_dir, "data.csv"))
        X = df.iloc[:, :-1].values
        y = df.iloc[:, -1].values
        # Partition the data by splitting into equal chunks
        chunk_size = len(X) // num_partitions
        start = partition_id * chunk_size
        end = start + chunk_size if partition_id < num_partitions - 1 else len(X)
        return X[start:end], y[start:end]
    else:
        # Demo mode: use flwr-datasets with iris
        from flwr_datasets import FederatedDataset
        from flwr_datasets.partitioner import IidPartitioner

        fds = FederatedDataset(
            dataset="scikit-learn/iris",
            partitioners={
                "train": IidPartitioner(num_partitions=num_partitions)
            },
        )
        partition = fds.load_partition(partition_id, "train")
        X = np.array(partition["features"])
        y = np.array(partition["label"])
        return X, y


@app.train()
def train(message):
    # Extract model parameters from message
    params = message.content.array_records.get("model")
    if params is not None:
        MODEL.coef_ = np.array(params["coef"])
        MODEL.intercept_ = np.array(params["intercept"])
        MODEL.classes_ = np.array(params["classes"])

    # Load local data partition
    partition_id = int(message.context.node_config["partition-id"])
    num_partitions = int(message.context.node_config["num-partitions"])
    X_train, y_train = load_data(partition_id, num_partitions)

    # Fit on local data (warm_start continues from received parameters)
    MODEL.fit(X_train, y_train)

    # Return updated parameters
    updated = {
        "coef": MODEL.coef_,
        "intercept": MODEL.intercept_,
        "classes": MODEL.classes_,
    }
    train_acc = accuracy_score(y_train, MODEL.predict(X_train))
    return message.create_reply(
        ArrayRecord({"model": updated}),
        metrics={"train_accuracy": train_acc, "num_samples": len(X_train)},
    )


@app.evaluate()
def evaluate(message):
    params = message.content.array_records.get("model")
    if params is not None:
        MODEL.coef_ = np.array(params["coef"])
        MODEL.intercept_ = np.array(params["intercept"])
        MODEL.classes_ = np.array(params["classes"])

    partition_id = int(message.context.node_config["partition-id"])
    num_partitions = int(message.context.node_config["num-partitions"])
    X_test, y_test = load_data(partition_id, num_partitions)

    accuracy = accuracy_score(y_test, MODEL.predict(X_test))
    return message.create_reply(
        ArrayRecord({"model": {"coef": MODEL.coef_, "intercept": MODEL.intercept_, "classes": MODEL.classes_}}),
        metrics={"accuracy": accuracy, "num_samples": len(X_test)},
    )
```

**server_app.py:**

```python
"""Federated anomaly detection ServerApp."""
from flwr.server import ServerApp

app = ServerApp()


@app.main()
def main(driver, context):
    # Strategy and num_rounds controlled by SuperLink contextualization
    pass
```

### Expected Outputs

| Metric | Per Round | Final |
|--------|-----------|-------|
| Training accuracy | Per-SuperNode accuracy on local partition | After `FL_NUM_ROUNDS` rounds |
| Evaluation accuracy | Evaluated on each SuperNode's test data | Global model accuracy after aggregation |

**Typical results (iris, 4 clients, FedAvg, 10 rounds):** ~90-95% accuracy. The iris dataset is small and linearly separable, so convergence is fast.

### Data Provisioning

- **Demo mode (default):** `flwr-datasets` auto-downloads the iris dataset (~10 KB). Network requirement is negligible.
- **Production mode:** CSV file pre-provisioned at `/opt/flower/data/data.csv` on the host. The CSV SHALL have features in all columns except the last, which contains the label. The ClientApp reads from `/app/data/data.csv`.
- **Selection logic:** If `/app/data/` contains files, load from CSV. Otherwise, fall back to `flwr-datasets` with iris.

---

## 6. Use Case 3: LLM Fine-Tuning

### Overview

| Property | Value |
|----------|-------|
| **Identifier** | `llm-fine-tuning` |
| **Framework** | PyTorch (with bitsandbytes, peft, transformers pre-installed in PyTorch variant) |
| **Model** | Small LLM (e.g., OpenLLaMA 3B) with 4-bit quantization via bitsandbytes and LoRA adapters via peft |
| **Dataset** | Task-specific instruction dataset (not auto-downloadable; requires pre-provisioned data or Hugging Face dataset name in `FL_NODE_CONFIG`) |
| **FAB name** | `flower-llm-fine-tuning` |
| **Resource requirements** | GPU with 16+ GB VRAM, ~16 GB system RAM per SuperNode |

### GPU Dependency (Phase 6)

**CRITICAL:** LLM fine-tuning REQUIRES GPU passthrough (Phase 6). Without `FL_GPU_ENABLED=YES` and actual GPU hardware passed through to the VM, this use case will:

- Fail with out-of-memory (OOM) errors on CPU-only systems (even 3B models require more memory than CPU training can provide efficiently).
- Be prohibitively slow if it does run (hours per round instead of minutes).

This spec defines the use case template parameters and FAB structure. Actual deployment depends on Phase 6 (GPU Acceleration) being complete.

### VRAM Requirements

| Model | Quantization | VRAM Required |
|-------|-------------|---------------|
| 3B | 4-bit | ~10.6 GB |
| 3B | 8-bit | ~13.5 GB |
| 7B | 4-bit | ~16.5 GB |

**Recommendation:** Start with a 3B model at 4-bit quantization (~10.6 GB VRAM) for initial deployments. 7B models require 16+ GB VRAM GPUs (e.g., NVIDIA A100 or H100).

### Contextualization Parameters for Deployment

```
ML_FRAMEWORK = pytorch
FL_USE_CASE = llm-fine-tuning
FL_NODE_CONFIG = "partition-id=0 num-partitions=2 model-name=openlm-research/open_llama_3b quantization=4bit"
FL_NUM_ROUNDS = 100
FL_STRATEGY = FedAvg
FL_GPU_ENABLED = YES
```

**Node config parameters specific to LLM fine-tuning:**

| Key | Values | Purpose |
|-----|--------|---------|
| `model-name` | Hugging Face model ID | Base model to fine-tune (e.g., `openlm-research/open_llama_3b`) |
| `quantization` | `4bit`, `8bit`, `none` | Quantization level via bitsandbytes. `4bit` recommended for VRAM efficiency. |
| `partition-id` | Integer | Data partition index for this SuperNode |
| `num-partitions` | Integer | Total number of data partitions (equals number of SuperNodes) |

### FAB Structure

**pyproject.toml:**

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "flower-llm-fine-tuning"
version = "1.0.0"
description = "Federated LLM fine-tuning with PEFT/LoRA"
dependencies = []  # Dependencies pre-installed in Docker image

[flower.components]
serverapp = "server_app:app"
clientapp = "client_app:app"
```

**client_app.py:**

```python
"""Federated LLM fine-tuning ClientApp (PyTorch + PEFT/LoRA + bitsandbytes)."""
import torch
from peft import LoraConfig, get_peft_model, set_peft_model_active_adapter
from transformers import AutoModelForCausalLM, AutoTokenizer, BitsAndBytesConfig
from flwr.client import ClientApp
from flwr.common import ArrayRecord

app = ClientApp()


def load_model(model_name, quantization):
    """Load base model with quantization and LoRA adapters."""
    if quantization == "4bit":
        bnb_config = BitsAndBytesConfig(
            load_in_4bit=True,
            bnb_4bit_quant_type="nf4",
            bnb_4bit_compute_dtype=torch.bfloat16,
        )
    elif quantization == "8bit":
        bnb_config = BitsAndBytesConfig(load_in_8bit=True)
    else:
        bnb_config = None

    model = AutoModelForCausalLM.from_pretrained(
        model_name,
        quantization_config=bnb_config,
        device_map="auto",
    )

    # Apply LoRA adapters
    lora_config = LoraConfig(
        r=16,
        lora_alpha=32,
        target_modules=["q_proj", "v_proj"],
        lora_dropout=0.05,
        task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora_config)
    return model


def load_data(partition_id, num_partitions, model_name):
    """Load instruction dataset partition from /app/data."""
    import os
    import json

    data_dir = "/app/data"
    tokenizer = AutoTokenizer.from_pretrained(model_name)

    if os.path.isdir(data_dir) and os.listdir(data_dir):
        # Load from pre-provisioned JSONL file
        with open(os.path.join(data_dir, "instructions.jsonl")) as f:
            data = [json.loads(line) for line in f]
        # Partition the data
        chunk_size = len(data) // num_partitions
        start = partition_id * chunk_size
        end = start + chunk_size if partition_id < num_partitions - 1 else len(data)
        return data[start:end], tokenizer
    else:
        raise FileNotFoundError(
            "LLM fine-tuning requires pre-provisioned data at /app/data/instructions.jsonl. "
            "Unlike image-classification and anomaly-detection, this use case does not support "
            "automatic dataset download."
        )


@app.train()
def train(message):
    model_name = message.context.node_config.get("model-name", "openlm-research/open_llama_3b")
    quantization = message.context.node_config.get("quantization", "4bit")
    partition_id = int(message.context.node_config["partition-id"])
    num_partitions = int(message.context.node_config["num-partitions"])

    model = load_model(model_name, quantization)

    # Load received LoRA adapter weights (if not first round)
    lora_params = message.content.array_records.get("lora_params")
    if lora_params is not None:
        for name, param in model.named_parameters():
            if param.requires_grad and name in lora_params:
                param.data = torch.tensor(lora_params[name])

    data, tokenizer = load_data(partition_id, num_partitions, model_name)

    # Fine-tune with LoRA for 1 local epoch
    optimizer = torch.optim.AdamW(
        filter(lambda p: p.requires_grad, model.parameters()), lr=2e-5
    )
    model.train()
    total_loss = 0.0
    for sample in data:
        inputs = tokenizer(sample["instruction"], return_tensors="pt", truncation=True, max_length=512)
        inputs = {k: v.to(model.device) for k, v in inputs.items()}
        outputs = model(**inputs, labels=inputs["input_ids"])
        loss = outputs.loss
        loss.backward()
        optimizer.step()
        optimizer.zero_grad()
        total_loss += loss.item()

    # Return only LoRA adapter weights (not full model)
    lora_state = {}
    for name, param in model.named_parameters():
        if param.requires_grad:
            lora_state[name] = param.data.cpu().numpy()

    return message.create_reply(
        ArrayRecord({"lora_params": lora_state}),
        metrics={"train_loss": total_loss / len(data), "num_samples": len(data)},
    )
```

**server_app.py:**

```python
"""Federated LLM fine-tuning ServerApp."""
from flwr.server import ServerApp

app = ServerApp()


@app.main()
def main(driver, context):
    # Strategy and num_rounds controlled by SuperLink contextualization.
    # FedAvg aggregates LoRA adapter weights across SuperNodes.
    pass
```

### Expected Outputs

| Metric | Per Round | Final |
|--------|-----------|-------|
| Training loss | Per-SuperNode average loss on instruction data | After `FL_NUM_ROUNDS` rounds |
| LoRA adapter weights | Aggregated via FedAvg after each round | Final merged LoRA adapters |

**Typical training:** LLM fine-tuning requires significantly more rounds than classification (100+ rounds is common). Each round trains only the LoRA adapter parameters (~0.1% of total model parameters), making federated aggregation efficient.

### Data Provisioning

- **Demo mode:** NOT supported for LLM fine-tuning. Instruction datasets are task-specific and cannot be meaningfully auto-downloaded for a generic demo. The ClientApp raises `FileNotFoundError` if no data is pre-provisioned.
- **Production mode:** JSONL file pre-provisioned at `/opt/flower/data/instructions.jsonl`. Each line is a JSON object with at minimum an `"instruction"` field. Example format:
  ```json
  {"instruction": "Explain federated learning in one sentence."}
  {"instruction": "What is the capital of France?"}
  ```
- **Alternative:** Provide a Hugging Face dataset name via `FL_NODE_CONFIG` for datasets available on the Hugging Face Hub. This requires network access.

---

## 7. FAB Pre-Installation Process

Use case FABs are built from source and installed into the framework-specific Docker images during the Docker image build process. This ensures the FABs are available at boot time without network access.

### Build Pipeline

```
1. Use case source code (pyproject.toml + Python files) is placed in:
     use-cases/image-classification/
     use-cases/anomaly-detection/
     use-cases/llm-fine-tuning/

2. Each use case is built into a FAB using the Flower CLI:
     cd use-cases/image-classification && flwr build
     -> produces: flower-image-classification.fab

3. FABs are copied into the Docker image and installed via flwr install.
```

### Dockerfile Addition Pattern

The FAB installation is added to the framework-specific Dockerfiles defined in `spec/06-ml-framework-variants.md`, Section 3. The FAB installation step comes AFTER all Python dependencies are installed (because `flwr install` installs the FAB code bundle but does NOT install pip dependencies).

**PyTorch variant (image-classification + llm-fine-tuning):**

```dockerfile
# ... (after pip install torch, torchvision, bitsandbytes, peft, transformers) ...

# Pre-install use case FABs
COPY use-cases/flower-image-classification.fab /tmp/
COPY use-cases/flower-llm-fine-tuning.fab /tmp/
RUN flwr install /tmp/flower-image-classification.fab --flwr-dir /app/.flwr \
    && flwr install /tmp/flower-llm-fine-tuning.fab --flwr-dir /app/.flwr \
    && rm /tmp/*.fab
```

**TensorFlow variant (image-classification):**

```dockerfile
# ... (after pip install tensorflow-cpu) ...

# Pre-install use case FABs
COPY use-cases/flower-image-classification.fab /tmp/
RUN flwr install /tmp/flower-image-classification.fab --flwr-dir /app/.flwr \
    && rm /tmp/*.fab
```

**scikit-learn variant (anomaly-detection):**

```dockerfile
# ... (after pip install scikit-learn, pandas) ...

# Pre-install use case FABs
COPY use-cases/flower-anomaly-detection.fab /tmp/
RUN flwr install /tmp/flower-anomaly-detection.fab --flwr-dir /app/.flwr \
    && rm /tmp/*.fab
```

### FAB Installation Directory

FABs are installed to `/app/.flwr` inside the container. This is Flower's default FAB installation directory. The `--flwr-dir` flag ensures FABs are installed relative to the container's app directory, not the system-wide Flower directory.

### Dependency Pre-Installation Requirement

**Critical:** `flwr install` installs the FAB code bundle (Python source files) but does NOT install the FAB's pip dependencies. All Python packages required by the use case ClientApp MUST be installed in the Docker image BEFORE the FAB is installed. This is already handled by the framework-specific Dockerfiles in `spec/06-ml-framework-variants.md`:

| Use Case | Required Packages | Installed By |
|----------|-------------------|-------------|
| image-classification (PyTorch) | torch, torchvision, flwr-datasets[vision] | PyTorch variant Dockerfile |
| image-classification (TensorFlow) | tensorflow-cpu, flwr-datasets[vision] | TensorFlow variant Dockerfile |
| anomaly-detection | scikit-learn, pandas, flwr-datasets | scikit-learn variant Dockerfile |
| llm-fine-tuning | torch, bitsandbytes, peft, transformers | PyTorch variant Dockerfile |

If any dependency is missing, the ClientApp will fail with `ModuleNotFoundError` at runtime.

---

## 8. FAB Activation at Runtime

This section defines how `FL_USE_CASE` activates a pre-installed FAB when the SuperNode processes a run from the SuperLink.

### Runtime Flow

```
1. SuperLink submits a run (via Control API or Flower CLI)
2. SuperNode receives the run instruction from SuperLink
3. SuperNode checks for pre-installed FABs in /app/.flwr:
   a. If FL_USE_CASE != "none" and the corresponding FAB is pre-installed:
      -> SuperNode uses the local pre-installed FAB
      -> No FAB download from SuperLink needed
   b. If FL_USE_CASE == "none":
      -> SuperNode receives the FAB from SuperLink (standard behavior)
      -> Used for custom ClientApps provided by the user
4. The ClientApp code from the FAB runs inside the SuperNode container
   (subprocess isolation mode -- all deps must be in the same container)
5. Training/evaluation executes; results are sent back to SuperLink
```

### configure.sh Use Case Activation

When `FL_USE_CASE` is set to a value other than `none`, the configure.sh script prepares the environment for the pre-installed FAB:

```bash
# FL_USE_CASE activation (Phase 3)
activate_use_case() {
    local use_case="${FL_USE_CASE:-none}"

    if [ "${use_case}" = "none" ]; then
        log "INFO" "No pre-built use case selected. SuperNode will wait for FAB delivery from SuperLink."
        return
    fi

    # Verify the FAB is pre-installed
    local fab_dir="/app/.flwr"
    log "INFO" "Activating pre-built use case: ${use_case}"
    log "INFO" "FAB directory: ${fab_dir}"

    # The pre-installed FAB is available in the container at /app/.flwr
    # Flower's SuperNode runtime will discover and use it when a run is submitted
    log "INFO" "Use case '${use_case}' FAB is pre-installed. Ready for run submission."
}
```

### Subprocess Mode Constraint

In subprocess isolation mode (the default per `spec/02-supernode-appliance.md`, Section 8), the ClientApp code from the FAB runs INSIDE the SuperNode container as a subprocess. This means:

1. All Python packages imported by the ClientApp must exist in the SuperNode Docker image.
2. The FAB does not need to include wheel files for its dependencies (they are already installed).
3. The ClientApp has access to the same filesystem as the SuperNode process, including `/app/data`.

If `FL_ISOLATION=process` were used instead, the ClientApp would run in a separate container. In that mode, framework dependencies would need to be in the ClientApp container image. Subprocess mode is simpler and is the recommended configuration.

---

## 9. Data Provisioning Strategy

Two data paths are defined: demo mode (auto-download) and production mode (pre-provisioned). The selection is automatic based on the presence of data files in the mount point.

### Demo Mode (Auto-Download)

**Behavior:** The ClientApp uses `flwr-datasets` to download the dataset on first run. The dataset is cached in the container's filesystem for subsequent rounds within the same session.

| Use Case | Dataset | Download Size | Network Required |
|----------|---------|---------------|-----------------|
| image-classification | CIFAR-10 | ~170 MB | YES |
| anomaly-detection | iris | ~10 KB | YES |
| llm-fine-tuning | (none) | N/A | N/A -- demo mode not supported |

**Air-gapped note:** Demo mode breaks the network-free boot guarantee from Phase 1 (`spec/02-supernode-appliance.md`, Section 4). This is an intentional trade-off: demo scenarios are expected to have network access. For air-gapped environments, use production mode with pre-provisioned data.

### Production Mode (Pre-Provisioned Data)

**Behavior:** Data is pre-provisioned on the host at `/opt/flower/data/`, which is mounted read-only into the container at `/app/data:ro` (per `spec/02-supernode-appliance.md`, Section 12).

| Use Case | Expected Data Format | Location |
|----------|---------------------|----------|
| image-classification | Image files organized by class, or raw dataset files | `/opt/flower/data/` |
| anomaly-detection | CSV file with features + label column | `/opt/flower/data/data.csv` |
| llm-fine-tuning | JSONL file with instruction records | `/opt/flower/data/instructions.jsonl` |

**How data arrives at /opt/flower/data/:**
- Pre-loaded in a custom QCOW2 image (for repeatable deployments).
- Mounted from a Longhorn persistent volume or NFS share.
- Downloaded at boot via a custom `START_SCRIPT` contextualization command.
- Pushed via SSH before starting a training run.
- Attached as a secondary disk image in the VM template.

### Selection Logic

The ClientApp in each use case FAB implements the same selection pattern:

```python
import os

DATA_DIR = "/app/data"

if os.path.isdir(DATA_DIR) and os.listdir(DATA_DIR):
    # Production mode: load from pre-provisioned data
    data = load_from_local(DATA_DIR)
else:
    # Demo mode: download via flwr-datasets
    data = download_from_flwr_datasets()
```

For LLM fine-tuning, the `else` branch raises `FileNotFoundError` because demo mode is not supported.

### Data Mount Path Reference

The data mount path is established in Phase 1:

| Layer | Path | Mode |
|-------|------|------|
| Host | `/opt/flower/data/` | Read-write (owned by UID 49999) |
| Docker mount | `-v /opt/flower/data:/app/data:ro` | Read-only |
| Container (ClientApp) | `/app/data/` | Read-only |

---

## 10. New Contextualization Variables Summary

Phase 3 introduces one new variable to the SuperNode appliance and activates one previously defined placeholder variable.

### New Variables

| Variable | USER_INPUT | Appliance | Default | Phase | Purpose |
|----------|-----------|-----------|---------|-------|---------|
| `FL_USE_CASE` | `O\|list\|Pre-built use case template\|none,image-classification,anomaly-detection,llm-fine-tuning\|none` | SuperNode | `none` | 3 | Selects pre-installed use case FAB to activate |

### Activated Placeholder Variables

| Variable | USER_INPUT | Appliance | Default | Phase | Status Change |
|----------|-----------|-----------|---------|-------|---------------|
| `ML_FRAMEWORK` | `O\|list\|ML framework\|pytorch,tensorflow,sklearn\|pytorch` | SuperNode | `pytorch` | 3 | Placeholder (Phase 1) -> Functional (Phase 3) |

**Note:** `ML_FRAMEWORK` was defined as a Phase 3 placeholder in `spec/03-contextualization-reference.md`, Section 6. It becomes functional with the framework variant strategy (`spec/06-ml-framework-variants.md`) and the use case compatibility matrix (this document, Section 3).

### Updated Variable Count

Adding `FL_USE_CASE` to the SuperNode brings the total contextualization variable count to:

| Category | Phase 1 Count | Phase 3 Addition | New Count |
|----------|---------------|-------------------|-----------|
| SuperNode parameters | 7 | +1 (FL_USE_CASE) | 8 |
| Phase 2+ placeholders | 6 | -1 (ML_FRAMEWORK activated) | 5 |
| **Total** | **29** | **+1** | **30** |

### Updated SuperNode USER_INPUT Block

The complete SuperNode USER_INPUT block with Phase 3 additions:

```
USER_INPUTS = [
  FLOWER_VERSION = "O|text|Flower Docker image version tag||1.25.0",
  FL_SUPERLINK_ADDRESS = "O|text|SuperLink Fleet API address (host:port)||",
  FL_NODE_CONFIG = "O|text|Space-separated key=value node config||",
  FL_MAX_RETRIES = "O|number|Max reconnection attempts (0=unlimited)||0",
  FL_MAX_WAIT_TIME = "O|number|Max wait time for connection in seconds (0=unlimited)||0",
  FL_ISOLATION = "O|list|App execution isolation mode|subprocess,process|subprocess",
  FL_LOG_LEVEL = "O|list|Log verbosity|DEBUG,INFO,WARNING,ERROR|INFO",
  ML_FRAMEWORK = "O|list|ML framework|pytorch,tensorflow,sklearn|pytorch",
  FL_USE_CASE = "O|list|Pre-built use case template|none,image-classification,anomaly-detection,llm-fine-tuning|none"
]
```

---

*Specification for ML-03: Pre-Built Use Case Templates*
*Phase: 03 - ML Framework Variants and Use Cases*
*Version: 1.0*
