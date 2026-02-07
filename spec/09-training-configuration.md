# Training Configuration

**Requirements:** ML-01, ML-04
**Phase:** 05 - Training Configuration
**Status:** Specification

---

## 1. Purpose and Scope

This section defines how operators select aggregation strategies, configure strategy-specific parameters, enable model checkpointing, and recover from training failures -- all through OpenNebula contextualization variables. The specification bridges the gap between OpenNebula's infrastructure layer (contextualization, OneFlow) and Flower's application layer (ServerApp, strategy classes, evaluate_fn callbacks).

**What this section covers:**
- Aggregation strategy reference: six supported strategies with algorithm descriptions, parameters, and when-to-use guidance.
- Strategy selection architecture: the complete data flow from `FL_STRATEGY` context variable through `configure.sh` to ServerApp strategy instantiation.
- Strategy-specific contextualization variables: eight new Phase 5 variables with USER_INPUT definitions and validation rules.
- Model checkpointing: the evaluate_fn callback pattern, checkpoint file format, naming convention, volume mount, and storage backend options.
- Resume from checkpoint: loading saved weights as initial_arrays, round counter behavior, and operator workflow.
- Failure recovery: four scenarios (SuperNode crash, SuperLink crash, full redeployment, network partition) and how checkpoints enable resumption.

**What this section does NOT cover:**
- Monitoring and metrics dashboards for training progress (Phase 8).
- Auto-scaling SuperNode count based on training metrics (Phase 9).
- GPU-specific training configuration such as CUDA memory management or multi-GPU partitioning (Phase 6).
- Custom user-provided strategies beyond the six built-in options (operator brings their own ServerApp code).

**Cross-references:**
- SuperLink appliance: [`spec/01-superlink-appliance.md`](01-superlink-appliance.md) -- boot sequence (Section 6), Docker container configuration (Section 7), contextualization parameters (Section 12).
- Contextualization reference: [`spec/03-contextualization-reference.md`](03-contextualization-reference.md) -- variable definitions, USER_INPUT format (Section 2), validation strategy (Section 8).
- Use case templates: [`spec/07-use-case-templates.md`](07-use-case-templates.md) -- pre-built FABs that implement the strategy factory and checkpoint logic.
- Single-site orchestration: [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md) -- OneFlow service template (Section 3), user_inputs hierarchy (Section 2).

---

## 2. Aggregation Strategy Reference

Flower provides 15+ built-in strategies in `flwr.server.strategy`. This specification supports six strategies that cover the most common federated learning scenarios: a general-purpose default (FedAvg), a heterogeneity-aware variant (FedProx), an adaptive optimizer (FedAdam), and three byzantine-robust options (Krum, Bulyan, FedTrimmedAvg).

All six strategies share the common constructor parameters `min_fit_clients`, `min_evaluate_clients`, and `min_available_clients` (already defined in Phase 1). Strategy-specific parameters are exposed as new Phase 5 contextualization variables.

### 2.1 FedAvg (Federated Averaging)

**Algorithm:** Computes a weighted average of client model updates, where each client's contribution is weighted by the number of training examples it used. This is the foundational federated learning algorithm.

**When to use:** Default strategy. Works well when data is approximately IID (independently and identically distributed) across clients, and clients have similar compute capabilities. Start here unless you have a specific reason to use another strategy.

**Flower class:** `flwr.server.strategy.FedAvg`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `min_fit_clients` | int | 2 | `FL_MIN_FIT_CLIENTS` (Phase 1) | Minimum clients to start a training round |
| `min_evaluate_clients` | int | 2 | `FL_MIN_EVALUATE_CLIENTS` (Phase 1) | Minimum clients for evaluation |
| `min_available_clients` | int | 2 | `FL_MIN_AVAILABLE_CLIENTS` (Phase 1) | Minimum connected clients before any round |
| `fraction_fit` | float | 1.0 | (not exposed) | Fraction of clients selected for training |
| `fraction_evaluate` | float | 1.0 | (not exposed) | Fraction of clients selected for evaluation |
| `accept_failures` | bool | True | (not exposed) | Continue round even if some clients fail |
| `inplace` | bool | True | (not exposed) | In-place aggregation for memory efficiency |

**No additional variables needed** beyond the Phase 1 parameters. FedAvg is fully configured by the existing `FL_MIN_*` variables.

**Minimum client requirement:** `n >= FL_MIN_AVAILABLE_CLIENTS` (default: 2).

### 2.2 FedProx (Federated Optimization in Heterogeneous Networks)

**Algorithm:** Extends FedAvg by adding a proximal term to each client's local loss function: `L_prox = (mu/2) * ||w - w_global||^2`. This term penalizes local model divergence from the global model, preventing clients with non-IID data or excessive local training from pulling the global model in incompatible directions.

**When to use:** Non-IID data distributions where different clients have fundamentally different data characteristics (e.g., different disease prevalence across hospitals, different customer demographics across regions). Also useful when clients have heterogeneous compute capabilities and perform different amounts of local work per round.

**Flower class:** `flwr.server.strategy.FedProx`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `proximal_mu` | float | 1.0 | `FL_PROXIMAL_MU` (Phase 5) | Proximal regularization strength |
| All FedAvg params | ... | ... | (same as FedAvg) | Inherited from FedAvg |

**Minimum client requirement:** `n >= FL_MIN_AVAILABLE_CLIENTS` (default: 2).

**Important caveats:**

1. **Client-side implementation required.** The Flower FedProx strategy automatically sends `proximal_mu` to clients via the `configure_fit` callback. However, the ClientApp MUST implement the proximal loss term in its training loop. If the ClientApp ignores `proximal_mu` from the fit config, FedProx produces identical results to FedAvg.

2. **Pre-built FAB support.** The pre-built use case FABs (defined in [`spec/07-use-case-templates.md`](07-use-case-templates.md)) SHALL check for `proximal_mu` in the fit configuration and apply the proximal term when present. Custom ClientApps are the operator's responsibility -- this requirement is documented but not enforced at boot time.

3. **Parameter tuning.** `proximal_mu=0.0` makes FedProx mathematically identical to FedAvg. Typical values range from 0.001 (light regularization) to 1.0 (strong regularization). Higher values constrain local models closer to the global model but may slow convergence.

### 2.3 FedAdam (Adaptive Federated Optimization)

**Algorithm:** Applies the Adam optimizer on the server side to aggregate pseudo-gradients (the difference between received client updates and the previous global model). Uses adaptive per-parameter learning rates with momentum, enabling faster convergence on complex loss landscapes.

**When to use:** When convergence is slow with FedAvg, for complex or deep models where per-parameter learning rate adaptation helps, or when the operator wants server-side learning rate control independent of client-side optimization.

**Flower class:** `flwr.server.strategy.FedAdam`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `eta` | float | 0.1 | `FL_SERVER_LR` (Phase 5) | Server-side learning rate |
| `eta_l` | float | 0.1 | `FL_CLIENT_LR` (Phase 5) | Client-side learning rate hint |
| `beta_1` | float | 0.9 | (not exposed) | Adam first moment decay rate |
| `beta_2` | float | 0.99 | (not exposed) | Adam second moment decay rate |
| `tau` | float | 1e-9 | (not exposed) | Adam numerical stability constant |
| All FedAvg params | ... | ... | (same as FedAvg) | Inherited from FedAvg |

**Minimum client requirement:** `n >= FL_MIN_AVAILABLE_CLIENTS` (default: 2).

**Important caveats:**

1. **Requires initial_parameters.** FedAdam (and all FedOpt variants) computes pseudo-gradients relative to a reference point. The ServerApp MUST provide `initial_arrays` when calling `strategy.start()`. Without initial parameters, FedAdam raises a runtime error on the first round. The strategy factory (Section 3) ensures this by always providing initial model weights.

2. **Learning rate exposure.** Only `eta` (server-side) and `eta_l` (client-side) are exposed as contextualization variables. The momentum parameters `beta_1`, `beta_2`, and `tau` are rarely tuned and kept at their defaults. Operators who need to adjust them should provide a custom ServerApp.

### 2.4 Krum (Byzantine-Robust Selection)

**Algorithm:** Selects the single client update that is closest to the majority of other updates (measured by Euclidean distance), excluding potential outliers. Designed to tolerate up to `f` byzantine (malicious or faulty) clients. In the selection step, Krum computes the sum of distances from each update to its `n - f - 2` nearest neighbors and selects the update with the smallest sum.

**When to use:** When some clients may be compromised, produce faulty updates (due to hardware errors or data corruption), or when data poisoning is a concern. Krum provides strong theoretical guarantees against byzantine failures.

**Flower class:** `flwr.server.strategy.Krum`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `num_malicious_clients` | int | 0 | `FL_NUM_MALICIOUS` (Phase 5) | Expected number of byzantine clients |
| `num_clients_to_keep` | int | 0 | (not exposed) | 0 = standard Krum; >0 = Multi-Krum |
| All FedAvg params | ... | ... | (same as FedAvg) | Inherited from FedAvg |

**Minimum client requirement:** `n >= 2*f + 3` where `n` is `FL_MIN_AVAILABLE_CLIENTS` and `f` is `FL_NUM_MALICIOUS`. With `f=1`, at least 5 clients are needed. With `f=0` (default), Krum behaves as selecting the "most average" update.

**Important caveats:**

1. **Client count constraint is validated at boot time.** If `FL_STRATEGY=Krum` and `FL_NUM_MALICIOUS > 0`, configure.sh validates that `FL_MIN_AVAILABLE_CLIENTS >= 2 * FL_NUM_MALICIOUS + 3`. Failure is fatal -- the appliance will not start with insufficient clients for the byzantine guarantee. See Section 5 for the validation rule.

2. **Standard Krum vs Multi-Krum.** With `num_clients_to_keep=0` (default, not exposed), Krum selects a single "best" update per round. Multi-Krum (positive `num_clients_to_keep`) selects multiple updates and averages them. Multi-Krum is not exposed as a contextualization variable to keep the interface simple; operators who need it should provide a custom ServerApp.

### 2.5 Bulyan (Two-Phase Byzantine-Robust)

**Algorithm:** Phase 1 uses Krum (or another robust selection rule) to select a subset of "good" updates from all received updates. Phase 2 applies a coordinate-wise trimmed mean on the selected subset, further removing potential outlier values at each parameter coordinate. Provides stronger theoretical guarantees than Krum alone.

**When to use:** Higher security requirements than Krum, environments where multiple clients may be compromised simultaneously, or when the operator wants defense-in-depth against byzantine attacks.

**Flower class:** `flwr.server.strategy.Bulyan`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `num_malicious_clients` | int | 0 | `FL_NUM_MALICIOUS` (Phase 5, shared with Krum) | Expected number of byzantine clients |
| All FedAvg params | ... | ... | (same as FedAvg) | Inherited from FedAvg |

**Minimum client requirement:** `n >= 4*f + 3` where `n` is `FL_MIN_AVAILABLE_CLIENTS` and `f` is `FL_NUM_MALICIOUS`. More restrictive than Krum. With `f=1`, at least 7 clients are needed. With `f=2`, at least 11 clients are needed.

**Important caveats:**

1. **Stricter client count than Krum.** The `4*f + 3` requirement means Bulyan is practical only in deployments with many clients. For small federations (< 7 clients), use Krum or FedTrimmedAvg instead.

2. **Same `FL_NUM_MALICIOUS` variable as Krum.** Both Krum and Bulyan use `FL_NUM_MALICIOUS`. The boot-time validation applies the correct formula based on the selected strategy.

### 2.6 FedTrimmedAvg (Trimmed Mean)

**Algorithm:** For each model parameter coordinate, collects values from all client updates, trims the highest and lowest `beta` fraction of values, and averages the remaining center. This coordinate-wise trimmed mean is robust to outlier updates without requiring explicit byzantine client detection.

**When to use:** Simple byzantine robustness with moderate outlier tolerance. Effective when a moderate fraction of clients may produce abnormal updates but the majority are trustworthy. Simpler than Krum/Bulyan with fewer configuration parameters.

**Flower class:** `flwr.server.strategy.FedTrimmedAvg`

| Parameter | Type | Default | Contextualization Variable | Notes |
|-----------|------|---------|---------------------------|-------|
| `beta` | float | 0.2 | `FL_TRIM_BETA` (Phase 5) | Fraction trimmed from each tail |
| All FedAvg params | ... | ... | (same as FedAvg) | Inherited from FedAvg |

**Minimum client requirement:** `n >= FL_MIN_AVAILABLE_CLIENTS` (default: 2). No special formula, but the strategy is most effective with more clients. With `beta=0.2` and 10 clients, 2 lowest and 2 highest values per coordinate are discarded.

**Important caveats:**

1. **Beta range.** `beta` must be in the range `(0.0, 0.5)` exclusive. A value of 0.0 trims nothing (identical to averaging). A value of 0.5 would trim all values, leaving nothing to average. The default `0.2` (20% from each tail) is suitable for environments where up to ~20% of clients may produce outlier updates.

### Strategy Selection Summary

| FL_STRATEGY Value | Flower Class | Extra Variables | Min Clients Formula | Best For |
|-------------------|-------------|----------------|---------------------|----------|
| `FedAvg` | `FedAvg` | None (Phase 1 params suffice) | `>= FL_MIN_AVAILABLE_CLIENTS` | IID data, homogeneous clients |
| `FedProx` | `FedProx` | `FL_PROXIMAL_MU` | `>= FL_MIN_AVAILABLE_CLIENTS` | Non-IID data, heterogeneous clients |
| `FedAdam` | `FedAdam` | `FL_SERVER_LR`, `FL_CLIENT_LR` | `>= FL_MIN_AVAILABLE_CLIENTS` | Complex models, slow convergence |
| `Krum` | `Krum` | `FL_NUM_MALICIOUS` | `>= 2 * FL_NUM_MALICIOUS + 3` | Suspected malicious clients (small f) |
| `Bulyan` | `Bulyan` | `FL_NUM_MALICIOUS` | `>= 4 * FL_NUM_MALICIOUS + 3` | Higher security, many clients |
| `FedTrimmedAvg` | `FedTrimmedAvg` | `FL_TRIM_BETA` | `>= FL_MIN_AVAILABLE_CLIENTS` | Simple outlier robustness |

---

## 3. Strategy Selection Architecture

Strategy selection in Flower CANNOT be done at the Docker or bash layer. The `flwr/superlink` binary does not accept a `--strategy` flag. Strategy selection happens inside the ServerApp code (the FAB), which reads configuration from `context.run_config`. The appliance's role is to bridge `FL_*` context variables into the FAB's run_config.

### Data Flow

```
OpenNebula CONTEXT vars      configure.sh           pyproject.toml / --run-config     ServerApp
FL_STRATEGY=FedProx    --->  generate_run_config  --->  strategy=FedProx          --->  strategy = FedProx(
FL_PROXIMAL_MU=0.1           writes run_config          proximal-mu=0.1                   proximal_mu=0.1,
FL_NUM_ROUNDS=10             key-value pairs             num-server-rounds=10               ...)
FL_MIN_FIT_CLIENTS=2                                     min-fit-clients=2
```

**Step-by-step path:**

1. **Operator sets FL_STRATEGY** in the VM template context variables or OneFlow service user_inputs (SuperLink role).
2. **configure.sh sources context variables** from `/run/one-context/one_env` and validates them (boot Steps 3-4).
3. **configure.sh calls `generate_run_config()`** which maps each `FL_*` variable to a run_config key-value pair, applying strategy-specific logic.
4. **The run_config is passed to the FAB** via the `--run-config` CLI flag when submitting a run, or written to `[tool.flwr.app.config]` in the FAB's `pyproject.toml`.
5. **The ServerApp reads `context.run_config`** in its `@app.main()` function and uses the `STRATEGY_MAP` factory to instantiate the correct strategy class with the correct parameters.

### configure.sh Bridge Function: `generate_run_config()`

The following bash function translates OpenNebula context variables into Flower run_config key-value pairs. It is called during the configure stage of the SuperLink boot sequence.

```bash
# In configure.sh -- bridge FL_* context vars to FAB run_config
generate_run_config() {
    local config=""
    config="${config} strategy=${FL_STRATEGY:-FedAvg}"
    config="${config} num-server-rounds=${FL_NUM_ROUNDS:-3}"
    config="${config} min-fit-clients=${FL_MIN_FIT_CLIENTS:-2}"
    config="${config} min-evaluate-clients=${FL_MIN_EVALUATE_CLIENTS:-2}"
    config="${config} min-available-clients=${FL_MIN_AVAILABLE_CLIENTS:-2}"

    # Strategy-specific parameters
    case "${FL_STRATEGY:-FedAvg}" in
        FedProx)
            config="${config} proximal-mu=${FL_PROXIMAL_MU:-1.0}"
            ;;
        FedAdam)
            config="${config} server-lr=${FL_SERVER_LR:-0.1}"
            config="${config} client-lr=${FL_CLIENT_LR:-0.1}"
            ;;
        Krum|Bulyan)
            config="${config} num-malicious=${FL_NUM_MALICIOUS:-0}"
            ;;
        FedTrimmedAvg)
            config="${config} trim-beta=${FL_TRIM_BETA:-0.2}"
            ;;
    esac

    # Checkpointing
    if [ "${FL_CHECKPOINT_ENABLED:-NO}" = "YES" ]; then
        config="${config} checkpoint-enabled=true"
        config="${config} checkpoint-interval=${FL_CHECKPOINT_INTERVAL:-5}"
        config="${config} checkpoint-path=${FL_CHECKPOINT_PATH:-/app/checkpoints}"
    fi

    echo "$config"
}

# Write to FAB's pyproject.toml or pass via --run-config
RUN_CONFIG=$(generate_run_config)
```

**Key design decisions:**

- The `case` statement ensures strategy-specific parameters are only included when the corresponding strategy is selected. This prevents irrelevant parameters from polluting the run_config.
- Defaults are applied in bash (using `${VAR:-default}`) as a defense-in-depth measure. The ServerApp factory also applies defaults.
- Checkpointing parameters are included in the run_config only when `FL_CHECKPOINT_ENABLED=YES`.

### ServerApp Strategy Factory Pattern: `STRATEGY_MAP`

The ServerApp uses a factory pattern to instantiate the correct strategy class based on the `strategy` key in `context.run_config`. This pattern is implemented in all pre-built FABs (see [`spec/07-use-case-templates.md`](07-use-case-templates.md)).

```python
"""ServerApp with strategy selection from run_config."""
from flwr.server import ServerApp
from flwr.server.strategy import (
    FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg,
)

app = ServerApp()


def _common_params(cfg):
    """Extract common strategy parameters from run_config."""
    return {
        "min_fit_clients": int(cfg.get("min-fit-clients", 2)),
        "min_evaluate_clients": int(cfg.get("min-evaluate-clients", 2)),
        "min_available_clients": int(cfg.get("min-available-clients", 2)),
    }


def _build_fedavg(cfg):
    return FedAvg(**_common_params(cfg))


def _build_fedprox(cfg):
    return FedProx(
        proximal_mu=float(cfg.get("proximal-mu", 1.0)),
        **_common_params(cfg),
    )


def _build_fedadam(cfg):
    return FedAdam(
        eta=float(cfg.get("server-lr", 0.1)),
        eta_l=float(cfg.get("client-lr", 0.1)),
        **_common_params(cfg),
    )


def _build_krum(cfg):
    return Krum(
        num_malicious_clients=int(cfg.get("num-malicious", 0)),
        **_common_params(cfg),
    )


def _build_bulyan(cfg):
    return Bulyan(
        num_malicious_clients=int(cfg.get("num-malicious", 0)),
        **_common_params(cfg),
    )


def _build_fedtrimmedavg(cfg):
    return FedTrimmedAvg(
        beta=float(cfg.get("trim-beta", 0.2)),
        **_common_params(cfg),
    )


STRATEGY_MAP = {
    "FedAvg": _build_fedavg,
    "FedProx": _build_fedprox,
    "FedAdam": _build_fedadam,
    "Krum": _build_krum,
    "Bulyan": _build_bulyan,
    "FedTrimmedAvg": _build_fedtrimmedavg,
}


@app.main()
def main(driver, context):
    cfg = context.run_config
    strategy_name = cfg.get("strategy", "FedAvg")
    num_rounds = int(cfg.get("num-server-rounds", 3))

    # Build strategy from factory
    build_fn = STRATEGY_MAP.get(strategy_name, _build_fedavg)
    strategy = build_fn(cfg)

    # Start training (initial_arrays and evaluate_fn set up elsewhere)
    # ...
```

**Design rationale:**

- **`_common_params` helper** extracts the three shared parameters once, avoiding repetition in each builder function.
- **Builder functions** encapsulate strategy-specific parameter extraction. Adding a new strategy requires only a new builder function and a `STRATEGY_MAP` entry.
- **Default fallback** to `_build_fedavg` ensures that an unrecognized strategy name does not crash the ServerApp (defense-in-depth; boot validation prevents this case).

### Anti-Patterns

| Anti-Pattern | Why It Fails | Correct Approach |
|-------------|-------------|-----------------|
| Hand-rolling strategy selection outside the FAB (e.g., passing `--strategy` to `flwr/superlink`) | The SuperLink binary does NOT accept a `--strategy` flag. Strategy selection MUST happen inside the ServerApp FAB code via `context.run_config`. | Use the `generate_run_config()` bridge in configure.sh and the `STRATEGY_MAP` factory in the ServerApp. |
| Assuming automatic checkpointing exists in Flower | Flower has no built-in "save every N rounds" mechanism. Every checkpoint save is explicit code in the `evaluate_fn` callback. | Implement the `make_checkpoint_fn` pattern (Section 6) in the ServerApp. |
| Mounting checkpoints on SuperNode | Checkpoints are server-side (SuperLink) artifacts. The SuperLink aggregates model weights and saves checkpoints. SuperNodes do NOT save global checkpoints -- they only have ephemeral local training state. | Mount the checkpoint volume on the SuperLink VM only. SuperNode has no checkpoint-related configuration. |
| Using in-container paths for FL_CHECKPOINT_PATH | The contextualization variable value is used inside the container. The Docker volume mount maps the host path to the container path. Setting a host path (e.g., `/opt/flower/checkpoints`) in FL_CHECKPOINT_PATH would create an unmapped directory inside the container. | Use container-relative paths. The default `/app/checkpoints` is correct because the volume mount maps `/opt/flower/checkpoints` (host) to `/app/checkpoints` (container). |

---

## 4. Strategy-Specific Parameter Variables (Phase 5)

Phase 5 introduces eight new contextualization variables for the SuperLink appliance. All are optional. None affect the SuperNode appliance (all new variables are server-side).

### New Variable Definitions

| # | Variable | USER_INPUT Definition | Type | Default | Validation Rule | Flower Mapping | Applies When |
|---|----------|----------------------|------|---------|-----------------|----------------|-------------|
| 1 | `FL_PROXIMAL_MU` | `O\|number-float\|FedProx proximal regularization term (mu)\|\|1.0` | number-float | `1.0` | Non-negative float (>=0.0) | Strategy param: `proximal_mu` | `FL_STRATEGY=FedProx` |
| 2 | `FL_SERVER_LR` | `O\|number-float\|Server-side learning rate (FedAdam)\|\|0.1` | number-float | `0.1` | Positive float (>0.0) | Strategy param: `eta` | `FL_STRATEGY=FedAdam` |
| 3 | `FL_CLIENT_LR` | `O\|number-float\|Client-side learning rate (FedAdam)\|\|0.1` | number-float | `0.1` | Positive float (>0.0) | Strategy param: `eta_l` | `FL_STRATEGY=FedAdam` |
| 4 | `FL_NUM_MALICIOUS` | `O\|number\|Expected number of malicious clients (Krum/Bulyan)\|\|0` | number | `0` | Non-negative integer (>=0) | Strategy param: `num_malicious_clients` | `FL_STRATEGY=Krum` or `FL_STRATEGY=Bulyan` |
| 5 | `FL_TRIM_BETA` | `O\|number-float\|Fraction to trim from each tail (FedTrimmedAvg)\|\|0.2` | number-float | `0.2` | Float in range (0.0, 0.5) exclusive | Strategy param: `beta` | `FL_STRATEGY=FedTrimmedAvg` |
| 6 | `FL_CHECKPOINT_ENABLED` | `O\|boolean\|Enable model checkpointing\|\|NO` | boolean | `NO` | YES or NO | ServerApp: checkpoint save logic | Always (SuperLink only) |
| 7 | `FL_CHECKPOINT_INTERVAL` | `O\|number\|Save checkpoint every N rounds\|\|5` | number | `5` | Positive integer (>0) | ServerApp: `checkpoint_interval` | `FL_CHECKPOINT_ENABLED=YES` |
| 8 | `FL_CHECKPOINT_PATH` | `O\|text\|Checkpoint directory (container path)\|\|/app/checkpoints` | text | `/app/checkpoints` | Non-empty string | ServerApp: checkpoint save path | `FL_CHECKPOINT_ENABLED=YES` |

### Updated FL_STRATEGY Variable (Phase 5 Extension)

The Phase 1 definition of `FL_STRATEGY` is extended from 3 options to 6 options to include the byzantine-robust strategies:

**Phase 1 definition:**
```
FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam|FedAvg"
```

**Phase 5 updated definition:**
```
FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg|FedAvg"
```

This change updates the dropdown in the Sunstone UI to include all six strategies while keeping FedAvg as the default.

### SuperLink USER_INPUT Block Addition (Phase 5 Variables)

These variables are added to the SuperLink role-level user_inputs in the OneFlow service template (see [`spec/08-single-site-orchestration.md`](08-single-site-orchestration.md), Section 3):

```
FL_PROXIMAL_MU = "O|number-float|FedProx proximal regularization term (mu)||1.0"
FL_SERVER_LR = "O|number-float|Server-side learning rate (FedAdam)||0.1"
FL_CLIENT_LR = "O|number-float|Client-side learning rate (FedAdam)||0.1"
FL_NUM_MALICIOUS = "O|number|Expected number of malicious clients (Krum/Bulyan)||0"
FL_TRIM_BETA = "O|number-float|Fraction to trim from each tail (FedTrimmedAvg)||0.2"
FL_CHECKPOINT_ENABLED = "O|boolean|Enable model checkpointing||NO"
FL_CHECKPOINT_INTERVAL = "O|number|Save checkpoint every N rounds||5"
FL_CHECKPOINT_PATH = "O|text|Checkpoint directory (container path)||/app/checkpoints"
```

### Variable Placement in OneFlow Service Template

All eight new variables are SuperLink role-level user_inputs. They are not placed at the service level because they are meaningful only to the SuperLink, not to SuperNodes.

| Variable | Level | Rationale |
|----------|-------|-----------|
| `FL_PROXIMAL_MU` | SuperLink role | Server-side strategy parameter |
| `FL_SERVER_LR` | SuperLink role | Server-side optimizer parameter |
| `FL_CLIENT_LR` | SuperLink role | Forwarded to clients via strategy config, but configured at the server |
| `FL_NUM_MALICIOUS` | SuperLink role | Server-side aggregation parameter |
| `FL_TRIM_BETA` | SuperLink role | Server-side aggregation parameter |
| `FL_CHECKPOINT_ENABLED` | SuperLink role | Only the SuperLink saves checkpoints |
| `FL_CHECKPOINT_INTERVAL` | SuperLink role | Only the SuperLink saves checkpoints |
| `FL_CHECKPOINT_PATH` | SuperLink role | Only the SuperLink saves checkpoints |

### Updated Variable Count

Adding 8 Phase 5 variables to the SuperLink brings the total contextualization variable count to:

| Category | Previous Count | Phase 5 Addition | New Count |
|----------|---------------|------------------|-----------|
| SuperLink parameters | 11 | +8 | 19 |
| **Total project variables** | **30** | **+8** | **38** |

---

## 5. Strategy Validation Rules

Boot-time validation in `configure.sh` for Phase 5 variables follows the same fail-fast approach defined in [`spec/03-contextualization-reference.md`](03-contextualization-reference.md), Section 8. Strategy-specific parameters are validated only when `FL_STRATEGY` matches; irrelevant parameters are logged at INFO level and ignored.

### Validation Rules by Variable

| Variable | Rule | Error Message | Condition |
|----------|------|---------------|-----------|
| `FL_PROXIMAL_MU` | Non-negative float (>=0.0) | `"Invalid FL_PROXIMAL_MU: '${VALUE}'. Must be a non-negative float."` | Validated always; warning if `FL_STRATEGY != FedProx` |
| `FL_SERVER_LR` | Positive float (>0.0) | `"Invalid FL_SERVER_LR: '${VALUE}'. Must be a positive float."` | Validated always; warning if `FL_STRATEGY != FedAdam` |
| `FL_CLIENT_LR` | Positive float (>0.0) | `"Invalid FL_CLIENT_LR: '${VALUE}'. Must be a positive float."` | Validated always; warning if `FL_STRATEGY != FedAdam` |
| `FL_NUM_MALICIOUS` | Non-negative integer (>=0) | `"Invalid FL_NUM_MALICIOUS: '${VALUE}'. Must be a non-negative integer."` | Validated always; additional constraint check when `FL_STRATEGY=Krum` or `Bulyan` |
| `FL_TRIM_BETA` | Float in range (0.0, 0.5) exclusive | `"Invalid FL_TRIM_BETA: '${VALUE}'. Must be a float between 0.0 and 0.5 (exclusive)."` | Validated always; warning if `FL_STRATEGY != FedTrimmedAvg` |
| `FL_CHECKPOINT_ENABLED` | YES or NO | `"Invalid FL_CHECKPOINT_ENABLED: '${VALUE}'. Must be YES or NO."` | Always |
| `FL_CHECKPOINT_INTERVAL` | Positive integer (>0) | `"Invalid FL_CHECKPOINT_INTERVAL: '${VALUE}'. Must be a positive integer."` | Ignored if `FL_CHECKPOINT_ENABLED != YES` |
| `FL_CHECKPOINT_PATH` | Non-empty string | `"FL_CHECKPOINT_PATH cannot be empty."` | Ignored if `FL_CHECKPOINT_ENABLED != YES` |

### Byzantine Client Count Validation

When `FL_STRATEGY` is Krum or Bulyan, the minimum client count is validated against the mathematical requirement of the selected strategy:

| Strategy | Formula | Minimum n for f=1 | Minimum n for f=2 |
|----------|---------|--------------------|--------------------|
| Krum | `n >= 2*f + 3` | 5 | 7 |
| Bulyan | `n >= 4*f + 3` | 7 | 11 |

Where `n` = `FL_MIN_AVAILABLE_CLIENTS` and `f` = `FL_NUM_MALICIOUS`.

### Validation Pseudocode

```bash
# Phase 5 validation additions to configure.sh validate_config()
validate_phase5_config() {
    local errors=0

    # --- Type validations (always run) ---

    # FL_PROXIMAL_MU: non-negative float
    if [ -n "$FL_PROXIMAL_MU" ]; then
        if ! [[ "$FL_PROXIMAL_MU" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            log "ERROR" "Invalid FL_PROXIMAL_MU: '${FL_PROXIMAL_MU}'. Must be a non-negative float."
            errors=$((errors + 1))
        fi
    fi

    # FL_SERVER_LR: positive float
    if [ -n "$FL_SERVER_LR" ]; then
        if ! [[ "$FL_SERVER_LR" =~ ^[0-9]*\.?[0-9]+$ ]] || \
           [ "$(echo "$FL_SERVER_LR <= 0" | bc -l 2>/dev/null)" = "1" ]; then
            log "ERROR" "Invalid FL_SERVER_LR: '${FL_SERVER_LR}'. Must be a positive float."
            errors=$((errors + 1))
        fi
    fi

    # FL_CLIENT_LR: positive float
    if [ -n "$FL_CLIENT_LR" ]; then
        if ! [[ "$FL_CLIENT_LR" =~ ^[0-9]*\.?[0-9]+$ ]] || \
           [ "$(echo "$FL_CLIENT_LR <= 0" | bc -l 2>/dev/null)" = "1" ]; then
            log "ERROR" "Invalid FL_CLIENT_LR: '${FL_CLIENT_LR}'. Must be a positive float."
            errors=$((errors + 1))
        fi
    fi

    # FL_NUM_MALICIOUS: non-negative integer
    if [ -n "$FL_NUM_MALICIOUS" ]; then
        if ! [[ "$FL_NUM_MALICIOUS" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Invalid FL_NUM_MALICIOUS: '${FL_NUM_MALICIOUS}'. Must be a non-negative integer."
            errors=$((errors + 1))
        fi
    fi

    # FL_TRIM_BETA: float in range (0.0, 0.5) exclusive
    if [ -n "$FL_TRIM_BETA" ]; then
        if ! [[ "$FL_TRIM_BETA" =~ ^[0-9]*\.?[0-9]+$ ]] || \
           [ "$(echo "$FL_TRIM_BETA <= 0" | bc -l 2>/dev/null)" = "1" ] || \
           [ "$(echo "$FL_TRIM_BETA >= 0.5" | bc -l 2>/dev/null)" = "1" ]; then
            log "ERROR" "Invalid FL_TRIM_BETA: '${FL_TRIM_BETA}'. Must be a float between 0.0 and 0.5 (exclusive)."
            errors=$((errors + 1))
        fi
    fi

    # FL_CHECKPOINT_ENABLED: YES or NO
    if [ -n "$FL_CHECKPOINT_ENABLED" ]; then
        case "${FL_CHECKPOINT_ENABLED}" in
            YES|NO) ;;
            *) log "ERROR" "Invalid FL_CHECKPOINT_ENABLED: '${FL_CHECKPOINT_ENABLED}'. Must be YES or NO."
               errors=$((errors + 1)) ;;
        esac
    fi

    # FL_CHECKPOINT_INTERVAL: positive integer (only if checkpointing enabled)
    if [ "${FL_CHECKPOINT_ENABLED:-NO}" = "YES" ]; then
        if [ -n "$FL_CHECKPOINT_INTERVAL" ] && ! [[ "$FL_CHECKPOINT_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
            log "ERROR" "Invalid FL_CHECKPOINT_INTERVAL: '${FL_CHECKPOINT_INTERVAL}'. Must be a positive integer."
            errors=$((errors + 1))
        fi
        if [ -z "${FL_CHECKPOINT_PATH}" ]; then
            log "ERROR" "FL_CHECKPOINT_PATH cannot be empty when FL_CHECKPOINT_ENABLED=YES."
            errors=$((errors + 1))
        fi
    fi

    # --- Strategy-specific semantic validations ---

    # FL_STRATEGY enum (Phase 5 extended)
    case "${FL_STRATEGY:-FedAvg}" in
        FedAvg|FedProx|FedAdam|Krum|Bulyan|FedTrimmedAvg) ;;
        *) log "ERROR" "Unknown FL_STRATEGY: '${FL_STRATEGY}'. Valid options: FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg."
           errors=$((errors + 1)) ;;
    esac

    # Conditional warnings: strategy-specific params set for wrong strategy
    if [ -n "$FL_PROXIMAL_MU" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedProx" ]; then
        log "INFO" "FL_PROXIMAL_MU is set but FL_STRATEGY is '${FL_STRATEGY:-FedAvg}' (not FedProx). Parameter will be ignored."
    fi
    if [ -n "$FL_SERVER_LR" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedAdam" ]; then
        log "INFO" "FL_SERVER_LR is set but FL_STRATEGY is '${FL_STRATEGY:-FedAvg}' (not FedAdam). Parameter will be ignored."
    fi
    if [ -n "$FL_CLIENT_LR" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedAdam" ]; then
        log "INFO" "FL_CLIENT_LR is set but FL_STRATEGY is '${FL_STRATEGY:-FedAvg}' (not FedAdam). Parameter will be ignored."
    fi
    if [ -n "$FL_NUM_MALICIOUS" ] && [ "${FL_STRATEGY:-FedAvg}" != "Krum" ] && [ "${FL_STRATEGY:-FedAvg}" != "Bulyan" ]; then
        log "INFO" "FL_NUM_MALICIOUS is set but FL_STRATEGY is '${FL_STRATEGY:-FedAvg}' (not Krum or Bulyan). Parameter will be ignored."
    fi
    if [ -n "$FL_TRIM_BETA" ] && [ "${FL_STRATEGY:-FedAvg}" != "FedTrimmedAvg" ]; then
        log "INFO" "FL_TRIM_BETA is set but FL_STRATEGY is '${FL_STRATEGY:-FedAvg}' (not FedTrimmedAvg). Parameter will be ignored."
    fi

    # Byzantine client count validation for Krum and Bulyan
    local n="${FL_MIN_AVAILABLE_CLIENTS:-2}"
    local f="${FL_NUM_MALICIOUS:-0}"

    if [ "${FL_STRATEGY:-FedAvg}" = "Krum" ] && [ "$f" -gt 0 ] 2>/dev/null; then
        local min_n=$((2 * f + 3))
        if [ "$n" -lt "$min_n" ]; then
            log "ERROR" "Krum requires n >= 2*f+3 clients. FL_MIN_AVAILABLE_CLIENTS=$n but FL_NUM_MALICIOUS=$f requires n >= $min_n."
            errors=$((errors + 1))
        fi
    fi

    if [ "${FL_STRATEGY:-FedAvg}" = "Bulyan" ] && [ "$f" -gt 0 ] 2>/dev/null; then
        local min_n=$((4 * f + 3))
        if [ "$n" -lt "$min_n" ]; then
            log "ERROR" "Bulyan requires n >= 4*f+3 clients. FL_MIN_AVAILABLE_CLIENTS=$n but FL_NUM_MALICIOUS=$f requires n >= $min_n."
            errors=$((errors + 1))
        fi
    fi

    # FedProx client-side notice
    if [ "${FL_STRATEGY:-FedAvg}" = "FedProx" ]; then
        log "INFO" "FedProx selected. Pre-built FABs support the proximal term. Custom ClientApps must implement the proximal loss term manually: L += (mu/2) * ||w - w_global||^2."
    fi

    # Abort on errors
    if [ $errors -gt 0 ]; then
        log "FATAL" "$errors Phase 5 configuration error(s). Aborting boot."
        exit 1
    fi

    log "INFO" "Phase 5 configuration validation passed."
}
```

### Validation Principles (Phase 5 Additions)

1. **Type validation always runs.** Even if a variable is irrelevant to the selected strategy, its format is validated. This catches typos early and ensures the value is correct if the operator later switches strategies.

2. **Semantic validation is conditional.** Byzantine client count checks (`n >= 2f+3`, `n >= 4f+3`) apply only when the corresponding strategy is selected. Irrelevant parameters generate an INFO log, not an error.

3. **FedProx client notice.** When FedProx is selected, configure.sh logs a reminder that the proximal term must be implemented in the ClientApp. This is informational, not a validation failure.

---

## 6. Model Checkpointing

Flower does NOT have built-in automatic checkpointing. There is no "save every N rounds" flag in the Flower configuration. Checkpointing requires explicit implementation in the ServerApp's `evaluate_fn` callback. This section defines the complete checkpointing mechanism for the appliance's pre-built FABs.

### 6.1 Checkpoint File Format

Flower uses `ArrayRecord` as its internal container for model parameters. ArrayRecord can convert to framework-specific formats:

| Framework | Conversion Method | File Extension | Example Filename |
|-----------|------------------|---------------|-----------------|
| PyTorch | `arrays.to_torch_state_dict()` + `torch.save()` | `.pt` | `checkpoint_round_10.pt` |
| TensorFlow | `arrays.to_numpy_ndarrays()` + `model.save()` | `.keras` | `checkpoint_round_10.keras` |
| scikit-learn | `arrays.to_numpy_ndarrays()` + `numpy.savez()` | `.npz` | `checkpoint_round_10.npz` |

**Recommended default: `.npz` (NumPy).** The `.npz` format is framework-agnostic because `ArrayRecord` can always convert to NumPy ndarrays regardless of the ML framework used by clients. Framework-specific formats (`.pt`, `.keras`) can be used by custom ServerApps, but the pre-built FABs use `.npz` for maximum portability.

### 6.2 Checkpoint Naming Convention

```
/app/checkpoints/
    checkpoint_round_{N}.npz       # Periodic checkpoint (round N)
    checkpoint_latest.npz          # Symlink to most recent checkpoint
    checkpoint_latest.json         # Metadata: round, timestamp, num_arrays
```

**Naming rationale:**
- `checkpoint_round_{N}.npz` provides round-specific files for debugging and rollback.
- `checkpoint_latest.npz` (symlink) provides a stable path for the resume workflow without needing to search for the highest-numbered file.
- `checkpoint_latest.json` stores metadata for operational visibility (which round was saved, when, how many parameter arrays).

### 6.3 Checkpoint evaluate_fn Implementation

The `make_checkpoint_fn` function creates an `evaluate_fn` callback that saves model weights to disk at configurable intervals. This function is called from the ServerApp's `@app.main()` entry point.

```python
import os
import json
import numpy as np
from datetime import datetime, timezone


def make_checkpoint_fn(interval, total_rounds, path):
    """Create evaluate_fn that saves checkpoints to disk.

    Args:
        interval: Save every N rounds (from FL_CHECKPOINT_INTERVAL).
        total_rounds: Total training rounds (from FL_NUM_ROUNDS).
        path: Checkpoint directory (from FL_CHECKPOINT_PATH).

    Returns:
        evaluate_fn callback for strategy.start().
    """
    os.makedirs(path, exist_ok=True)

    def evaluate_fn(server_round, arrays):
        should_save = (
            server_round != 0
            and (server_round == total_rounds or server_round % interval == 0)
        )
        if should_save:
            # Save model weights as NumPy arrays (framework-agnostic)
            ndarrays = arrays.to_numpy_ndarrays()
            checkpoint_file = os.path.join(
                path, f"checkpoint_round_{server_round}.npz"
            )
            np.savez(checkpoint_file, *ndarrays)

            # Save metadata
            metadata = {
                "round": server_round,
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "num_arrays": len(ndarrays),
            }
            metadata_file = os.path.join(path, "checkpoint_latest.json")
            with open(metadata_file, "w") as f:
                json.dump(metadata, f, indent=2)

            # Update latest symlink
            latest = os.path.join(path, "checkpoint_latest.npz")
            if os.path.islink(latest):
                os.unlink(latest)
            os.symlink(
                f"checkpoint_round_{server_round}.npz",
                latest,
            )

        return MetricRecord()

    return evaluate_fn
```

**Save triggers:**
- **Every N rounds** where N = `FL_CHECKPOINT_INTERVAL`. Default: every 5 rounds.
- **Always on the final round** (`server_round == total_rounds`). This ensures the final model is always checkpointed regardless of interval alignment.
- **Never on round 0.** Round 0 is the initial evaluation before any training occurs.

### 6.4 Checkpoint Volume Mount

Checkpoints are written by the SuperLink container. The host directory must exist and be owned by UID 49999 (the Flower container's `app` user).

**Host path:** `/opt/flower/checkpoints`
**Container path:** `/app/checkpoints`
**Mount mode:** Read-write (`:rw`)

This follows the same pattern as the existing state volume mount (`/opt/flower/state:/app/state`).

### 6.5 configure.sh Additions for Checkpointing

When `FL_CHECKPOINT_ENABLED=YES`, configure.sh performs the following additional steps during the SuperLink boot sequence:

```bash
# Checkpoint directory setup (Phase 5)
if [ "${FL_CHECKPOINT_ENABLED:-NO}" = "YES" ]; then
    log "INFO" "Checkpointing enabled. Setting up checkpoint directory."
    mkdir -p /opt/flower/checkpoints
    chown 49999:49999 /opt/flower/checkpoints
    log "INFO" "Checkpoint directory: /opt/flower/checkpoints (-> /app/checkpoints in container)"
fi
```

**Docker run command extension:**

When `FL_CHECKPOINT_ENABLED=YES`, the Docker run command (see [`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 7) is extended with the checkpoint volume mount:

```bash
# Conditional checkpoint volume mount
CHECKPOINT_MOUNT=""
if [ "${FL_CHECKPOINT_ENABLED:-NO}" = "YES" ]; then
    CHECKPOINT_MOUNT="-v /opt/flower/checkpoints:/app/checkpoints:rw"
fi

docker run -d \
  --name flower-superlink \
  --restart unless-stopped \
  --env-file /opt/flower/config/superlink.env \
  -p 9091:9091 \
  -p 9092:9092 \
  -p 9093:9093 \
  -v /opt/flower/state:/app/state \
  ${CHECKPOINT_MOUNT} \
  flwr/superlink:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --isolation subprocess \
  --fleet-api-address ${FL_FLEET_API_ADDRESS:-0.0.0.0:9092} \
  --database ${FL_DATABASE:-state/state.db}
```

The same extension applies to the systemd unit file template (`ExecStart` line in [`spec/01-superlink-appliance.md`](01-superlink-appliance.md), Section 8).

---

## 7. Resume from Checkpoint

Flower has no built-in resume mechanism. Resume is implemented by loading saved checkpoint weights and passing them as `initial_arrays` to the strategy's `start()` method. The ServerApp checks for an existing checkpoint at startup and uses it if found.

### Resume Workflow

```
1. SuperLink (re)starts after crash or redeployment
2. ServerApp initializes in @app.main()
3. ServerApp checks checkpoint_path for checkpoint_latest.npz
   a. If found: load as initial_arrays, log "Resuming from checkpoint round N"
   b. If not found: initialize fresh model, log "Starting fresh training"
4. Strategy starts with initial_arrays (either from checkpoint or fresh model)
5. Training proceeds from round 1 (round counter always restarts)
```

### Resume Implementation Pattern

```python
import os
import json
import numpy as np
from flwr.common import ArrayRecord


def load_checkpoint_or_fresh(checkpoint_path, model_init_fn):
    """Load checkpoint if available, otherwise initialize fresh model.

    Args:
        checkpoint_path: Path to checkpoint directory (from run_config).
        model_init_fn: Callable that returns initial ArrayRecord for fresh start.

    Returns:
        Tuple of (initial_arrays, resumed_round).
    """
    latest_checkpoint = os.path.join(checkpoint_path, "checkpoint_latest.npz")
    latest_metadata = os.path.join(checkpoint_path, "checkpoint_latest.json")

    if os.path.exists(latest_checkpoint):
        # Resume from checkpoint
        data = np.load(latest_checkpoint)
        ndarrays = [data[key] for key in sorted(data.files)]
        initial_arrays = ArrayRecord.from_numpy_ndarrays(ndarrays)

        # Read metadata for logging
        resumed_round = 0
        if os.path.exists(latest_metadata):
            with open(latest_metadata) as f:
                metadata = json.load(f)
            resumed_round = metadata.get("round", 0)

        log("Resuming from checkpoint: round %d (%d arrays loaded)",
            resumed_round, len(ndarrays))
        return initial_arrays, resumed_round
    else:
        # Fresh start
        initial_arrays = model_init_fn()
        log("No checkpoint found at %s. Starting fresh training.", checkpoint_path)
        return initial_arrays, 0
```

### Round Counter Behavior

**The round counter always restarts from 1.** Flower's `strategy.start(num_rounds=N)` runs N rounds starting from round 1. There is no built-in "resume from round X" concept. The checkpoint provides initial model weights, not training progress state.

**Operator workflow for continued training:**

1. Training runs for 50 rounds. Checkpoint saved at round 50.
2. SuperLink crashes and restarts.
3. ServerApp loads `checkpoint_round_50.npz` as `initial_arrays`.
4. If `FL_NUM_ROUNDS=50`, training runs 50 MORE rounds (rounds 1-50 from the ServerApp's perspective, but effectively rounds 51-100 from the model's perspective).
5. If the operator wants only the remaining rounds, they should update `FL_NUM_ROUNDS` to the remaining count before redeployment.

**FL_RESUME_ROUND is NOT implemented.** Flower has no round offset concept. The spec explicitly documents this limitation rather than implementing a workaround that would diverge from Flower's native behavior. Operators must adjust `FL_NUM_ROUNDS` manually when resuming.

---

## 8. Storage Backend Options

The appliance writes checkpoints to a local filesystem path. What backs that path is the operator's infrastructure choice. The appliance does NOT manage disk attachment, NFS mounting, or S3 uploading.

| Backend | How | Pros | Cons |
|---------|-----|------|------|
| **Local disk** (default) | Default `/opt/flower/checkpoints` on SuperLink VM's root disk | Zero config, fast writes, no dependencies | Lost on VM termination |
| **Persistent volume** (OpenNebula DISK) | Attach secondary DISK in VM template, mount at `/opt/flower/checkpoints` | Survives VM termination, reattachable to new VMs | Requires OpenNebula storage configuration |
| **NFS mount** | Mount NFS share at `/opt/flower/checkpoints` | Shared across VMs, network-accessible | Requires NFS infrastructure, write latency |
| **S3 upload** | Post-checkpoint upload via `curl`/`aws s3 cp` in a wrapper script | Durable, scalable, cloud-native | Network dependency, latency, requires S3 credentials |

### Recommendation Hierarchy

1. **Default: Local disk.** The `/opt/flower/checkpoints` directory lives on the SuperLink VM's root disk. Simple, fast, no dependencies. Checkpoints survive container restarts (systemd manages the container lifecycle) but are lost on VM termination. Suitable for development, demos, and training runs that complete within a single VM session.

2. **Persistent: Secondary disk.** For production deployments where checkpoint survival across VM termination is required, the operator attaches a persistent DISK in the SuperLink VM template and mounts it at `/opt/flower/checkpoints`. This is an OpenNebula infrastructure concern -- the appliance's configure.sh creates the directory and sets ownership regardless of what filesystem backs it.

3. **NFS/S3: Operator-managed.** For shared or durable storage, the operator mounts an NFS share or configures an S3 sync at the infrastructure level. The appliance writes to the local path; what backs that path is transparent to the Flower container.

**The appliance does NOT manage disk attachment or NFS/S3 configuration.** These are infrastructure-level decisions made in the VM template or by the operator. The appliance's only responsibility is to create `/opt/flower/checkpoints`, set ownership to 49999:49999, and mount it into the container.

---

## 9. Failure Recovery

This section documents four failure scenarios and how checkpointing affects recovery in each case.

### Scenario 1: SuperNode Crashes Mid-Training Round

**What happens:**
1. SuperNode container crashes (OOM, hardware failure, etc.).
2. SuperLink's strategy detects the client failure (gRPC connection drops).
3. If `accept_failures=True` (default for all six strategies), the round completes with the remaining clients.
4. If the remaining connected clients drop below `min_fit_clients`, the SuperLink waits for reconnection before starting the next round.
5. SuperNode's systemd restarts the container. Flower reconnects automatically (`--max-retries 0` = unlimited).
6. SuperNode re-registers with the SuperLink and participates in the next round.

**Checkpoint role:** None. SuperNode has no persistent state. It receives the current global model from the SuperLink at the start of each training round. No data is lost.

**Recovery time:** 10-30 seconds (systemd restart delay + container startup + gRPC reconnection).

### Scenario 2: SuperLink Crashes Mid-Training Round

**What happens:**
1. SuperLink container crashes.
2. All connected SuperNodes detect the disconnection and enter their reconnection loop.
3. Systemd restarts the SuperLink container (RestartSec=10).
4. The restarted container reads `state.db` from `/app/state` (already persistent per Phase 1).
5. The ServerApp initializes and checks for checkpoints.

**Without checkpoints (FL_CHECKPOINT_ENABLED=NO):**
- Model weights from the current training session are lost.
- `state.db` preserves run history and client registration, but NOT the aggregated model.
- Training restarts from scratch with a freshly initialized model.
- All progress from previous rounds is lost.

**With checkpoints (FL_CHECKPOINT_ENABLED=YES):**
- ServerApp finds `checkpoint_latest.npz` in `/app/checkpoints`.
- Loads the checkpoint as `initial_arrays` (see Section 7).
- Training resumes from the checkpointed model state.
- At most `FL_CHECKPOINT_INTERVAL` rounds of progress are lost (the rounds since the last checkpoint).
- SuperNodes reconnect and receive the restored model on the next round.

**Checkpoint is critical for SuperLink crash recovery.** Without checkpoints, a SuperLink crash means starting training over. With checkpoints, recovery loses at most one checkpoint interval worth of rounds.

**Recovery time:** 15-60 seconds (systemd restart delay + container startup + checkpoint loading + SuperNode reconnection).

### Scenario 3: Full Service Redeployment (VM Terminated)

**What happens:**
1. Operator terminates the OneFlow service (or the SuperLink VM is terminated).
2. The VM is destroyed. Local disk data is lost.
3. Operator deploys a new service instance.

**Without persistent volume:**
- All checkpoints on the local disk are lost.
- Training starts from scratch.
- The operator must manually copy checkpoints before termination if they want to preserve them.

**With persistent volume:**
- The operator attaches the same persistent DISK to the new SuperLink VM template.
- The new VM mounts the volume at `/opt/flower/checkpoints`.
- ServerApp finds the checkpoint and resumes training.

**Recovery time:** 60-120 seconds (new VM creation + boot sequence + checkpoint loading).

### Scenario 4: Network Partition (Temporary)

**What happens:**
1. Network between SuperLink and some SuperNodes drops temporarily.
2. Affected SuperNodes enter their reconnection loop (configured with `--max-retries 0`, unlimited).
3. SuperLink continues training rounds with the remaining connected clients (if `>= min_fit_clients`).
4. When the network recovers, disconnected SuperNodes reconnect and join future rounds.

**Checkpoint role:** None. This is handled entirely by Flower's native reconnection mechanism. No data is lost; the disconnected SuperNodes simply miss some training rounds.

**Recovery time:** Immediate upon network recovery (gRPC reconnection is automatic).

### Failure Recovery Summary

| Scenario | Checkpoint Role | Data Loss Without Checkpoint | Data Loss With Checkpoint | Recovery Time |
|----------|----------------|------------------------------|--------------------------|---------------|
| SuperNode crash | None (no server-side data affected) | None | None | 10-30s |
| SuperLink crash | Restores model weights | All training progress lost | At most N rounds (checkpoint interval) | 15-60s |
| Full redeployment | Restores model (requires persistent volume) | All training progress lost | At most N rounds (with persistent volume) | 60-120s |
| Network partition | None (handled by Flower reconnection) | None | None | Immediate |

---

*Specification for ML-01 and ML-04: Training Configuration*
*Phase: 05 - Training Configuration*
*Version: 1.0*
