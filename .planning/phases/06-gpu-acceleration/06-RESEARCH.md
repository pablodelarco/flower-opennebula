# Phase 6: GPU Acceleration - Research

**Researched:** 2026-02-08
**Domain:** NVIDIA GPU passthrough for Docker-in-VM federated learning workloads on OpenNebula
**Confidence:** HIGH (host configuration and Container Toolkit), MEDIUM (memory management patterns), LOW (MIG on OpenNebula -- limited direct integration docs)

## Summary

This research covers the complete GPU passthrough stack for accelerated federated learning training on SuperNode appliances. The stack has four layers: (1) host prerequisites -- IOMMU/VFIO configuration to enable GPU passthrough, (2) VM template configuration -- UEFI firmware, q35 machine type, PCI device assignment, and CPU/NUMA pinning, (3) container runtime -- NVIDIA Container Toolkit installation inside the VM to expose the passthrough GPU to Docker containers, and (4) CUDA memory management -- per-process memory fraction and Multi-Instance GPU (MIG) support for shared GPU scenarios.

The standard approach for OpenNebula 7.0 is well-documented: enable IOMMU in BIOS and kernel, bind GPUs to vfio-pci driver, configure PCI monitoring in OpenNebula, and use VM templates with UEFI/q35/host-passthrough CPU. Inside the VM, NVIDIA Container Toolkit 1.18+ provides the `--gpus` flag for Docker. Memory management uses framework-specific APIs: PyTorch's `torch.cuda.set_per_process_memory_fraction()` and TensorFlow's `tf.config.set_memory_growth()` or `tf.config.set_logical_device_configuration()`.

A CPU-only fallback path is essential. Both PyTorch (`torch.cuda.is_available()`) and TensorFlow (`tf.config.list_physical_devices('GPU')`) provide device detection that enables graceful degradation. The spec should define a consistent pattern: check GPU availability at ClientApp startup, log the device being used, and proceed with CPU training if no GPU is found.

**Primary recommendation:** Define the full GPU stack in the spec with clear layers (host, VM, container, application). Include a validation script specification that checks each layer. Require CPU-only fallback in all framework variants. Defer MIG support to a future phase (complex host setup, limited OpenNebula docs).

## Standard Stack

The established technologies for GPU acceleration in the Docker-in-VM architecture:

### Core

| Technology | Version | Purpose | Why Standard |
|------------|---------|---------|--------------|
| IOMMU (Intel VT-d / AMD-Vi) | BIOS + kernel | Hardware isolation for PCI passthrough | Required by all PCIe passthrough implementations. No alternative exists. |
| vfio-pci driver | Linux kernel module | Userspace access to PCI devices | Standard Linux mechanism for device passthrough to VMs. |
| driverctl | any | Persistent driver binding | OpenNebula docs recommend for binding GPUs to vfio-pci across reboots. |
| UEFI firmware | (OVMF) | VM boot firmware | Required for modern GPUs with Resizable BAR. q35+UEFI is the standard GPU passthrough configuration. |
| NVIDIA Container Toolkit | 1.18.2+ | Docker GPU access | Official NVIDIA solution for exposing GPUs to containers. Provides `--gpus` flag. |
| nvidia-smi | (bundled with driver) | GPU monitoring and validation | Standard NVIDIA tool for GPU detection, memory monitoring, MIG configuration. |

### Supporting

| Technology | Version | Purpose | When to Use |
|------------|---------|---------|-------------|
| MIG (Multi-Instance GPU) | NVIDIA driver 535+ | GPU partitioning | H100, A100 GPUs when sharing a single GPU across multiple VMs or containers. Phase 6+ consideration. |
| nvidia-ctk | 1.18+ | Container Toolkit configuration | Configures Docker daemon to use NVIDIA runtime. Required for `--gpus` flag. |
| CUDA_VISIBLE_DEVICES | env var | GPU isolation | Limits which GPUs a container sees. Simpler than MIG for basic isolation. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| PCI passthrough | vGPU (NVIDIA GRID) | vGPU provides fractional GPU sharing but requires NVIDIA GRID license (~$2-3K/GPU/year). PCI passthrough is license-free with near-bare-metal performance. |
| vfio-pci binding | nouveau blacklist only | nouveau blacklist alone is not sufficient -- vfio-pci must claim the device for passthrough to work. |
| NVIDIA Container Toolkit | Manual device mounts | Container Toolkit handles driver library injection, device node creation, and cgroup configuration automatically. Manual approach is error-prone. |
| MIG | Time-slicing | Time-slicing (CUDA MPS) has no QoS guarantees. MIG provides hardware-isolated GPU partitions with dedicated memory. For production FL, MIG is preferred when available. |

### VM Template Requirements

The GPU-enabled VM template must specify:

```
OS = [
    ARCH = "x86_64",
    FIRMWARE = "UEFI"
]

FEATURES = [
    MACHINE = "q35"
]

CPU_MODEL = [
    MODEL = "host-passthrough"
]

TOPOLOGY = [
    PIN_POLICY = "CORE",
    CORES = "<cores>",
    SOCKETS = "1"
]

PCI = [
    SHORT_ADDRESS = "<gpu_pci_address>"
]
```

**Confidence:** HIGH -- verified from OpenNebula 7.0 NVIDIA GPU passthrough documentation.

## Architecture Patterns

### Recommended GPU Stack Layers

```
+------------------------------------------+
|  Layer 4: Application (ClientApp)        |
|  - PyTorch/TensorFlow CUDA operations    |
|  - Memory fraction configuration         |
|  - CPU fallback logic                    |
+------------------------------------------+
|  Layer 3: Container Runtime              |
|  - NVIDIA Container Toolkit              |
|  - Docker --gpus flag                    |
|  - /etc/docker/daemon.json config        |
+------------------------------------------+
|  Layer 2: VM Template                    |
|  - UEFI firmware                         |
|  - q35 machine type                      |
|  - host-passthrough CPU                  |
|  - PCI device assignment                 |
|  - NUMA-aware CPU pinning                |
+------------------------------------------+
|  Layer 1: Host Prerequisites             |
|  - IOMMU enabled (BIOS + kernel)         |
|  - vfio-pci driver binding               |
|  - udev rules for device permissions     |
|  - OpenNebula PCI probe configuration    |
+------------------------------------------+
```

### Pattern 1: Host IOMMU/VFIO Configuration

**What:** Enable IOMMU in BIOS, configure kernel parameters, bind GPU to vfio-pci driver, set udev permissions.

**When to use:** Always required for GPU passthrough.

**Configuration steps:**

```bash
# 1. BIOS: Enable Intel VT-d or AMD IOMMU (manual step)

# 2. Kernel parameters (Intel example)
# Edit /etc/default/grub:
# GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt"
# Then: update-grub && reboot

# 3. Load vfio-pci module at boot
echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf

# 4. Install driverctl for persistent binding
apt install driverctl

# 5. Identify GPU PCI address
lspci -D | grep -i nvidia
# Example output: 0000:e1:00.0 3D controller: NVIDIA Corporation ...

# 6. Bind GPU to vfio-pci driver (persists across reboots)
driverctl set-override 0000:e1:00.0 vfio-pci

# 7. Verify binding
lspci -Dnns 0000:e1:00.0 -k
# Should show: Kernel driver in use: vfio-pci

# 8. Set udev rules for OpenNebula
echo 'SUBSYSTEM=="vfio", GROUP="kvm", MODE="0666"' > /etc/udev/rules.d/99-vfio.rules
udevadm control --reload && udevadm trigger
```

**Source:** [OpenNebula 7.0 NVIDIA GPU Passthrough](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/)

### Pattern 2: OpenNebula PCI Device Discovery

**What:** Configure OpenNebula to discover and track NVIDIA GPUs for VM assignment.

**When to use:** After host VFIO configuration is complete.

**Configuration:**

```bash
# Edit /var/lib/one/remotes/etc/im/kvm-probes.d/pci.conf
# Add NVIDIA vendor filter:
:filter: '10de:*'

# Synchronize probes to all hosts
onehost sync -f

# Wait for probe (up to 10 minutes) or force update
onehost forceupdate <HOST_ID>

# Verify GPU is detected
onehost show <HOST_ID> | grep -A 20 "PCI"
```

**Source:** [OpenNebula 7.0 PCI Passthrough](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/pci_passthrough/)

### Pattern 3: NVIDIA Container Toolkit Installation (Inside VM)

**What:** Install NVIDIA drivers and Container Toolkit inside the Ubuntu 24.04 VM to expose the passthrough GPU to Docker containers.

**When to use:** Pre-install in GPU-enabled appliance image or install at boot via contextualization when GPU is detected.

**Installation steps:**

```bash
# 1. Install NVIDIA driver (inside VM with passthrough GPU)
apt update && apt install -y nvidia-driver-545

# 2. Reboot and verify GPU detection
nvidia-smi

# 3. Add NVIDIA Container Toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# 4. Install Container Toolkit
apt update
apt install -y nvidia-container-toolkit

# 5. Configure Docker to use NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# 6. Verify Docker GPU access
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

**Source:** [NVIDIA Container Toolkit Install Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)

### Pattern 4: Docker Run with GPU Access

**What:** Launch Flower SuperNode container with GPU access using the `--gpus` flag.

**When to use:** When `FL_GPU_ENABLED=YES` in contextualization variables.

**Example (Phase 6 upgrade to SuperNode Docker run):**

```bash
# GPU-enabled SuperNode container
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  --gpus all \
  -v /opt/flower/data:/app/data:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  -e CUDA_VISIBLE_DEVICES=${FL_CUDA_VISIBLE_DEVICES:-all} \
  flwr/supernode:${FLOWER_VERSION:-1.25.0} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}"
```

**Key differences from CPU-only:**
- Added `--gpus all` flag
- Added `CUDA_VISIBLE_DEVICES` environment variable for GPU selection

### Pattern 5: CPU-Only Fallback

**What:** Detect GPU availability at application startup and gracefully fall back to CPU training.

**When to use:** Always. Every ClientApp must handle the no-GPU case.

**PyTorch fallback pattern:**

```python
import torch

def get_device():
    """Get the best available device with graceful fallback."""
    if torch.cuda.is_available():
        device = torch.device("cuda:0")
        gpu_name = torch.cuda.get_device_name(0)
        print(f"Using GPU: {gpu_name}")
    else:
        device = torch.device("cpu")
        print("CUDA not available, using CPU")
    return device

# Usage in ClientApp
device = get_device()
model = model.to(device)
```

**TensorFlow fallback pattern:**

```python
import tensorflow as tf

def configure_device():
    """Configure TensorFlow device with GPU memory growth or CPU fallback."""
    gpus = tf.config.list_physical_devices('GPU')
    if gpus:
        try:
            for gpu in gpus:
                tf.config.experimental.set_memory_growth(gpu, True)
            print(f"Using {len(gpus)} GPU(s)")
        except RuntimeError as e:
            print(f"GPU configuration error: {e}")
    else:
        print("No GPU available, using CPU")

# Call early in ClientApp initialization
configure_device()
```

**Source:** [PyTorch CUDA Semantics](https://docs.pytorch.org/docs/stable/notes/cuda.html), [TensorFlow GPU Guide](https://www.tensorflow.org/guide/gpu)

### Anti-Patterns to Avoid

- **Assuming GPU is always present:** ClientApp code that calls `.cuda()` without checking availability crashes on CPU-only nodes.
- **Skipping memory growth configuration:** TensorFlow pre-allocates all GPU memory by default, preventing multi-client scenarios.
- **Using nouveau driver on host:** The nouveau driver must be blacklisted AND the GPU must be bound to vfio-pci. Blacklisting alone is insufficient.
- **Missing UEFI firmware in VM template:** Modern GPUs (especially those with Resizable BAR) require UEFI. Legacy BIOS boot may cause GPU initialization failures.
- **Ignoring NUMA topology:** For maximum performance, vCPUs should be pinned to the same NUMA node as the GPU. Missing PIN_POLICY causes scheduling across NUMA nodes.

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| GPU device discovery in container | Manual /dev/nvidia* mounts | NVIDIA Container Toolkit + `--gpus` flag | Toolkit handles device nodes, cgroups, driver library injection automatically. Manual approach misses library mounts. |
| Driver binding persistence | Init scripts | driverctl | driverctl creates persistent overrides that survive kernel updates. Init scripts may run before modules load. |
| GPU memory sharing | Manual CUDA memory limits | TensorFlow `set_memory_growth()` or PyTorch `set_per_process_memory_fraction()` | Framework APIs handle pool allocation correctly. Manual limits don't account for CUDA overhead. |
| Multi-GPU partitioning | Time-slicing (MPS) | MIG (on supported GPUs) | MIG provides hardware-isolated partitions with guaranteed memory QoS. MPS has no isolation guarantees. |
| GPU health monitoring | Custom nvidia-smi parsing | NVIDIA DCGM or prometheus-nvidia-exporter | Purpose-built tools with proper metrics export. |

**Key insight:** The GPU stack has many layers, and each layer has an official solution. Custom implementations invariably miss edge cases (driver version compatibility, cgroup configuration, memory pool fragmentation).

## Common Pitfalls

### Pitfall 1: IOMMU Not Actually Enabled

**What goes wrong:** The host appears configured (kernel parameters set), but IOMMU is disabled in BIOS. GPU passthrough silently fails or produces cryptic QEMU errors.

**Why it happens:** IOMMU is often disabled by default in BIOS. Kernel parameters only request IOMMU; BIOS must actually enable the feature.

**How to avoid:** Validate IOMMU with two checks:
```bash
# Check 1: Kernel sees IOMMU
dmesg | grep -i iommu
# Should show: "IOMMU: enabled" or "Intel-IOMMU: enabled"

# Check 2: IOMMU groups exist
ls /sys/kernel/iommu_groups/
# Should list numbered directories (0/, 1/, 2/, etc.)
```

**Warning signs:** Empty `/sys/kernel/iommu_groups/`, QEMU errors about VFIO, GPU not appearing in VM.

**Confidence:** HIGH -- common issue in GPU passthrough forums.

### Pitfall 2: vfio-pci Not Claiming the GPU

**What goes wrong:** The GPU is still bound to nouveau or nvidia driver on the host instead of vfio-pci. OpenNebula cannot pass the device to VMs.

**Why it happens:** Driver binding order: if nouveau/nvidia loads before vfio-pci, it claims the GPU. The override must be set before boot or the GPU must be manually unbound.

**How to avoid:**
```bash
# Verify current driver
lspci -Dnns <pci_address> -k
# Should show: Kernel driver in use: vfio-pci

# If showing nouveau or nvidia, rebind:
driverctl set-override <pci_address> vfio-pci
```

**Warning signs:** `lspci -k` shows `nvidia` or `nouveau` as kernel driver.

**Confidence:** HIGH -- documented in OpenNebula GPU passthrough guide.

### Pitfall 3: NVIDIA Container Toolkit Not Configured for Docker

**What goes wrong:** Container Toolkit is installed but `docker run --gpus all` fails with "could not select device driver" error.

**Why it happens:** The `nvidia-ctk runtime configure` step was missed. Docker's daemon.json does not reference the NVIDIA runtime.

**How to avoid:**
```bash
# Configure Docker to use NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker

# Verify configuration
cat /etc/docker/daemon.json
# Should contain "nvidia" runtime reference

# Restart Docker
systemctl restart docker
```

**Warning signs:** Error: "could not select device driver 'nvidia' with capabilities: [[gpu]]"

**Confidence:** HIGH -- documented in NVIDIA Container Toolkit install guide.

### Pitfall 4: TensorFlow Pre-allocates All GPU Memory

**What goes wrong:** First TensorFlow process grabs all GPU VRAM. Second process (another ClientApp instance) gets CUDA OOM error even with small models.

**Why it happens:** TensorFlow's default behavior pre-allocates entire GPU memory for performance. This is designed for single-process workloads.

**How to avoid:**
```python
# Set memory growth BEFORE any TensorFlow operations
import tensorflow as tf
gpus = tf.config.list_physical_devices('GPU')
for gpu in gpus:
    tf.config.experimental.set_memory_growth(gpu, True)
```

Or use environment variable:
```bash
TF_FORCE_GPU_ALLOW_GROWTH=true
```

**Warning signs:** CUDA OOM on second process, `nvidia-smi` shows first process using 100% VRAM.

**Confidence:** HIGH -- well-documented TensorFlow behavior.

### Pitfall 5: PyTorch Memory Fraction Not Enforcing Isolation

**What goes wrong:** `torch.cuda.set_per_process_memory_fraction(0.25)` is set, but actual usage exceeds 25% and other processes get OOM.

**Why it happens:** PyTorch's memory fraction is a soft limit that only restricts the caching allocator. CUDA context memory, cuDNN workspace, and other overhead are not counted. The function "is a check done purely after successful allocating" -- not true isolation.

**How to avoid:**
- Treat fraction as guidance, not hard isolation
- For true isolation, use MIG (hardware partitioning) or separate VMs/containers with `CUDA_VISIBLE_DEVICES`
- Set fraction lower than needed (0.20 for expected 25% usage)

**Warning signs:** Total GPU usage exceeds sum of configured fractions.

**Confidence:** HIGH -- documented limitation in PyTorch GitHub issues.

### Pitfall 6: Missing UEFI Causes GPU Initialization Failure

**What goes wrong:** VM boots but GPU shows as "Unknown device" or fails to initialize. NVIDIA driver installation inside VM fails.

**Why it happens:** Modern GPUs (RTX series, H100, A100) require UEFI with Resizable BAR support. Legacy BIOS boot cannot initialize the GPU correctly.

**How to avoid:** Always include in GPU-enabled VM templates:
```
OS = [
    FIRMWARE = "UEFI"
]
FEATURES = [
    MACHINE = "q35"
]
```

**Warning signs:** `lspci` inside VM shows "Unknown device", driver installation fails, nvidia-smi shows no devices.

**Confidence:** HIGH -- documented in OpenNebula GPU passthrough guide.

## Code Examples

Verified patterns from official sources:

### GPU Validation Script (Inside VM)

```bash
#!/bin/bash
# /opt/flower/scripts/validate-gpu.sh
# Validates the complete GPU stack is correctly configured

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

ERRORS=0

# Check 1: NVIDIA kernel module loaded
log "Checking NVIDIA kernel module..."
if lsmod | grep -q nvidia; then
    log "  OK: nvidia module loaded"
else
    log "  ERROR: nvidia module not loaded"
    ERRORS=$((ERRORS + 1))
fi

# Check 2: nvidia-smi responds
log "Checking nvidia-smi..."
if nvidia-smi > /dev/null 2>&1; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)
    GPU_MEMORY=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader | head -1)
    log "  OK: GPU detected - $GPU_NAME ($GPU_MEMORY)"
else
    log "  ERROR: nvidia-smi failed"
    ERRORS=$((ERRORS + 1))
fi

# Check 3: NVIDIA Container Toolkit configured
log "Checking NVIDIA Container Toolkit..."
if grep -q '"nvidia"' /etc/docker/daemon.json 2>/dev/null; then
    log "  OK: Docker configured for NVIDIA runtime"
else
    log "  ERROR: Docker not configured for NVIDIA runtime"
    ERRORS=$((ERRORS + 1))
fi

# Check 4: Docker can access GPU
log "Checking Docker GPU access..."
if docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi > /dev/null 2>&1; then
    log "  OK: Docker containers can access GPU"
else
    log "  ERROR: Docker GPU access failed"
    ERRORS=$((ERRORS + 1))
fi

# Check 5: CUDA version
log "Checking CUDA version..."
CUDA_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
log "  INFO: Driver version: $CUDA_VERSION"

# Summary
echo ""
if [ $ERRORS -eq 0 ]; then
    log "GPU validation PASSED: All checks successful"
    exit 0
else
    log "GPU validation FAILED: $ERRORS error(s) detected"
    exit 1
fi
```

### Host GPU Passthrough Validation Script

```bash
#!/bin/bash
# validate-host-gpu.sh
# Run on OpenNebula KVM host to validate GPU passthrough prerequisites

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

ERRORS=0
WARNINGS=0

# Check 1: IOMMU enabled in kernel
log "Checking IOMMU kernel configuration..."
if grep -q "iommu=on\|intel_iommu=on\|amd_iommu=on" /proc/cmdline; then
    log "  OK: IOMMU enabled in kernel parameters"
else
    log "  ERROR: IOMMU not enabled in kernel parameters"
    log "  FIX: Add 'intel_iommu=on iommu=pt' or 'amd_iommu=on iommu=pt' to GRUB_CMDLINE_LINUX_DEFAULT"
    ERRORS=$((ERRORS + 1))
fi

# Check 2: IOMMU groups exist
log "Checking IOMMU groups..."
if [ -d /sys/kernel/iommu_groups ] && [ "$(ls -A /sys/kernel/iommu_groups)" ]; then
    GROUPS=$(ls /sys/kernel/iommu_groups | wc -l)
    log "  OK: $GROUPS IOMMU groups found"
else
    log "  ERROR: No IOMMU groups found"
    log "  FIX: Ensure IOMMU is enabled in BIOS (Intel VT-d or AMD IOMMU)"
    ERRORS=$((ERRORS + 1))
fi

# Check 3: vfio-pci module loaded
log "Checking vfio-pci module..."
if lsmod | grep -q vfio_pci; then
    log "  OK: vfio-pci module loaded"
else
    log "  WARNING: vfio-pci module not loaded"
    log "  FIX: echo 'vfio-pci' > /etc/modules-load.d/vfio-pci.conf && modprobe vfio-pci"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 4: Find NVIDIA GPUs and check driver binding
log "Checking NVIDIA GPU driver binding..."
NVIDIA_GPUS=$(lspci -D | grep -i nvidia | grep -v Audio || true)
if [ -z "$NVIDIA_GPUS" ]; then
    log "  WARNING: No NVIDIA GPUs found"
    WARNINGS=$((WARNINGS + 1))
else
    while IFS= read -r line; do
        PCI_ADDR=$(echo "$line" | awk '{print $1}')
        GPU_NAME=$(echo "$line" | cut -d: -f4-)
        DRIVER=$(lspci -Dnns "$PCI_ADDR" -k 2>/dev/null | grep "Kernel driver" | awk '{print $NF}')

        if [ "$DRIVER" = "vfio-pci" ]; then
            log "  OK: $PCI_ADDR ($GPU_NAME) bound to vfio-pci"
        elif [ -z "$DRIVER" ]; then
            log "  WARNING: $PCI_ADDR ($GPU_NAME) no driver bound"
            log "  FIX: driverctl set-override $PCI_ADDR vfio-pci"
            WARNINGS=$((WARNINGS + 1))
        else
            log "  ERROR: $PCI_ADDR ($GPU_NAME) bound to $DRIVER (should be vfio-pci)"
            log "  FIX: driverctl set-override $PCI_ADDR vfio-pci"
            ERRORS=$((ERRORS + 1))
        fi
    done <<< "$NVIDIA_GPUS"
fi

# Check 5: udev rules for VFIO
log "Checking VFIO udev rules..."
if grep -rq 'SUBSYSTEM=="vfio"' /etc/udev/rules.d/ 2>/dev/null; then
    log "  OK: VFIO udev rules configured"
else
    log "  WARNING: VFIO udev rules not found"
    log "  FIX: echo 'SUBSYSTEM==\"vfio\", GROUP=\"kvm\", MODE=\"0666\"' > /etc/udev/rules.d/99-vfio.rules"
    WARNINGS=$((WARNINGS + 1))
fi

# Check 6: OpenNebula PCI filter
log "Checking OpenNebula PCI probe filter..."
PCI_CONF="/var/lib/one/remotes/etc/im/kvm-probes.d/pci.conf"
if [ -f "$PCI_CONF" ] && grep -q "10de" "$PCI_CONF"; then
    log "  OK: NVIDIA filter configured in pci.conf"
else
    log "  WARNING: NVIDIA vendor filter not in pci.conf"
    log "  FIX: Add ':filter: \"10de:*\"' to $PCI_CONF"
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
echo ""
if [ $ERRORS -eq 0 ] && [ $WARNINGS -eq 0 ]; then
    log "Host GPU passthrough validation PASSED: All checks successful"
    exit 0
elif [ $ERRORS -eq 0 ]; then
    log "Host GPU passthrough validation PASSED with WARNINGS: $WARNINGS warning(s)"
    exit 0
else
    log "Host GPU passthrough validation FAILED: $ERRORS error(s), $WARNINGS warning(s)"
    exit 1
fi
```

### Framework Memory Configuration

**PyTorch memory fraction:**
```python
import torch

def configure_gpu_memory(fraction: float = 0.5):
    """Configure GPU memory fraction for PyTorch.

    Args:
        fraction: Fraction of GPU memory to use (0.0 to 1.0)

    Note: This is a soft limit. Actual usage may exceed the fraction
    due to CUDA context and framework overhead.
    """
    if torch.cuda.is_available():
        torch.cuda.set_per_process_memory_fraction(fraction)
        print(f"PyTorch GPU memory fraction set to {fraction}")
```

**TensorFlow memory configuration:**
```python
import tensorflow as tf

def configure_gpu_memory(memory_limit_mb: int = None):
    """Configure GPU memory for TensorFlow.

    Args:
        memory_limit_mb: If set, limits GPU memory to this many MB.
                         If None, enables memory growth (dynamic allocation).
    """
    gpus = tf.config.list_physical_devices('GPU')
    if not gpus:
        print("No GPU available")
        return

    try:
        if memory_limit_mb:
            # Hard limit
            tf.config.set_logical_device_configuration(
                gpus[0],
                [tf.config.LogicalDeviceConfiguration(memory_limit=memory_limit_mb)]
            )
            print(f"TensorFlow GPU memory limited to {memory_limit_mb} MB")
        else:
            # Dynamic growth
            for gpu in gpus:
                tf.config.experimental.set_memory_growth(gpu, True)
            print("TensorFlow GPU memory growth enabled")
    except RuntimeError as e:
        print(f"GPU configuration error: {e}")
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| nvidia-docker2 package | NVIDIA Container Toolkit | 2020 | nvidia-docker2 is deprecated. Container Toolkit provides unified solution for Docker, containerd, CRI-O. |
| Manual /dev/nvidia* mounts | `docker run --gpus` flag | Docker 19.03 (2019) | The `--gpus` flag is the standard way to request GPU access. Manual mounts are error-prone. |
| nvidia-smi for partitioning | MIG (Multi-Instance GPU) | NVIDIA A100 (2020) | MIG provides hardware-isolated GPU partitions. nvidia-smi alone cannot provide true isolation. |
| CUDA_MPS_PIPE_DIRECTORY | MIG | A100/H100 era | MPS (Multi-Process Service) has no memory QoS. MIG is preferred for production multi-tenant. |
| SeaBIOS for GPU VMs | UEFI + q35 | ~2020 | Modern GPUs require UEFI for Resizable BAR, proper PCIe initialization. SeaBIOS causes failures. |

**Deprecated/outdated:**
- `nvidia-docker` (v1): Completely deprecated. Use NVIDIA Container Toolkit.
- `nvidia-docker2`: Deprecated. Replaced by nvidia-container-toolkit package.
- `--runtime=nvidia` flag: Still works but `--gpus` flag is preferred.

## Open Questions

Things that could not be fully resolved during research:

1. **MIG profile support in OpenNebula Sunstone UI**
   - What we know: OpenNebula 7.0 docs mention vGPU and MIG support. The host probes detect MIG instances.
   - What's unclear: The exact VM template syntax for requesting a specific MIG profile. Is it automatic selection or explicit profile ID?
   - Recommendation: Defer MIG to a future phase. For Phase 6, focus on full GPU passthrough (one GPU per VM). MIG requires additional host setup and is only relevant for H100/A100 GPUs.
   - **Confidence:** LOW -- documentation is sparse on MIG template syntax.

2. **NVIDIA driver version compatibility with Ubuntu 24.04 kernel**
   - What we know: Ubuntu 24.04 uses kernel 6.8+. NVIDIA drivers 535+ support this kernel.
   - What's unclear: Whether specific driver versions have issues with specific kernel point releases. The NVIDIA forums show occasional compatibility reports.
   - Recommendation: Pin to a tested driver version in the appliance image (e.g., nvidia-driver-545 or nvidia-driver-550). Document the tested combination.
   - **Confidence:** MEDIUM -- common setup but version combinations vary.

3. **Flower simulation engine GPU fraction vs. production SuperNode**
   - What we know: Flower's simulation engine supports `client-resources.num-gpus = 0.25` for fractional GPU assignment.
   - What's unclear: Whether this same configuration applies to production SuperNode deployments or only to simulation backends.
   - Recommendation: For production SuperNode, use framework-level memory configuration (PyTorch/TensorFlow APIs) rather than relying on Flower-specific resource limits.
   - **Confidence:** LOW -- the docs focus on simulation engine, not production SuperNode.

4. **GPU health monitoring in Flower/OpenNebula integration**
   - What we know: nvidia-smi provides GPU metrics. OpenNebula probes can collect host-level GPU info.
   - What's unclear: How to expose per-VM GPU metrics to OneGate or external monitoring. NVIDIA DCGM is the production solution but adds complexity.
   - Recommendation: For Phase 6, spec a basic nvidia-smi-based health check inside the VM. Defer DCGM/prometheus integration to Phase 8 (observability).
   - **Confidence:** MEDIUM -- individual pieces are documented, integration is novel.

## Sources

### Primary (HIGH confidence)
- [OpenNebula 7.0 NVIDIA GPU Passthrough](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/nvidia_gpu_passthrough/) - Host IOMMU/VFIO configuration, VM template requirements
- [OpenNebula 7.0 PCI Passthrough](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/pci_passthrough/) - General PCI passthrough mechanics
- [OpenNebula 7.0 vGPU & MIG](https://docs.opennebula.io/7.0/product/cluster_configuration/hosts_and_clusters/vgpu/) - MIG and vGPU configuration
- [NVIDIA Container Toolkit Install Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) - Container Toolkit installation and Docker configuration
- [TensorFlow GPU Guide](https://www.tensorflow.org/guide/gpu) - GPU memory configuration, memory growth, device visibility
- [PyTorch CUDA Semantics](https://docs.pytorch.org/docs/stable/notes/cuda.html) - Device selection, memory management, fallback patterns

### Secondary (MEDIUM confidence)
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/index.html) - MIG concepts and configuration
- [PyTorch set_per_process_memory_fraction](https://docs.pytorch.org/docs/stable/generated/torch.cuda.memory.set_per_process_memory_fraction.html) - Memory fraction API (note: soft limit)
- [Flower Simulation GPU Configuration](https://flower.ai/docs/framework/how-to-run-simulations.html) - GPU resource allocation for simulations
- [Docker GPU Support](https://docs.docker.com/compose/how-tos/gpu-support/) - Docker Compose GPU syntax

### Tertiary (LOW confidence)
- [PyTorch memory fraction limitations (GitHub #69688)](https://github.com/pytorch/pytorch/issues/69688) - Documents soft limit behavior
- [Flower OOM Issue #3238](https://github.com/adap/flower/issues/3238) - Community discussion on GPU memory in FL
- Proxmox and community GPU passthrough guides - Useful for validation script patterns

## Metadata

**Confidence breakdown:**
- Host configuration (IOMMU/VFIO): HIGH -- well-documented in OpenNebula 7.0
- VM template requirements: HIGH -- official documentation with examples
- NVIDIA Container Toolkit: HIGH -- official NVIDIA documentation
- Memory management patterns: MEDIUM -- framework APIs documented but limitations less visible
- MIG integration with OpenNebula: LOW -- sparse documentation on template syntax
- CPU-only fallback: HIGH -- standard framework patterns

**Research date:** 2026-02-08
**Valid until:** 2026-03-08 (30 days -- GPU drivers and Container Toolkit update frequently)
