# GPU Passthrough Stack

**Requirement:** ML-02
**Phase:** 06 - GPU Acceleration
**Status:** Specification

---

## 1. Purpose and Scope

This section defines the complete GPU passthrough stack for accelerated federated learning training on SuperNode appliances. The stack enables NVIDIA GPUs to be passed through from OpenNebula KVM hosts into SuperNode VMs, exposed to Docker containers via the NVIDIA Container Toolkit, and managed at the application level with framework-specific CUDA memory APIs.

**What this section covers:**
- Four-layer GPU stack: host prerequisites, VM template, container runtime, application memory management.
- NVIDIA GPU passthrough configuration for OpenNebula 7.0 KVM hosts.
- NVIDIA Container Toolkit installation and Docker configuration inside VMs.
- PyTorch and TensorFlow CUDA memory management patterns.
- CPU-only fallback path for environments without GPU passthrough capability.
- Decision records for key architectural choices.

**What this section does NOT cover:**
- Multi-Instance GPU (MIG) partitioning (deferred to future phase).
- vGPU (NVIDIA GRID) configuration (requires commercial license; out of scope).
- GPU monitoring and metrics export (Phase 8 -- Monitoring and Observability).
- GPU-enabled Dockerfile variants (Plan 06-02 defines the GPU image build changes).
- Full contextualization variable USER_INPUT definitions (Plan 06-02 adds to contextualization reference).

**Requirement traceability:** This document satisfies ML-02 (GPU passthrough specification for accelerated training on client nodes).

**Relationship to base SuperNode spec:** The SuperNode appliance (`spec/02-supernode-appliance.md`) defines a CPU-only baseline. This spec extends that baseline with GPU passthrough capabilities. The base appliance remains valid for CPU-only deployments. GPU enablement is opt-in via the `FL_GPU_ENABLED` contextualization variable.

---

## 2. Architecture Overview

The GPU passthrough stack has four layers, each building on the one below. All four layers must be correctly configured for a GPU-accelerated training workload to function.

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

**Layer responsibilities:**
- **Layer 1** (infrastructure team): One-time host configuration. Requires physical access to BIOS and root access to the KVM host. Not managed by the appliance.
- **Layer 2** (OpenNebula admin): VM template definition. Configured in Sunstone or via `onetemplate` CLI. Determines which GPU is assigned to each VM.
- **Layer 3** (appliance image): Pre-installed in the GPU-enabled QCOW2 image. NVIDIA drivers and Container Toolkit are baked into the image during build.
- **Layer 4** (application developer): ClientApp code patterns for GPU memory management and CPU fallback. Guided by this spec but implemented per workload.

---

## 3. Layer 1: Host Prerequisites

The KVM host must be configured for PCI passthrough before any GPU can be assigned to a VM. These steps are performed once per host by the infrastructure team.

### 3a. BIOS Configuration

IOMMU must be enabled in the system BIOS/UEFI firmware. This is a manual step that requires physical or IPMI/BMC access to the server.

| CPU Vendor | BIOS Setting | Location (typical) |
|------------|-------------|-------------------|
| Intel | Intel VT-d | Advanced > CPU Configuration or Chipset Configuration |
| AMD | AMD IOMMU (AMD-Vi) | Advanced > IOMMU or Advanced > NBC Configuration |

**Note:** The exact BIOS menu path varies by motherboard manufacturer. Consult the server's hardware manual. IOMMU is often disabled by default.

### 3b. Kernel Parameters

After enabling IOMMU in BIOS, the Linux kernel must be instructed to use it. Edit `/etc/default/grub`:

**Intel systems:**

```bash
GRUB_CMDLINE_LINUX_DEFAULT="intel_iommu=on iommu=pt"
```

**AMD systems:**

```bash
GRUB_CMDLINE_LINUX_DEFAULT="amd_iommu=on iommu=pt"
```

Apply the configuration:

```bash
update-grub && reboot
```

**Verification:**

```bash
# Check 1: Kernel sees IOMMU
dmesg | grep -i iommu
# Expected: "IOMMU: enabled" or "Intel-IOMMU: enabled"

# Check 2: IOMMU groups exist
ls /sys/kernel/iommu_groups/
# Expected: Numbered directories (0/, 1/, 2/, etc.)
```

The `iommu=pt` parameter enables passthrough mode, which improves performance for devices not behind a VFIO driver by bypassing DMA remapping for host devices.

### 3c. vfio-pci Module Loading

The vfio-pci kernel module provides userspace access to PCI devices, enabling QEMU/KVM to assign them to VMs. Configure it to load at boot:

```bash
echo "vfio-pci" | sudo tee /etc/modules-load.d/vfio-pci.conf
```

Load the module immediately (without reboot):

```bash
modprobe vfio-pci
```

**Verification:**

```bash
lsmod | grep vfio_pci
# Expected: vfio_pci listed with its dependencies (vfio_pci_core, vfio, etc.)
```

### 3d. GPU Driver Binding with driverctl

Each GPU intended for passthrough must be bound to the `vfio-pci` driver instead of the host's NVIDIA or nouveau driver. The `driverctl` utility creates persistent driver overrides that survive kernel updates and reboots.

```bash
# 1. Install driverctl
apt install driverctl

# 2. Identify GPU PCI address
lspci -D | grep -i nvidia
# Example output: 0000:e1:00.0 3D controller: NVIDIA Corporation ...

# 3. Bind GPU to vfio-pci (persistent across reboots)
driverctl set-override 0000:e1:00.0 vfio-pci

# 4. Verify binding
lspci -Dnns 0000:e1:00.0 -k
# Expected: Kernel driver in use: vfio-pci
```

**Audio device:** Many NVIDIA GPUs include an HDMI audio controller on a secondary PCI function (e.g., `0000:e1:00.1`). If the GPU and audio device share an IOMMU group, both must be bound to vfio-pci:

```bash
driverctl set-override 0000:e1:00.1 vfio-pci
```

**Why driverctl over alternatives:** driverctl creates persistent overrides stored in `/etc/driverctl.d/` that survive kernel updates. Init scripts or modprobe rules may execute before the GPU module loads, causing race conditions. driverctl operates at the systemd level and reliably intercepts driver binding.

### 3e. udev Rules for VFIO Permissions

OpenNebula's libvirt/QEMU process needs access to VFIO device files. Create a udev rule to set appropriate permissions:

```bash
echo 'SUBSYSTEM=="vfio", GROUP="kvm", MODE="0666"' > /etc/udev/rules.d/99-vfio.rules
udevadm control --reload && udevadm trigger
```

**Verification:**

```bash
ls -la /dev/vfio/
# Expected: VFIO group devices with mode 0666 and group kvm
```

### 3f. Host Configuration Summary

After completing all steps, verify the full host configuration:

| Check | Command | Expected Output |
|-------|---------|-----------------|
| IOMMU enabled | `dmesg \| grep -i iommu` | "IOMMU: enabled" or similar |
| IOMMU groups exist | `ls /sys/kernel/iommu_groups/` | Numbered directories |
| vfio-pci loaded | `lsmod \| grep vfio_pci` | Module listed |
| GPU bound to vfio-pci | `lspci -Dnns <addr> -k` | "Kernel driver in use: vfio-pci" |
| VFIO permissions | `ls -la /dev/vfio/` | Mode 0666, group kvm |
| driverctl override active | `driverctl list-overrides` | PCI address -> vfio-pci |

---

## 4. OpenNebula PCI Device Discovery

After the host is configured for GPU passthrough, OpenNebula must be configured to discover and track NVIDIA GPUs for VM assignment.

### 4a. PCI Probe Filter Configuration

Edit the PCI probe configuration to include NVIDIA devices (vendor ID `10de`):

```bash
# Edit /var/lib/one/remotes/etc/im/kvm-probes.d/pci.conf
# Add NVIDIA vendor filter:
:filter: '10de:*'
```

This filter tells the OpenNebula monitoring probes to report all PCI devices with NVIDIA's vendor ID. Without this filter, GPUs are not visible in the PCI device inventory.

### 4b. Probe Synchronization

After modifying the PCI probe configuration, synchronize the probes to all hosts:

```bash
# Synchronize probes to all hosts
onehost sync -f

# Wait for probe cycle (up to 10 minutes) or force update
onehost forceupdate <HOST_ID>
```

**Timing:** OpenNebula monitoring probes run on a configurable interval (default: every few minutes). After `onehost sync -f`, the next probe cycle will discover the GPU. Use `onehost forceupdate` to trigger an immediate probe if needed.

### 4c. Verification

Confirm that OpenNebula has discovered the GPU:

```bash
onehost show <HOST_ID> | grep -A 20 "PCI"
```

The output should list the NVIDIA GPU with its PCI address, vendor ID (`10de`), and device ID. The GPU's status should indicate it is available for assignment (not already assigned to a VM).

**Sunstone verification:** In the OpenNebula Sunstone UI, navigate to Infrastructure > Hosts > [host] > PCI tab. The NVIDIA GPU should appear in the PCI devices list with vendor "NVIDIA Corporation".

---

## 5. Layer 2: VM Template Requirements

The GPU-enabled VM template must include specific attributes for PCI passthrough to function correctly. Each attribute addresses a hardware or firmware requirement of modern NVIDIA GPUs.

### 5a. Required Template Attributes

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

### 5b. Attribute Justification

| Attribute | Value | Why Required |
|-----------|-------|-------------|
| `FIRMWARE = "UEFI"` | OVMF UEFI firmware | Modern GPUs (RTX series, H100, A100) require UEFI for Resizable BAR (ReBAR) support. Legacy SeaBIOS cannot initialize these GPUs, causing "Unknown device" errors in `lspci` inside the VM. |
| `MACHINE = "q35"` | Intel Q35 chipset | The q35 machine type provides native PCIe bus emulation. The older i440fx machine type uses emulated PCI-to-PCIe bridges that add latency and can cause GPU initialization failures. |
| `MODEL = "host-passthrough"` | CPU model passthrough | Exposes the host CPU's exact feature flags to the VM. Required for CUDA operations that depend on specific CPU instructions (AVX, AVX-512). Without this, some CUDA kernels may fail or fall back to slower code paths. |
| `PIN_POLICY = "CORE"` | CPU core pinning | Pins vCPUs to specific physical cores, preventing the hypervisor from migrating vCPU threads across cores. Eliminates context-switch overhead during GPU-intensive training loops. |
| `SOCKETS = "1"` | Single socket topology | Combined with `CORES = n`, presents all vCPUs as cores on a single socket. Avoids cross-socket NUMA penalties when the GPU is attached to one NUMA node. |
| `SHORT_ADDRESS = "<addr>"` | GPU PCI address | Identifies which specific GPU to pass through to this VM. The address comes from `onehost show` output (e.g., `e1:00.0`). |

### 5c. NUMA-Aware CPU Pinning

For optimal GPU training performance, vCPUs should be pinned to the same NUMA node as the GPU. Cross-NUMA memory access adds 30-50% latency penalty, which directly impacts GPU training throughput.

**Identifying GPU NUMA node:**

```bash
# On the KVM host, find the GPU's NUMA node
cat /sys/bus/pci/devices/0000:e1:00.0/numa_node
# Output: 1 (GPU is on NUMA node 1)

# List CPUs on that NUMA node
lscpu --parse=CPU,NODE | grep ",1$"
# Output: CPU IDs on NUMA node 1
```

**Recommendation:** When creating VM templates for GPU workloads, pin the VM's vCPUs to cores on the same NUMA node as the assigned GPU. OpenNebula's `TOPOLOGY` section with `PIN_POLICY = "CORE"` ensures pinning, but the operator must verify that the assigned cores belong to the correct NUMA node.

### 5d. Multi-GPU Assignment

To assign multiple GPUs to a single VM, add multiple `PCI` entries:

```
PCI = [
    SHORT_ADDRESS = "<gpu_1_pci_address>"
]
PCI = [
    SHORT_ADDRESS = "<gpu_2_pci_address>"
]
```

Each GPU must be individually bound to vfio-pci on the host (Section 3d). All GPUs assigned to a single VM should ideally reside on the same NUMA node.

---

## 6. Anti-Patterns: Layers 1-2

Common configuration mistakes that cause GPU passthrough to fail silently or produce cryptic errors.

| Anti-Pattern | Symptom | Root Cause | Fix |
|-------------|---------|-----------|-----|
| IOMMU disabled in BIOS despite kernel params | `ls /sys/kernel/iommu_groups/` is empty; QEMU errors about VFIO | Kernel parameters request IOMMU, but the BIOS feature is off. Both must be enabled. | Enable Intel VT-d or AMD IOMMU in BIOS settings. |
| GPU bound to nouveau/nvidia instead of vfio-pci | `lspci -k` shows `nvidia` or `nouveau` as kernel driver; GPU not available for passthrough | Driver binding order: if the host's GPU driver loads before vfio-pci claims the device, passthrough is impossible. | Run `driverctl set-override <addr> vfio-pci` and reboot. |
| Missing UEFI firmware in VM template | `lspci` inside VM shows "Unknown device"; nvidia driver installation fails; nvidia-smi shows no devices | Modern GPUs require UEFI for Resizable BAR. Legacy SeaBIOS cannot initialize the GPU correctly. | Add `OS = [ FIRMWARE = "UEFI" ]` to the VM template. |
| Using i440fx instead of q35 machine type | GPU visible but performance is degraded; occasional PCIe errors | i440fx uses PCI-to-PCIe bridges that add latency and may not support GPU BAR sizes. | Add `FEATURES = [ MACHINE = "q35" ]` to the VM template. |
| Cross-NUMA CPU scheduling | Training throughput 30-50% lower than expected despite GPU being functional | vCPUs scheduled on a different NUMA node than the GPU. Memory access crosses the NUMA interconnect. | Pin vCPUs to cores on the same NUMA node as the GPU using `TOPOLOGY = [ PIN_POLICY = "CORE" ]`. |
| Missing audio device binding | QEMU fails to start VM with "device is already in use" error | GPU and HDMI audio controller share an IOMMU group. Both must be bound to vfio-pci. | Bind both the GPU (e.g., `e1:00.0`) and audio device (e.g., `e1:00.1`) to vfio-pci. |

---

## 7. Layer 3: Container Runtime (NVIDIA Container Toolkit)

Once the GPU is passed through to the VM (Layers 1-2), the NVIDIA driver and Container Toolkit must be installed inside the VM to expose the GPU to Docker containers.

### 7a. Prerequisites

Before proceeding, verify that the GPU is visible inside the VM:

```bash
lspci | grep -i nvidia
# Expected: NVIDIA GPU listed (e.g., "3D controller: NVIDIA Corporation ...")
```

If the GPU is not visible, review Layers 1-2 configuration. Common causes: missing UEFI firmware, GPU not bound to vfio-pci on host, PCI address not specified in VM template.

### 7b. NVIDIA Driver Installation

Install the NVIDIA proprietary driver inside the VM. The GPU-enabled QCOW2 image pre-installs this driver during the build process.

```bash
# Install NVIDIA driver (inside VM with passthrough GPU)
apt update && apt install -y nvidia-driver-545

# Reboot to load the kernel module
reboot

# Verify GPU detection
nvidia-smi
```

**Driver version recommendation:** Pin to `nvidia-driver-545` or `nvidia-driver-550` for Ubuntu 24.04 (kernel 6.8+). These versions are tested with the 6.8 kernel series. Newer driver versions may be used but should be validated against the target kernel.

**Verification:**

```bash
# Check kernel module is loaded
lsmod | grep nvidia
# Expected: nvidia module listed

# Check GPU is detected
nvidia-smi
# Expected: GPU name, driver version, CUDA version, memory info
```

### 7c. NVIDIA Container Toolkit Installation

The NVIDIA Container Toolkit enables Docker containers to access the host GPU via the `--gpus` flag. This replaces the deprecated `nvidia-docker2` package.

```bash
# 1. Add NVIDIA Container Toolkit repository
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

# 2. Install Container Toolkit
apt update
apt install -y nvidia-container-toolkit

# 3. Configure Docker to use NVIDIA runtime
nvidia-ctk runtime configure --runtime=docker

# 4. Restart Docker to apply configuration
systemctl restart docker
```

**What `nvidia-ctk runtime configure` does:** Modifies `/etc/docker/daemon.json` to register the NVIDIA container runtime. Without this step, `docker run --gpus all` fails with "could not select device driver 'nvidia'" error.

### 7d. Container Toolkit Verification

```bash
# Verify Docker can access the GPU
docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi
```

This command pulls a minimal CUDA base image (if not already present) and runs `nvidia-smi` inside the container. A successful output shows the GPU name, driver version, and CUDA version -- confirming that all three layers (host, VM, container runtime) are correctly configured.

**Verification checklist:**

| Check | Command | Expected Output |
|-------|---------|-----------------|
| NVIDIA module loaded | `lsmod \| grep nvidia` | nvidia module listed |
| nvidia-smi works | `nvidia-smi` | GPU info displayed |
| Docker configured | `grep nvidia /etc/docker/daemon.json` | NVIDIA runtime reference |
| Container GPU access | `docker run --rm --gpus all nvidia/cuda:12.0-base nvidia-smi` | GPU info from inside container |

### 7e. Pre-baked vs. Boot-time Installation

The GPU-enabled QCOW2 image SHALL pre-install the NVIDIA driver and Container Toolkit during image build. This follows the same pre-baking strategy as the base SuperNode appliance (see `spec/02-supernode-appliance.md`, Section 4).

**Rationale:**
- NVIDIA driver installation requires a reboot (kernel module loading). This is incompatible with the single-boot appliance lifecycle.
- Container Toolkit installation requires network access to NVIDIA's APT repository. Air-gapped environments cannot install at boot.
- Pre-baking ensures the GPU stack is ready immediately when the VM boots with a passthrough GPU.

**When no GPU is assigned:** If a GPU-enabled QCOW2 boots without a passthrough GPU, the NVIDIA driver loads but finds no device. This is a benign condition -- `nvidia-smi` reports "No devices were found" and the appliance falls back to CPU-only operation (Section 9).

---

## 8. SuperNode Docker Run Modification

When `FL_GPU_ENABLED=YES` is set in the VM's CONTEXT variables, the SuperNode bootstrap script adds GPU access flags to the Docker run command.

### 8a. GPU-Enabled Docker Run Command

```bash
# GPU-enabled SuperNode container
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  --gpus all \
  -v /opt/flower/data:/app/data:ro \
  -e FLWR_LOG_LEVEL=${FL_LOG_LEVEL:-INFO} \
  -e CUDA_VISIBLE_DEVICES=${FL_CUDA_VISIBLE_DEVICES:-all} \
  ${IMAGE_TAG} \
  --insecure \
  --superlink ${SUPERLINK_ADDRESS}:9092 \
  --isolation subprocess \
  --node-config "${FL_NODE_CONFIG}" \
  --max-retries ${FL_MAX_RETRIES:-0} \
  --max-wait-time ${FL_MAX_WAIT_TIME:-0}
```

### 8b. Differences from CPU-Only Docker Run

| Parameter | CPU-Only (Phase 1) | GPU-Enabled (Phase 6) | Purpose |
|-----------|--------------------|-----------------------|---------|
| `--gpus all` | absent | present | Requests all available GPUs from the NVIDIA Container Toolkit. The toolkit handles device node creation, driver library injection, and cgroup configuration. |
| `CUDA_VISIBLE_DEVICES` | absent | `${FL_CUDA_VISIBLE_DEVICES:-all}` | Controls which GPUs are visible inside the container. Default `all` exposes every GPU assigned to the VM. Set to specific device IDs (e.g., `0`, `0,1`) for multi-GPU selection. |

All other parameters (volume mounts, Flower CLI flags, restart policy) remain unchanged from the CPU-only configuration in `spec/02-supernode-appliance.md`, Section 8.

### 8c. Bootstrap Script Logic

The bootstrap script conditionally adds GPU flags based on `FL_GPU_ENABLED`:

```bash
# GPU flag construction (Phase 6)
GPU_FLAGS=""
if [ "${FL_GPU_ENABLED:-NO}" = "YES" ]; then
    GPU_FLAGS="--gpus all -e CUDA_VISIBLE_DEVICES=${FL_CUDA_VISIBLE_DEVICES:-all}"
    log "INFO" "GPU passthrough enabled"

    # Validate GPU is actually available
    if ! nvidia-smi > /dev/null 2>&1; then
        log "WARNING" "FL_GPU_ENABLED=YES but nvidia-smi failed"
        log "WARNING" "Container will start with --gpus flag but GPU may not be available"
        log "WARNING" "Training will fall back to CPU if ClientApp handles GPU absence correctly"
    fi
fi

# Docker run command (GPU_FLAGS inserted conditionally)
docker run -d \
  --name flower-supernode \
  --restart unless-stopped \
  ${GPU_FLAGS} \
  -v /opt/flower/data:/app/data:ro \
  ...
```

**FL_GPU_ENABLED=YES with no GPU:** This is a WARNING, not a FATAL error. The container starts with `--gpus all`, but if no GPU is available, the NVIDIA Container Toolkit gracefully handles the absence. The ClientApp must implement CPU-only fallback (Section 9). This design allows a single QCOW2 image to work in both GPU and CPU-only environments.

---

## 9. CPU-Only Fallback Path

Every ClientApp MUST handle the case where no GPU is available. This is a design principle, not an optional optimization. The fallback path ensures that:
- The same ClientApp code works on both GPU-enabled and CPU-only SuperNodes.
- A GPU failure (driver crash, CUDA error) degrades to CPU training rather than crashing.
- Testing and development can proceed without GPU hardware.

### 9a. Design Principle

**Rule:** `FL_GPU_ENABLED=YES` with no GPU detected is a WARNING, not a FATAL error.

The boot sequence behavior:
1. `FL_GPU_ENABLED=YES` is set in CONTEXT variables.
2. The bootstrap script adds `--gpus all` to the Docker run command.
3. `nvidia-smi` fails (no GPU present) -- bootstrap logs a WARNING.
4. The container starts. Docker's `--gpus` flag with no GPU available does not prevent container startup.
5. The ClientApp detects no CUDA device and falls back to CPU training.
6. Training proceeds at reduced speed but remains functional.

### 9b. PyTorch Fallback Pattern

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
# All tensors and operations use the selected device
```

### 9c. TensorFlow Fallback Pattern

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

### 9d. Logging Requirement

**ClientApp MUST log the device being used.** This is not optional. Without device logging, operators cannot determine whether training is running on GPU or CPU from the container logs.

Required log output at ClientApp startup:
- GPU available: `"Using GPU: NVIDIA A100-SXM4-40GB"` (include GPU model name)
- CPU fallback: `"CUDA not available, using CPU"` or `"No GPU available, using CPU"`

This logging enables operators to verify GPU utilization across a fleet of SuperNodes by inspecting `docker logs flower-supernode` on each VM.

---

## 10. Layer 4: Application CUDA Memory Management

When a GPU is available, the ClientApp should configure CUDA memory allocation to prevent out-of-memory errors, especially in multi-client scenarios where multiple SuperNode containers share a single GPU.

### 10a. PyTorch Memory Configuration

**Memory fraction (soft limit):**

```python
import torch

def configure_gpu_memory(fraction: float = 0.5):
    """Configure GPU memory fraction for PyTorch.

    Args:
        fraction: Fraction of GPU memory to use (0.0 to 1.0)

    Note: This is a SOFT limit. Actual usage may exceed the fraction
    due to CUDA context, cuDNN workspace, and framework overhead.
    The function only restricts the caching allocator, not total
    GPU memory consumption.
    """
    if torch.cuda.is_available():
        torch.cuda.set_per_process_memory_fraction(fraction)
        print(f"PyTorch GPU memory fraction set to {fraction}")
```

**Caveat:** `torch.cuda.set_per_process_memory_fraction()` is a soft limit that only restricts the PyTorch caching allocator. CUDA context memory (~300-500 MB), cuDNN workspace, and other overhead are not counted against the fraction. Actual GPU memory usage may exceed the configured fraction. For true memory isolation, use MIG (hardware partitioning) or separate VMs with dedicated GPUs.

**CUDA_VISIBLE_DEVICES (device selection):**

```bash
# Limit container to specific GPU(s)
CUDA_VISIBLE_DEVICES=0        # First GPU only
CUDA_VISIBLE_DEVICES=0,1      # First two GPUs
CUDA_VISIBLE_DEVICES=""        # No GPUs (force CPU)
```

### 10b. TensorFlow Memory Configuration

TensorFlow provides two memory management approaches:

**Dynamic memory growth (recommended default):**

```python
import tensorflow as tf

gpus = tf.config.list_physical_devices('GPU')
for gpu in gpus:
    tf.config.experimental.set_memory_growth(gpu, True)
```

This allocates GPU memory on demand rather than pre-allocating the entire GPU. Each TensorFlow operation allocates only the memory it needs, and the allocation grows as needed. This is the recommended default for single-client scenarios because it is simple and avoids wasted memory.

**Hard memory limit:**

```python
import tensorflow as tf

gpus = tf.config.list_physical_devices('GPU')
tf.config.set_logical_device_configuration(
    gpus[0],
    [tf.config.LogicalDeviceConfiguration(memory_limit=4096)]  # 4 GB
)
```

This creates a virtual GPU device with a hard memory cap. TensorFlow operations that exceed this limit receive an OOM error. Use this approach when multiple TensorFlow processes share a single GPU and each needs a guaranteed memory allocation.

**Environment variable alternative:**

```bash
TF_FORCE_GPU_ALLOW_GROWTH=true
```

This environment variable achieves the same effect as `set_memory_growth(gpu, True)` without code changes. It can be set in the Docker run command via the `supernode.env` file.

### 10c. When to Use Each Approach

| Scenario | PyTorch Recommendation | TensorFlow Recommendation |
|----------|----------------------|--------------------------|
| Single ClientApp per GPU (default) | No memory configuration needed (uses all available memory) | `set_memory_growth(gpu, True)` -- prevents pre-allocation of unused memory |
| Multiple ClientApps sharing a GPU | `set_per_process_memory_fraction(0.5)` -- soft limit per process | `set_logical_device_configuration(memory_limit=N)` -- hard limit per process |
| Testing without GPU | CPU fallback (Section 9) | CPU fallback (Section 9) |
| Maximum training performance | No limits; let framework manage memory | `set_memory_growth(gpu, True)` -- dynamic allocation with no ceiling |

**Default recommendation:** For the Flower-OpenNebula appliance, the default configuration is one ClientApp per GPU (subprocess isolation mode with `--gpus all`). In this scenario:
- **PyTorch:** No memory configuration needed. PyTorch manages the caching allocator automatically.
- **TensorFlow:** Enable memory growth to prevent pre-allocating all GPU memory. Set via `TF_FORCE_GPU_ALLOW_GROWTH=true` environment variable in the Docker run command.

---

## 11. Anti-Patterns: Layers 3-4

Common application-level mistakes that cause GPU training failures or poor performance.

| Anti-Pattern | Symptom | Root Cause | Fix |
|-------------|---------|-----------|-----|
| Assuming GPU is always present | `RuntimeError: CUDA error: no kernel image` or `AttributeError: 'NoneType' object has no attribute 'to'` | ClientApp calls `.cuda()` or `.to("cuda")` without checking `torch.cuda.is_available()` | Use the fallback pattern from Section 9: check GPU availability, select device, move model and tensors to device. |
| TensorFlow pre-allocates all GPU memory | Second ClientApp process gets `CUDA_ERROR_OUT_OF_MEMORY`; `nvidia-smi` shows first process using 100% VRAM | TensorFlow's default behavior pre-allocates entire GPU memory for performance. Designed for single-process workloads. | Call `tf.config.experimental.set_memory_growth(gpu, True)` before any TensorFlow operations. |
| Missing `nvidia-ctk runtime configure` | `docker run --gpus all` fails with "could not select device driver 'nvidia' with capabilities: [[gpu]]" | Container Toolkit is installed but Docker daemon.json was not updated to reference the NVIDIA runtime. | Run `nvidia-ctk runtime configure --runtime=docker && systemctl restart docker`. |
| Treating PyTorch memory fraction as hard limit | Total GPU usage across processes exceeds configured fractions; unexpected OOM errors | `set_per_process_memory_fraction()` is a soft limit. CUDA context and framework overhead are not counted. | Set fractions lower than target (0.20 for expected 25% usage). For true isolation, use MIG or separate VMs. |
| Calling memory configuration after GPU operations | `RuntimeError: GPU memory configuration must be set before initialization` | TensorFlow requires `set_memory_growth()` to be called before any GPU operations. PyTorch is more lenient but best practice is early configuration. | Call memory configuration functions at the very beginning of ClientApp initialization, before any model or data operations. |

---
