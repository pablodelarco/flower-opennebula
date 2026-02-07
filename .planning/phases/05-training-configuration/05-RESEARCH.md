# Phase 5: Training Configuration - Research

**Researched:** 2026-02-07
**Domain:** Flower FL aggregation strategies, checkpointing, failure recovery
**Confidence:** HIGH (verified against official Flower docs)

## Summary

This research investigates how Flower handles aggregation strategy selection, strategy-specific parameters, model checkpointing, and failure recovery -- all in the context of the existing OpenNebula appliance architecture (Phases 1-4). The goal is to inform a spec that allows operators to configure non-default aggregation strategies and checkpoint behavior entirely through OpenNebula contextualization variables.

Flower 1.25.0 provides 15+ built-in strategies in `flwr.server.strategy`, including all four targets: FedAvg, FedProx, FedAdam, and byzantine-robust options (Krum, Bulyan, FedTrimmedAvg). Each strategy exposes different parameters, but all share a common constructor interface for client sampling thresholds (`min_fit_clients`, `min_evaluate_clients`, `min_available_clients`). Strategy-specific parameters include `proximal_mu` for FedProx, `eta`/`beta_1`/`beta_2`/`tau` for FedAdam, `num_malicious_clients` for Krum/Bulyan, and `beta` for FedTrimmedAvg.

Checkpointing in Flower is **not automatic** -- it requires explicit implementation in the ServerApp's `evaluate_fn` callback or `@app.main()` function. There is no built-in "save every N rounds" flag. The spec must define how the appliance's pre-built FABs implement checkpointing using contextualization variables (FL_CHECKPOINT_INTERVAL, FL_CHECKPOINT_PATH) and how resume-from-checkpoint works via `--run-config`.

**Primary recommendation:** Extend the FL_STRATEGY list to include byzantine-robust options, add strategy-specific parameter variables (FL_PROXIMAL_MU, FL_SERVER_LR, FL_NUM_MALICIOUS, FL_TRIM_BETA), add checkpointing variables (FL_CHECKPOINT_ENABLED, FL_CHECKPOINT_INTERVAL, FL_CHECKPOINT_PATH), and define exactly how the ServerApp FAB reads these from `context.run_config` to instantiate the correct strategy and save checkpoints.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `flwr` (Flower) | 1.25.0 | FL framework -- strategies, ServerApp, ClientApp | Already locked in Phase 1 |
| `flwr.server.strategy` | 1.25.0 | Built-in aggregation strategies | Official Flower strategy implementations |
| PyTorch `torch.save`/`torch.load` | (framework ver) | Model checkpoint persistence | Standard PyTorch serialization |
| NumPy `.npz` | (framework ver) | Framework-agnostic checkpoint format | Used by Flower's ArrayRecord conversion |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `flwr.common.ArrayRecord` | 1.25.0 | Model parameter container | Converting between strategy and checkpoint format |
| `flwr.server.ServerConfig` | 1.25.0 | Server configuration (num_rounds, timeout) | Configuring training run |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Per-strategy FL_* variables | Single JSON config variable | JSON is harder to validate in bash, less user-friendly in Sunstone UI |
| PyTorch `.pt` format | `.safetensors` | safetensors is more portable but adds a dependency; `.pt` is native to PyTorch |
| Local disk checkpoints | Direct S3 upload | S3 adds network dependency during training; local + external backup is simpler |

## Architecture Patterns

### Pattern 1: Strategy Selection via run_config Bridge

**What:** The SuperLink's `configure.sh` translates FL_* contextualization variables into the FAB's `pyproject.toml` run_config values. When a `flwr run` is submitted (or when the SuperLink starts with subprocess isolation), the ServerApp reads `context.run_config` to determine which strategy class to instantiate and what parameters to use.

**When to use:** Always -- this is the bridge between OpenNebula contextualization and Flower's strategy API.

**How it works:**

```
OpenNebula CONTEXT vars      configure.sh         pyproject.toml / run_config       ServerApp
FL_STRATEGY=FedProx    --->  Writes to FAB    --->  strategy="FedProx"         --->  strategy = FedProx(
FL_PROXIMAL_MU=0.1           config file            proximal-mu=0.1                    proximal_mu=0.1,
FL_NUM_ROUNDS=10                                    num-server-rounds=10                ...)
```

**Source:** Flower docs -- `context.run_config` provides key-value access to `[tool.flwr.app.config]` from pyproject.toml, overridable via `--run-config`.

```python
# ServerApp reading strategy from run_config
@app.main()
def main(grid, context):
    strategy_name = context.run_config.get("strategy", "FedAvg")
    num_rounds = int(context.run_config.get("num-server-rounds", 3))

    if strategy_name == "FedAvg":
        strategy = FedAvg(
            min_fit_clients=int(context.run_config.get("min-fit-clients", 2)),
            min_evaluate_clients=int(context.run_config.get("min-evaluate-clients", 2)),
            min_available_clients=int(context.run_config.get("min-available-clients", 2)),
        )
    elif strategy_name == "FedProx":
        strategy = FedProx(
            proximal_mu=float(context.run_config.get("proximal-mu", 1.0)),
            min_fit_clients=int(context.run_config.get("min-fit-clients", 2)),
            ...
        )
    elif strategy_name == "FedAdam":
        strategy = FedAdam(
            eta=float(context.run_config.get("server-lr", 0.1)),
            eta_l=float(context.run_config.get("client-lr", 0.1)),
            beta_1=float(context.run_config.get("beta-1", 0.9)),
            beta_2=float(context.run_config.get("beta-2", 0.99)),
            tau=float(context.run_config.get("tau", 1e-9)),
            ...
        )
    # ... etc
```

### Pattern 2: Checkpointing via evaluate_fn Callback

**What:** Flower does NOT have built-in automatic checkpointing. The ServerApp implements checkpointing in an `evaluate_fn` callback passed to the strategy's `start()` method. This callback is called before round 1 and after every round.

**When to use:** When FL_CHECKPOINT_ENABLED=YES is set.

**Source:** [Flower docs -- Save and load model checkpoints](https://flower.ai/docs/framework/how-to-save-and-load-model-checkpoints.html)

```python
def get_evaluate_fn(save_every_round, total_rounds, save_path):
    """Create evaluate_fn that saves checkpoints every N rounds."""
    def evaluate(server_round: int, arrays: ArrayRecord) -> MetricRecord:
        if server_round != 0 and (
            server_round == total_rounds or server_round % save_every_round == 0
        ):
            state_dict = arrays.to_torch_state_dict()
            torch.save(state_dict, f"{save_path}/checkpoint_round_{server_round}.pt")
        return MetricRecord()
    return evaluate

# In ServerApp main:
strategy = FedAvg(...)
result = strategy.start(
    grid=grid,
    initial_arrays=initial_arrays,
    num_rounds=num_rounds,
    evaluate_fn=get_evaluate_fn(
        save_every_round=checkpoint_interval,
        total_rounds=num_rounds,
        save_path=checkpoint_path,
    ),
)
```

### Pattern 3: Resume from Checkpoint

**What:** Flower has no built-in resume mechanism. Resume is implemented by loading saved checkpoint weights and passing them as `initial_arrays` to `strategy.start()`. The checkpoint path is passed via `--run-config checkpoint=path/to/checkpoint`.

**When to use:** After a crash, on redeployment.

**Source:** [Flower Discuss -- Resume from checkpoint](https://discuss.flower.ai/t/how-to-resume-flwr-run-from-a-checkpoint/1016)

```python
@app.main()
def main(grid, context):
    checkpoint_path = context.run_config.get("checkpoint", "")

    if checkpoint_path and os.path.exists(checkpoint_path):
        # Resume: load from checkpoint
        state_dict = torch.load(checkpoint_path)
        initial_arrays = ArrayRecord(state_dict)
        log("Resuming from checkpoint: %s", checkpoint_path)
    else:
        # Fresh start: initialize new model
        model = Net()
        initial_arrays = ArrayRecord(model.state_dict())

    strategy = FedAvg(...)
    result = strategy.start(
        grid=grid,
        initial_arrays=initial_arrays,
        num_rounds=num_rounds,
    )
```

### Pattern 4: Writable Checkpoint Volume Mount

**What:** Phase 1 established data mount as read-only (`/opt/flower/data:/app/data:ro`). Checkpoints require a **writable** path. A new volume mount is needed: `/opt/flower/checkpoints:/app/checkpoints:rw`.

**When to use:** When FL_CHECKPOINT_ENABLED=YES is set on the SuperLink.

**Implementation:**

```bash
# In configure.sh, if FL_CHECKPOINT_ENABLED=YES:
mkdir -p /opt/flower/checkpoints
chown 49999:49999 /opt/flower/checkpoints

# Docker run adds:
-v /opt/flower/checkpoints:/app/checkpoints:rw
```

### Anti-Patterns to Avoid

- **Hand-rolling strategy selection outside the FAB:** The temptation is to pass strategy as a SuperLink CLI flag. Flower's SuperLink binary does NOT accept a `--strategy` flag. Strategy selection MUST happen inside the ServerApp FAB code via `context.run_config`.
- **Assuming automatic checkpointing exists in Flower:** It does not. Every checkpoint save is explicit code in `evaluate_fn` or `@app.main()`.
- **Mounting checkpoints on SuperNode:** Checkpoints are server-side (SuperLink) artifacts. The SuperLink aggregates models and saves checkpoints. SuperNodes do NOT save global checkpoints -- they only have local training state which is ephemeral.
- **Using in-container paths for FL_CHECKPOINT_PATH:** The contextualization variable should reference the host path or a relative container path. The docker mount handles the mapping.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Aggregation strategies | Custom averaging code | `flwr.server.strategy.FedAvg`, `FedProx`, etc. | Flower strategies handle sampling, weighting, failure tolerance |
| FedProx proximal term | Manual loss modification | FedProx strategy's built-in `on_fit_config_fn` | FedProx automatically sends `proximal_mu` to clients via config dict |
| Byzantine detection | Custom outlier detection | `Krum`, `Bulyan`, `FedTrimmedAvg` | Peer-reviewed implementations, handles edge cases |
| Checkpoint format | Custom serialization | `ArrayRecord.to_torch_state_dict()` / `to_numpy_ndarrays()` | Native Flower conversion, handles parameter naming |
| Strategy factory | Custom if/else chain in bash | ServerApp Python code with `context.run_config` | Strategy instantiation requires Python (constructor args, types) |

**Key insight:** Strategy selection CANNOT be done at the Docker/bash layer. The `flwr/superlink` binary does not accept strategy parameters. Strategy selection happens inside the ServerApp code (the FAB), which reads configuration from `context.run_config`. The appliance's job is to bridge FL_* context variables into the FAB's run_config.

## Common Pitfalls

### Pitfall 1: FedProx Requires Client-Side Implementation

**What goes wrong:** Operator selects FedProx via FL_STRATEGY=FedProx but the ClientApp does not implement the proximal term in its loss function. Training runs but produces identical results to FedAvg.

**Why it happens:** FedProx strategy sends `proximal_mu` to clients via the config dictionary, but the CLIENT must implement the proximal loss term: `loss += (mu/2) * ||w - w_global||^2`. If the ClientApp ignores `proximal_mu` in its config, the proximal term has no effect.

**How to avoid:** The pre-built use case FABs (Phase 3) must check for `proximal_mu` in the fit config and apply the proximal term when present. Custom ClientApps are the user's responsibility -- document this requirement clearly.

**Warning signs:** Identical training curves between FedAvg and FedProx runs.

### Pitfall 2: FedAdam Requires initial_parameters

**What goes wrong:** FedAdam is instantiated without `initial_parameters`, causing an error or unexpected behavior.

**Why it happens:** FedAdam (and all FedOpt variants) require the initial global model parameters to compute pseudo-gradients. Unlike FedAvg which can start from any state, FedAdam needs a reference point.

**How to avoid:** The ServerApp code must always provide `initial_arrays` when using `strategy.start()`. This is already required by the `start()` API, but the error messages may not be clear.

**Warning signs:** Runtime error on first round with FedAdam.

### Pitfall 3: Byzantine Strategies Need Minimum Client Count

**What goes wrong:** Krum with `num_malicious_clients=2` but only 3 total clients. Krum needs `n >= 2*f + 3` clients (where f is malicious count), so 3 clients with f=2 is insufficient.

**Why it happens:** The mathematical guarantee of Krum requires `n - f - 2 >= 1` neighbors. Bulyan has even stricter requirements: `n >= 4*f + 3`.

**How to avoid:** Validate at boot time: if FL_STRATEGY=Krum and FL_NUM_MALICIOUS > 0, check that FL_MIN_AVAILABLE_CLIENTS meets the minimum requirement. Log a warning if not.

**Warning signs:** Aggregation errors or empty selections during training.

### Pitfall 4: Checkpoint Path Not Writable

**What goes wrong:** FL_CHECKPOINT_ENABLED=YES but the checkpoint directory inside the container is not writable (e.g., mounted read-only or wrong UID ownership).

**Why it happens:** Phase 1 established the pattern of UID 49999 ownership. If the checkpoint directory is created by root and not chowned, the container process cannot write.

**How to avoid:** `configure.sh` must create `/opt/flower/checkpoints` with `chown 49999:49999` before starting the container, same pattern as `/opt/flower/state`.

**Warning signs:** "Permission denied" errors in container logs at checkpoint save time.

### Pitfall 5: Checkpoint Resume Without Round Offset

**What goes wrong:** Training resumes from a round-50 checkpoint but starts counting from round 1 again. The ServerApp runs `num_rounds` more rounds instead of resuming from round 50.

**Why it happens:** Flower's `strategy.start(num_rounds=N)` always runs N rounds from the beginning. There is no built-in "resume from round X" concept. The checkpoint only provides initial model weights, not training progress state.

**How to avoid:** Document that resume-from-checkpoint restarts the round counter. If the user wants to continue for the remaining rounds, they should set `FL_NUM_ROUNDS` to the remaining count. Alternatively, the spec could define FL_RESUME_ROUND as a hint variable.

**Warning signs:** Duplicate round numbers in logs.

## Aggregation Strategy Reference

### Strategy 1: FedAvg (Federated Averaging)

**Algorithm:** Weighted average of client model updates, weighted by number of training examples.
**When to use:** Default strategy. Works well with IID data and homogeneous clients.
**Flower class:** `flwr.server.strategy.FedAvg`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `min_fit_clients` | int | 2 | `FL_MIN_FIT_CLIENTS` (already defined) |
| `min_evaluate_clients` | int | 2 | `FL_MIN_EVALUATE_CLIENTS` (already defined) |
| `min_available_clients` | int | 2 | `FL_MIN_AVAILABLE_CLIENTS` (already defined) |
| `fraction_fit` | float | 1.0 | (not exposed -- use defaults) |
| `fraction_evaluate` | float | 1.0 | (not exposed -- use defaults) |
| `accept_failures` | bool | True | (not exposed -- keep True) |
| `inplace` | bool | True | (not exposed -- keep True) |

**No additional variables needed** beyond what Phase 1 already defines.

### Strategy 2: FedProx (Federated Optimization in Heterogeneous Networks)

**Algorithm:** Same as FedAvg but adds a proximal term to each client's local loss function: `L_prox = (mu/2) * ||w - w_global||^2`. This penalizes local model divergence from the global model.
**When to use:** Non-IID data distributions, heterogeneous client compute capabilities.
**Flower class:** `flwr.server.strategy.FedProx`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `proximal_mu` | float | (required) | `FL_PROXIMAL_MU` (NEW) |
| All FedAvg params | ... | ... | (same as FedAvg) |

**Important:** `proximal_mu=0.0` makes FedProx identical to FedAvg. Typical values: 0.001 to 1.0. The Flower FedProx strategy automatically sends `proximal_mu` to clients via `configure_fit`, but the ClientApp MUST implement the proximal loss term.

**New variable:**
```
FL_PROXIMAL_MU = "O|number-float|FedProx proximal regularization term (mu)||1.0"
```

### Strategy 3: FedAdam (Adaptive Federated Optimization)

**Algorithm:** Applies the Adam optimizer on the server side to aggregate pseudo-gradients (difference between received and previous global model). Uses adaptive learning rates with momentum.
**When to use:** When convergence is slow with FedAvg, for complex models, when learning rate tuning is needed.
**Flower class:** `flwr.server.strategy.FedAdam`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `eta` | float | 0.1 | `FL_SERVER_LR` (NEW) |
| `eta_l` | float | 0.1 | `FL_CLIENT_LR` (NEW) |
| `beta_1` | float | 0.9 | (not exposed -- advanced) |
| `beta_2` | float | 0.99 | (not exposed -- advanced) |
| `tau` | float | 1e-9 | (not exposed -- advanced) |
| All FedAvg params | ... | ... | (same as FedAvg) |

**Recommendation:** Expose `eta` (server learning rate) and `eta_l` (client learning rate) as contextualization variables. Keep `beta_1`, `beta_2`, `tau` at defaults -- they are rarely tuned.

**New variables:**
```
FL_SERVER_LR = "O|number-float|Server-side learning rate (FedAdam)||0.1"
FL_CLIENT_LR = "O|number-float|Client-side learning rate (FedAdam)||0.1"
```

### Strategy 4: Krum (Byzantine-Robust)

**Algorithm:** Selects the client update that is closest to most other updates, excluding potential outliers. Designed to tolerate up to f byzantine (malicious/faulty) clients.
**When to use:** When some clients may be compromised, produce faulty updates, or when data poisoning is a concern.
**Flower class:** `flwr.server.strategy.Krum`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `num_malicious_clients` | int | 0 | `FL_NUM_MALICIOUS` (NEW) |
| `num_clients_to_keep` | int | 0 | (not exposed -- 0 = standard Krum, >0 = MultiKrum) |
| All FedAvg params | ... | ... | (same as FedAvg) |

**Constraint:** Requires `n >= 2*f + 3` clients where n = total connected, f = num_malicious_clients. With f=1, need at least 5 clients. With f=0 (default), behaves like selecting the "most average" update.

**New variable:**
```
FL_NUM_MALICIOUS = "O|number|Expected number of malicious clients (Krum/Bulyan)||0"
```

### Strategy 5: Bulyan (Two-Phase Byzantine-Robust)

**Algorithm:** Phase 1: Uses Krum (or another robust rule) to select a subset of "good" updates. Phase 2: Applies coordinate-wise trimmed mean on the selected subset. Stronger guarantees than Krum alone.
**When to use:** Higher security requirements than Krum, more suspected malicious clients.
**Flower class:** `flwr.server.strategy.Bulyan`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `num_malicious_clients` | int | 0 | `FL_NUM_MALICIOUS` (shared with Krum) |
| All FedAvg params | ... | ... | (same as FedAvg) |

**Constraint:** Requires `n >= 4*f + 3` clients. More restrictive than Krum. With f=1, need at least 7 clients.

### Strategy 6: FedTrimmedAvg (Trimmed Mean)

**Algorithm:** For each model parameter coordinate, trims the highest and lowest `beta` fraction of values, then averages the remaining. Robust to outlier updates.
**When to use:** Simple byzantine robustness, moderate outlier tolerance needed.
**Flower class:** `flwr.server.strategy.FedTrimmedAvg`

| Parameter | Type | Default | Contextualization Variable |
|-----------|------|---------|---------------------------|
| `beta` | float | 0.2 | `FL_TRIM_BETA` (NEW) |
| All FedAvg params | ... | ... | (same as FedAvg) |

**Note:** `beta=0.2` trims 20% from each tail. With 10 clients, discards 2 lowest + 2 highest per coordinate.

**New variable:**
```
FL_TRIM_BETA = "O|number-float|Fraction to trim from each tail (FedTrimmedAvg)||0.2"
```

### Strategy Selection Summary

| FL_STRATEGY Value | Flower Class | Extra Variables | Min Clients Formula |
|-------------------|-------------|----------------|---------------------|
| `FedAvg` | `FedAvg` | None (Phase 1 params suffice) | >= `FL_MIN_AVAILABLE_CLIENTS` |
| `FedProx` | `FedProx` | `FL_PROXIMAL_MU` | >= `FL_MIN_AVAILABLE_CLIENTS` |
| `FedAdam` | `FedAdam` | `FL_SERVER_LR`, `FL_CLIENT_LR` | >= `FL_MIN_AVAILABLE_CLIENTS` |
| `Krum` | `Krum` | `FL_NUM_MALICIOUS` | >= `2*FL_NUM_MALICIOUS + 3` |
| `Bulyan` | `Bulyan` | `FL_NUM_MALICIOUS` | >= `4*FL_NUM_MALICIOUS + 3` |
| `FedTrimmedAvg` | `FedTrimmedAvg` | `FL_TRIM_BETA` | >= `FL_MIN_AVAILABLE_CLIENTS` |

## Checkpointing Architecture

### Checkpoint File Format

Flower uses framework-native formats via ArrayRecord conversion:

| Framework | Method | File Extension | Example |
|-----------|--------|---------------|---------|
| PyTorch | `arrays.to_torch_state_dict()` -> `torch.save()` | `.pt` | `checkpoint_round_10.pt` |
| TensorFlow | `arrays.to_numpy_ndarrays()` -> `model.save()` | `.keras` | `checkpoint_round_10.keras` |
| scikit-learn | `arrays.to_numpy_ndarrays()` -> `numpy.savez()` | `.npz` | `checkpoint_round_10.npz` |

**Recommendation for the spec:** Use `.npz` (NumPy) as the default format because it is framework-agnostic and ArrayRecord can always convert to NumPy ndarrays regardless of the ML framework. Framework-specific formats (`.pt`, `.keras`) can be used by custom ClientApps.

### Checkpoint Naming Convention

```
/app/checkpoints/
    checkpoint_round_{N}.npz       # Periodic checkpoints
    checkpoint_latest.npz          # Symlink or copy of most recent
    checkpoint_metadata.json       # Round number, strategy, timestamp
```

### Storage Backend Options (OpenNebula VM Context)

| Backend | How | Pros | Cons |
|---------|-----|------|------|
| **Local disk** (VM ephemeral) | Default `/opt/flower/checkpoints` on root disk | Zero config, fast writes | Lost on VM termination |
| **Persistent volume** (OpenNebula DISK) | Attach a secondary DISK via VM template | Survives VM termination, reattachable | Requires OpenNebula storage config |
| **NFS mount** | Mount NFS share at `/opt/flower/checkpoints` | Shared across VMs, network-accessible | Requires NFS infrastructure |
| **S3 upload** | Post-checkpoint upload via `curl`/`aws s3 cp` | Durable, scalable, cloud-native | Network dependency, latency, requires credentials |

**Recommendation for the spec:**
1. **Default: Local disk** -- `/opt/flower/checkpoints` on the SuperLink VM's root disk. Simple, fast, no dependencies. Checkpoints survive container restarts (systemd) but not VM termination.
2. **Persistent: Secondary disk** -- Operator attaches a persistent DISK in the VM template and mounts it at `/opt/flower/checkpoints`. The appliance does NOT manage disk attachment -- that is an OpenNebula infrastructure concern.
3. **Document but don't implement:** NFS and S3 as operator-managed options. The appliance writes to a local path; what backs that path is the operator's choice.

### Checkpoint Volume Mount (New)

```bash
# SuperLink Docker run addition (when FL_CHECKPOINT_ENABLED=YES):
-v /opt/flower/checkpoints:/app/checkpoints:rw

# Host directory setup in configure.sh:
mkdir -p /opt/flower/checkpoints
chown 49999:49999 /opt/flower/checkpoints
```

This is analogous to the existing `/opt/flower/state:/app/state` mount for the SQLite database.

### Failure Recovery Scenarios

#### Scenario 1: SuperNode Crashes Mid-Training Round

**What happens:**
1. SuperNode container crashes (OOM, hardware failure, etc.).
2. SuperLink's strategy detects the client failure (gRPC connection drops).
3. If `accept_failures=True` (default), the round completes with remaining clients.
4. If remaining clients < `min_fit_clients`, the round fails and SuperLink waits.
5. SuperNode's systemd restarts the container. Flower reconnects automatically (`--max-retries 0`).
6. SuperNode re-registers and participates in the next round.

**No checkpoint involvement.** SuperNode has no persistent state. It receives the current global model from SuperLink at the start of each round.

#### Scenario 2: SuperLink Crashes Mid-Training Round

**What happens:**
1. SuperLink container crashes.
2. All SuperNodes detect disconnection, enter reconnection loop.
3. Systemd restarts SuperLink container (RestartSec=10).
4. SuperLink reads `state.db` from `/app/state` (already persistent).
5. **Without checkpoints:** Training restarts from scratch (initial model weights). All previous rounds' progress is in `state.db` for audit but the model weights are lost.
6. **With checkpoints:** SuperLink's ServerApp checks for latest checkpoint in `/app/checkpoints`, loads it as `initial_arrays`, and resumes training.
7. SuperNodes reconnect and receive the restored model.

**Checkpoint is critical for SuperLink crash recovery.**

#### Scenario 3: Full Service Redeployment (VM Terminated)

**What happens:**
1. Operator terminates and redeploys the OneFlow service.
2. VM is destroyed. Local disk checkpoints are lost unless stored on a persistent volume.
3. **With persistent volume:** New VM attaches the same volume. ServerApp finds checkpoints and resumes.
4. **Without persistent volume:** Training starts fresh. Operator must manually copy checkpoints before termination.

**Persistent storage is required for cross-deployment resume.**

#### Scenario 4: Network Partition (Temporary)

**What happens:**
1. Network between SuperLink and some SuperNodes drops.
2. Affected SuperNodes enter reconnection loop.
3. SuperLink continues rounds with connected clients (if >= `min_fit_clients`).
4. When network recovers, SuperNodes reconnect and join future rounds.
5. **No checkpoint involvement** -- this is handled by Flower's native reconnection.

## New Contextualization Variables (Phase 5)

### SuperLink Variables (New)

| Variable | USER_INPUT | Type | Default | Validation | Purpose |
|----------|-----------|------|---------|------------|---------|
| `FL_PROXIMAL_MU` | `O\|number-float\|FedProx proximal term (mu)\|\|1.0` | number-float | `1.0` | Non-negative float (>=0.0) | Proximal regularization strength for FedProx. Ignored if FL_STRATEGY != FedProx. |
| `FL_SERVER_LR` | `O\|number-float\|Server-side learning rate\|\|0.1` | number-float | `0.1` | Positive float (>0.0) | Server-side learning rate for FedAdam. Ignored if FL_STRATEGY != FedAdam. |
| `FL_CLIENT_LR` | `O\|number-float\|Client-side learning rate\|\|0.1` | number-float | `0.1` | Positive float (>0.0) | Client-side learning rate for FedAdam. Ignored if FL_STRATEGY != FedAdam. |
| `FL_NUM_MALICIOUS` | `O\|number\|Expected malicious clients (Krum/Bulyan)\|\|0` | number | `0` | Non-negative integer (>=0) | Expected number of Byzantine clients for Krum/Bulyan. Ignored if FL_STRATEGY not Krum/Bulyan. |
| `FL_TRIM_BETA` | `O\|number-float\|Trim fraction per tail (FedTrimmedAvg)\|\|0.2` | number-float | `0.2` | Float in range 0.0-0.5 exclusive | Fraction to trim from each tail for FedTrimmedAvg. |
| `FL_CHECKPOINT_ENABLED` | `O\|boolean\|Enable model checkpointing\|\|NO` | boolean | `NO` | YES or NO | Master switch for checkpoint saving. |
| `FL_CHECKPOINT_INTERVAL` | `O\|number\|Save checkpoint every N rounds\|\|5` | number | `5` | Positive integer (>0) | Checkpoint frequency in rounds. |
| `FL_CHECKPOINT_PATH` | `O\|text\|Checkpoint directory (container path)\|\|/app/checkpoints` | text | `/app/checkpoints` | Non-empty string | Path inside container where checkpoints are saved. |

### Updated FL_STRATEGY Variable (Phase 5 Extension)

The Phase 1 definition of FL_STRATEGY needs to be extended:

**Phase 1 definition:**
```
FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam|FedAvg"
```

**Phase 5 updated definition:**
```
FL_STRATEGY = "O|list|Aggregation strategy|FedAvg,FedProx,FedAdam,Krum,Bulyan,FedTrimmedAvg|FedAvg"
```

### Variable Placement in OneFlow Service Template

| Variable | Level | Rationale |
|----------|-------|-----------|
| `FL_STRATEGY` | SuperLink role | Server-side parameter |
| `FL_PROXIMAL_MU` | SuperLink role | Server-side strategy parameter |
| `FL_SERVER_LR` | SuperLink role | Server-side optimizer parameter |
| `FL_CLIENT_LR` | SuperLink role | Forwarded to clients via strategy, but configured at server |
| `FL_NUM_MALICIOUS` | SuperLink role | Server-side aggregation parameter |
| `FL_TRIM_BETA` | SuperLink role | Server-side aggregation parameter |
| `FL_CHECKPOINT_ENABLED` | SuperLink role | Only SuperLink saves checkpoints |
| `FL_CHECKPOINT_INTERVAL` | SuperLink role | Only SuperLink saves checkpoints |
| `FL_CHECKPOINT_PATH` | SuperLink role | Only SuperLink saves checkpoints |

All new Phase 5 variables are SuperLink-only. SuperNodes do not need any new variables for Phase 5.

## Code Examples

### ServerApp Strategy Factory (Verified Pattern)

```python
"""ServerApp with strategy selection from run_config."""
from flwr.server import ServerApp
from flwr.server.strategy import (
    FedAvg, FedProx, FedAdam, Krum, Bulyan, FedTrimmedAvg,
)

app = ServerApp()

STRATEGY_MAP = {
    "FedAvg": _build_fedavg,
    "FedProx": _build_fedprox,
    "FedAdam": _build_fedadam,
    "Krum": _build_krum,
    "Bulyan": _build_bulyan,
    "FedTrimmedAvg": _build_fedtrimmedavg,
}

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
```

Source: Based on Flower strategy API docs (verified per-strategy parameter lists).

### Checkpoint evaluate_fn (Verified Pattern)

```python
import os
import json
import numpy as np
from datetime import datetime

def make_checkpoint_fn(interval, total_rounds, path):
    """Create evaluate_fn that saves checkpoints to disk."""
    os.makedirs(path, exist_ok=True)

    def evaluate_fn(server_round, arrays):
        should_save = (
            server_round != 0
            and (server_round == total_rounds or server_round % interval == 0)
        )
        if should_save:
            # Save model weights as NumPy arrays (framework-agnostic)
            ndarrays = arrays.to_numpy_ndarrays()
            np.savez(
                os.path.join(path, f"checkpoint_round_{server_round}.npz"),
                *ndarrays,
            )
            # Save metadata
            metadata = {
                "round": server_round,
                "timestamp": datetime.utcnow().isoformat(),
                "num_arrays": len(ndarrays),
            }
            with open(os.path.join(path, "checkpoint_latest.json"), "w") as f:
                json.dump(metadata, f)
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

Source: Based on [Flower checkpoint docs](https://flower.ai/docs/framework/how-to-save-and-load-model-checkpoints.html), extended with metadata and symlink pattern.

### configure.sh Run Config Bridge (Pattern)

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

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `flwr.server.strategy.FedAvg` | `flwr.serverapp.strategy.FedAvg` | Flower 1.21-1.22 (Sep 2025) | Both namespaces work in 1.25.0; old is deprecated but functional |
| `start_server()` + Strategy | `ServerApp` + `@app.main()` + `strategy.start()` | Flower 1.20+ | Modern API uses Grid/Context pattern |
| `Parameters` (ndarrays list) | `ArrayRecord` (dict-like) | Flower 1.20+ | New container for model parameters |
| `FitRes`/`EvaluateRes` tuples | `Message` with `RecordDict` | Flower 1.21+ (Message API) | Strategies now operate on Messages |
| No built-in checkpoint API | `evaluate_fn` callback pattern | Stable pattern | Still requires manual implementation |

**Critical note for this spec:** The existing Phase 3 use case FABs (image-classification, anomaly-detection, llm-fine-tuning) use the `flwr.server.ServerApp` namespace which is still functional in 1.25.0. Phase 5 should use the same namespace for consistency with Phase 3 code. Migration to `flwr.serverapp` can happen in a future version upgrade.

## Open Questions

1. **How does `--run-config` interact with subprocess isolation mode?**
   - What we know: In subprocess isolation, the SuperLink runs both the `flower-superlink` process and the ServerApp FAB within the same container. The FAB is pre-installed (Phase 3).
   - What's unclear: How exactly does `context.run_config` get populated when using subprocess mode with pre-installed FABs? Is it from the pyproject.toml in the FAB, from `--run-config` CLI override, or from environment variables?
   - Recommendation: Verify during implementation. The bridge from FL_* to run_config may need to write a modified pyproject.toml or pass `--run-config` when submitting a run via the Control API.

2. **Does Flower 1.25.0 persist round progress in state.db?**
   - What we know: SuperLink uses `--database state/state.db` for SQLite persistence. This stores run history and connected node state.
   - What's unclear: Does `state.db` store the current global model weights between rounds? If so, checkpoint-based resume might be partially redundant with state.db recovery.
   - Recommendation: Test during implementation. If state.db stores model weights, document the interaction with explicit checkpoints.

3. **FedProx client-side proximal term in pre-built FABs**
   - What we know: FedProx strategy automatically sends `proximal_mu` via config dict. But the ClientApp must implement the proximal loss term.
   - What's unclear: Do the Phase 3 FABs currently support the proximal term? The existing client_app.py code does not check for `proximal_mu`.
   - Recommendation: Phase 5 spec should explicitly update the pre-built FABs to support the proximal term when FL_STRATEGY=FedProx.

## Sources

### Primary (HIGH confidence)

- [Flower Strategy API reference](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.html) -- Complete list of built-in strategies
- [FedAvg parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FedAvg.html) -- Constructor signature
- [FedProx parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FedProx.html) -- proximal_mu documentation
- [FedProx source code](https://flower.ai/docs/framework/_modules/flwr/server/strategy/fedprox.html) -- How proximal_mu is sent to clients
- [FedAdam parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FedAdam.html) -- eta, beta_1, beta_2, tau
- [Krum parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.Krum.html) -- num_malicious_clients
- [Bulyan parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.Bulyan.html) -- Two-phase byzantine aggregation
- [FedTrimmedAvg parameters](https://flower.ai/docs/framework/ref-api/flwr.server.strategy.FedTrimmedAvg.html) -- beta trim ratio
- [Save and load checkpoints](https://flower.ai/docs/framework/how-to-save-and-load-model-checkpoints.html) -- Official checkpoint guide
- [How to use strategies](https://flower.ai/docs/framework/how-to-use-strategies.html) -- strategy.start() API, evaluate_fn
- [ServerApp API](https://flower.ai/docs/framework/ref-api/flwr.server.ServerApp.html) -- server_fn, @app.main()
- [Configure pyproject.toml](https://flower.ai/docs/framework/how-to-configure-pyproject-toml.html) -- run_config setup
- [Flower CLI reference](https://flower.ai/docs/framework/ref-api-cli.html) -- --run-config flag
- [Flower changelog](https://flower.ai/docs/framework/ref-changelog.html) -- API migration timeline

### Secondary (MEDIUM confidence)

- [Flower Discuss -- Resume from checkpoint](https://discuss.flower.ai/t/how-to-resume-flwr-run-from-a-checkpoint/1016) -- Community guidance on manual resume
- [FedProx baselines](https://flower.ai/docs/baselines/fedprox.html) -- Implementation examples

### Tertiary (LOW confidence)

- [OpenNebula NFS/NAS Datastore docs](https://docs.opennebula.io/7.0/product/cluster_configuration/storage_system/nas_ds/) -- Storage backend options (not verified for checkpoint use case specifically)

## Metadata

**Confidence breakdown:**
- Standard stack (strategies): HIGH -- verified against official Flower API docs per-strategy
- Architecture (run_config bridge): MEDIUM -- verified that run_config works, but subprocess isolation flow needs implementation validation
- Checkpointing: HIGH -- official docs confirm manual implementation pattern
- Failure recovery: MEDIUM -- based on Flower's documented behavior + state.db behavior needs verification
- New variables: HIGH -- derived directly from verified strategy parameters

**Research date:** 2026-02-07
**Valid until:** 2026-03-07 (30 days -- Flower API stable within minor version)
