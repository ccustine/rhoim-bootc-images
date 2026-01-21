# RHOIM NVIDIA Base Image - RHEL 9 Bootc

This directory contains the Containerfile for building a GPU-enabled RHEL 9 bootc base image with NVIDIA drivers pre-installed.

## Overview

- **Base Image**: `registry.redhat.io/rhel9/rhel-bootc:latest`
- **x86_64**: NVIDIA open kernel modules (signed by Red Hat)
- **arm64**: CPU-only (no GPU drivers)
- **Purpose**: Foundation layer for vLLM, RHAIIS, or custom inference workloads

## Prerequisites

1. **Red Hat Subscription**
   - Access to `registry.redhat.io` (requires authentication)
   - Run `podman login registry.redhat.io` before building

2. **Build Tools**
   - Podman (recommended) or Docker
   - For cross-platform builds: QEMU user-mode emulation

## Build Instructions

### x86_64 (with NVIDIA drivers)

```bash
cd nvidia-base

podman build \
  --platform linux/amd64 \
  -t localhost/rhoim-nvidia-base:latest \
  -f ./Containerfile .
```

### arm64 (CPU-only)

```bash
cd nvidia-base

podman build \
  --platform linux/arm64 \
  -t localhost/rhoim-nvidia-base:latest \
  -f ./Containerfile .
```

### Build on macOS (Apple Silicon)

Building x86_64 images with NVIDIA drivers on macOS requires emulation:

```bash
# Ensure QEMU is installed
brew install qemu

# Build x86_64 image (will be slow due to emulation)
podman build \
  --platform linux/amd64 \
  -t localhost/rhoim-nvidia-base:latest \
  -f ./Containerfile .
```

For faster builds, use a native x86_64 build host (e.g., GitHub Actions, AWS EC2).

## Pushing to Registry

The official registry for this image is:

```
quay.io/rhoim/nvidia-bootc-base
```

### Push to Quay.io

```bash
# Login to Quay.io
podman login quay.io

# Tag and push
podman tag localhost/rhoim-nvidia-base:latest quay.io/rhoim/rhoim-nvidia-base:latest
podman push quay.io/rhoim/rhoim-nvidia-base:latest
```

## NVIDIA Driver Details

### Driver Flavor

This image uses the **NVIDIA open kernel modules** (`nvidia-driver:open-dkms`):
- Open source kernel modules compiled and signed by Red Hat
- Works with UEFI Secure Boot enabled
- Compatible with Turing and newer GPUs (GTX 16xx, RTX 20xx+)

### Supported GPUs

The open kernel modules support:
- NVIDIA Datacenter GPUs (A100, H100, L4, L40, etc.)
- NVIDIA RTX Professional GPUs
- NVIDIA GeForce RTX (Turing and newer)

For older GPUs (Pascal, Maxwell), use the proprietary driver stream instead by modifying the Containerfile to use `nvidia-driver:latest-dkms`.

### Driver Packages Installed

| Package | Description |
|---------|-------------|
| `nvidia-driver` | Core driver and utilities |
| `nvidia-driver-cuda` | CUDA driver components |
| `nvidia-driver-libs` | Runtime libraries |
| `nvidia-driver-NVML` | NVIDIA Management Library |

## Layering Applications

This image is designed as a base layer. To add vLLM or RHAIIS:

### Example: Layering vLLM

```dockerfile
# Use the NVIDIA base as foundation
FROM localhost/rhoim-nvidia-base:latest

# Copy vLLM from a builder stage
COPY --from=vllm-builder /opt/vllm-venv /opt/vllm-venv

# Add your application configuration
COPY etc/ /etc/

# Enable your service
RUN systemctl enable my-inference.service
```

### Example: Layering RHAIIS

```dockerfile
FROM localhost/rhoim-nvidia-base:latest

# Pull RHAIIS components
# ... RHAIIS-specific configuration
```

## Converting to Bootable VM

After building, convert to a bootable VM image using bootc-image-builder:

```bash
mkdir -p images

podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-nvidia-base:latest
```

The VM image will be at `images/qcow2/disk.qcow2`.

## Verification

### Check NVIDIA Driver in Container

```bash
# Run the container
podman run -it --rm --privileged localhost/rhoim-nvidia-base:latest /bin/bash

# Inside container: check driver
modinfo nvidia
nvidia-smi  # Only works with actual GPU hardware
```

### Check Kernel Modules

```bash
# List installed kernel modules
ls /usr/lib/modules/*/extra/nvidia/
```

## Troubleshooting

### Build Fails: "No package kernel-devel available"

The kernel-devel package version must match the kernel in the bootc image. If this fails:
1. The bootc base image may have been updated with a new kernel
2. Wait for kernel-devel packages to sync (usually within 24 hours)
3. Or pin to a specific bootc image tag

### Build Fails: akmods Permission Error

On some build hosts, akmods may fail with permission issues. Workaround:

```dockerfile
RUN chmod 777 /var/tmp && \
    akmods --force --kernels ${KVER} && \
    chmod 755 /var/tmp
```

### nvidia-smi: "No devices found"

This is expected when running in a container without GPU passthrough. The drivers are installed correctly; `nvidia-smi` only works with actual GPU hardware.

## File Structure

```
nvidia-base/
├── Containerfile          # Main build definition
├── README.md              # This file
└── etc/
    └── modprobe.d/
        └── nvidia.conf    # Optional driver configuration
```

## References

- [NVIDIA Driver Installation Guide for RHEL](https://docs.nvidia.com/datacenter/tesla/driver-installation-guide/red-hat-enterprise-linux.html)
- [NVIDIA Open GPU Drivers Signed by Red Hat](https://developer.nvidia.com/blog/nvidia-open-gpu-datacenter-drivers-for-rhel9-signed-by-red-hat)
- [bootc Documentation](https://github.com/containers/bootc)
- [RHEL Image Mode Documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/using_image_mode_for_rhel_to_build_deploy_and_manage_operating_systems/)
