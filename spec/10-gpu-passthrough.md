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
