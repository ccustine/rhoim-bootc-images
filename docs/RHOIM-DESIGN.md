# RHOIM Design Document

**Red Hat OpenShift Inference Microservices**

Version: 1.0 (Draft)
Date: 2026-01-21

---

## 1. Executive Summary & Goals

**RHOIM (Red Hat OpenShift Inference Microservices)** is a production-ready inference platform that delivers GPU-accelerated LLM serving as a bootable, immutable operating system image. RHOIM packages vLLM (via RHAIIS) into a bootc-based appliance that works identically on bare metal, cloud VMs, and Kubernetes/OpenShift.

### Primary Goals

1. **Zero-configuration inference** - Boot the image, specify a model, serve an OpenAI-compatible API
2. **Deployment flexibility** - Same image runs on bare metal with systemd or as a container on OpenShift
3. **Enterprise-ready** - Built-in observability, API authentication, and secrets management
4. **Immutable infrastructure** - Updates via image replacement (`bootc switch`), not in-place patching
5. **Air-gap capable** - Support both runtime model download and pre-baked model images

### Non-Goals (Out of Scope)

- Multi-model routing or model orchestration (use OpenShift AI/KServe for that)
- Training or fine-tuning workloads
- Custom inference engines (RHOIM uses vLLM exclusively via RHAIIS)
- Non-NVIDIA GPUs in initial release (AMD ROCm is roadmap)

### Success Criteria

- Boot-to-serving in under 5 minutes (excluding model download)
- OpenAI API compatibility validated against common client libraries
- Prometheus metrics exposed for standard GPU inference dashboards

---

## 2. Architecture Overview

RHOIM uses a layered image architecture built on Red Hat's bootc technology. The same OCI image serves as both a bootable OS (for bare metal/VMs) and a container runtime (for Kubernetes).

### Image Hierarchy

```
┌─────────────────────────────────────────────────────┐
│  RHOIM Application Layer                            │
│  - Model configuration (ignition/K8s secrets)       │
│  - API authentication, observability                │
├─────────────────────────────────────────────────────┤
│  RHAIIS vLLM Runtime                                │
│  - vLLM inference engine                            │
│  - CUDA libraries, PyTorch                          │
│  - OpenAI-compatible API server                     │
├─────────────────────────────────────────────────────┤
│  nvidia-bootc-base                                  │
│  - NVIDIA drivers (pinned kernel modules)           │
│  - Container Toolkit + CDI configuration            │
│  - Ignition/Afterburn for first-boot provisioning   │
├─────────────────────────────────────────────────────┤
│  RHEL 9 bootc                                       │
│  - Immutable OS base                                │
│  - systemd, ostree, bootc tooling                   │
└─────────────────────────────────────────────────────┘
```

### Deployment Modes

| Mode | Base | Init System | Config Source | Use Case |
|------|------|-------------|---------------|----------|
| **Bare Metal/VM** | Bootable AMI/ISO | systemd | Ignition + Afterburn | Dedicated inference appliance |
| **Kubernetes** | Container image | Container entrypoint | K8s Secrets, ConfigMaps | Scalable cloud deployment |

### Key Architectural Decisions

- **Single image, dual purpose** - bootc images are valid OCI containers
- **Stateless compute** - Models downloaded or mounted, no persistent local state
- **Environment-aware secrets** - Detects runtime context (cloud VM vs K8s) and uses appropriate secrets mechanism

---

## 3. Functional Requirements

### 3.1 Model Serving

| Requirement | Description |
|-------------|-------------|
| **FR-1** | Expose OpenAI-compatible REST API (`/v1/chat/completions`, `/v1/completions`, `/v1/models`, `/v1/embeddings`) |
| **FR-2** | Support any model format that vLLM/RHAIIS accepts (HuggingFace, safetensors, etc.) |
| **FR-3** | Download models at runtime from HuggingFace Hub when `MODEL_ID` is specified |
| **FR-4** | Support pre-baked models embedded in custom images for air-gap deployments |
| **FR-5** | Configurable vLLM parameters via environment variables (`VLLM_EXTRA_ARGS`) |

### 3.2 Authentication & Authorization

| Requirement | Description |
|-------------|-------------|
| **FR-6** | API key validation for incoming requests (configurable key list) |
| **FR-7** | Support disabling auth for development/internal deployments |
| **FR-8** | Return standard HTTP 401/403 responses for auth failures |

### 3.3 Observability

| Requirement | Description |
|-------------|-------------|
| **FR-9** | Expose Prometheus metrics endpoint (`/metrics`) |
| **FR-10** | Include GPU utilization, memory usage, request latency, throughput metrics |
| **FR-11** | Health check endpoints (`/health`, `/ready`) for load balancer integration |
| **FR-12** | Structured JSON logging to stdout/journald |

### 3.4 Configuration

| Requirement | Description |
|-------------|-------------|
| **FR-13** | Primary config via environment variables (12-factor app style) |
| **FR-14** | Support Ignition/Afterburn for bare metal/VM provisioning |
| **FR-15** | Support Kubernetes Secrets and ConfigMaps for K8s deployments |

---

## 4. Non-Functional Requirements

### 4.1 Performance

| Requirement | Description |
|-------------|-------------|
| **NFR-1** | Boot-to-serving in under 5 minutes (excluding model download time) |
| **NFR-2** | Inference latency determined by vLLM/RHAIIS (no added overhead from RHOIM layer) |
| **NFR-3** | Support models up to available GPU VRAM (no artificial limits) |

### 4.2 Reliability

| Requirement | Description |
|-------------|-------------|
| **NFR-4** | Automatic service restart on failure (systemd `Restart=on-failure`) |
| **NFR-5** | Graceful shutdown on SIGTERM (drain in-flight requests) |
| **NFR-6** | Health checks report unhealthy when GPU unavailable or model failed to load |

### 4.3 Security

| Requirement | Description |
|-------------|-------------|
| **NFR-7** | No secrets stored in image layers (injected at runtime) |
| **NFR-8** | Run inference process as non-root user where possible |
| **NFR-9** | Support network isolation (no outbound required after model cached) |
| **NFR-10** | TLS termination expected at load balancer/ingress (not built-in) |

### 4.4 Compatibility

| Requirement | Description |
|-------------|-------------|
| **NFR-11** | NVIDIA GPUs with Compute Capability 7.0+ (Volta and newer) |
| **NFR-12** | RHEL 9.x kernel compatibility (pinned kernel for driver stability) |
| **NFR-13** | AMD ROCm support as future roadmap item |

### 4.5 Operability

| Requirement | Description |
|-------------|-------------|
| **NFR-14** | Updates via `bootc switch` to new image version |
| **NFR-15** | Rollback via `bootc rollback` to previous image |
| **NFR-16** | No manual intervention required for routine updates |

---

## 5. Configuration & Secrets Architecture

RHOIM uses a unified configuration model that adapts to the deployment environment. The image detects its runtime context and loads secrets from the appropriate source.

### Configuration Hierarchy

```
┌─────────────────────────────────────────────────────────────┐
│  Runtime Environment Variables (highest priority)          │
│  - Overrides all other sources                              │
├─────────────────────────────────────────────────────────────┤
│  Secrets (environment-specific)                             │
│  - Bare metal/VM: Ignition + Afterburn + cloud secrets mgr  │
│  - Kubernetes: Native Secrets, Vault                        │
├─────────────────────────────────────────────────────────────┤
│  Default Configuration (/etc/sysconfig/rhoim)              │
│  - Shipped in image, lowest priority                        │
└─────────────────────────────────────────────────────────────┘
```

### Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_ID` | `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | HuggingFace model repo or local path |
| `VLLM_HOST` | `0.0.0.0` | Listen address |
| `VLLM_PORT` | `8000` | Listen port |
| `VLLM_DEVICE_TYPE` | `cuda` | Accelerator type |
| `VLLM_EXTRA_ARGS` | (empty) | Additional vLLM CLI arguments |
| `API_KEYS` | (empty) | Comma-separated valid API keys |
| `HF_TOKEN` | (empty) | HuggingFace access token for gated models |
| `RHOIM_OFFLINE` | `false` | Disable model downloads (require local model) |

### Secrets Flow by Environment

**Bare Metal / Cloud VM:**
1. Ignition provisions systemd units and base config at first boot
2. Afterburn injects cloud metadata (SSH keys, instance identity)
3. `fetch-hf-token.service` retrieves `HF_TOKEN` from AWS Secrets Manager (or equivalent)
4. `rhoim-vllm.service` starts after secrets are populated

**Kubernetes:**
1. Secrets mounted as environment variables or files via Pod spec
2. Optional: External Secrets Operator syncs from Vault/cloud secrets
3. Container entrypoint reads config and starts vLLM directly

---

## 6. Deployment Flows

### 6.1 Bare Metal / Cloud VM Deployment

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Build AMI   │───▶│  Boot VM     │───▶│  Ignition    │───▶│  Serving     │
│  from bootc  │    │  with image  │    │  configures  │    │  requests    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

**Steps:**
1. Build bootc image with RHOIM layers
2. Convert to cloud-specific format (AMI, qcow2, ISO)
3. Launch instance with Ignition config as user-data
4. First boot: Ignition creates users, services, firewall rules
5. Afterburn fetches SSH keys from cloud metadata
6. `fetch-hf-token.service` retrieves secrets from cloud secrets manager
7. `rhoim-vllm.service` downloads model (if needed) and starts serving

**Updates:**
```bash
sudo bootc switch quay.io/redhat/rhoim:v2.0
sudo reboot
```

### 6.2 Kubernetes / OpenShift Deployment

```
┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│  Push image  │───▶│  Deploy Pod  │───▶│  Mount       │───▶│  Serving     │
│  to registry │    │  with GPU    │    │  secrets     │    │  requests    │
└──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

**Steps:**
1. Push RHOIM container image to registry
2. Create Secret with `HF_TOKEN`, `API_KEYS`
3. Create ConfigMap with model configuration
4. Deploy Pod/Deployment with GPU resource requests
5. Container starts, loads config from environment, serves API

**Scaling:**
- Horizontal Pod Autoscaler based on request queue depth or GPU utilization
- Each replica serves the same model independently
- Load balancer distributes requests across replicas

---

## 7. API Specification

RHOIM exposes a vLLM-powered API that is compatible with the OpenAI API specification, plus operational endpoints for health and metrics.

### 7.1 Inference Endpoints (OpenAI-Compatible)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | POST | Chat-style completions (recommended) |
| `/v1/completions` | POST | Text completions (legacy) |
| `/v1/models` | GET | List available models |
| `/v1/embeddings` | POST | Generate embeddings (if model supports) |

**Authentication:** Include `Authorization: Bearer <API_KEY>` header when `API_KEYS` is configured.

**Example Request:**
```bash
curl -X POST http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer devkey1" \
  -d '{
    "model": "TinyLlama/TinyLlama-1.1B-Chat-v1.0",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

### 7.2 Operational Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/health` | GET | Liveness probe (returns 200 if process running) |
| `/ready` | GET | Readiness probe (returns 200 if model loaded, GPU available) |
| `/metrics` | GET | Prometheus-format metrics |

### 7.3 Key Metrics Exposed

| Metric | Type | Description |
|--------|------|-------------|
| `vllm_requests_total` | Counter | Total inference requests |
| `vllm_request_duration_seconds` | Histogram | Request latency distribution |
| `vllm_tokens_generated_total` | Counter | Total tokens generated |
| `vllm_gpu_memory_usage_bytes` | Gauge | GPU memory consumption |
| `vllm_model_loaded` | Gauge | 1 if model loaded successfully |

---

## 8. Image Variants

RHOIM provides multiple image variants to address different deployment scenarios.

### 8.1 Available Images

| Image | Base | Use Case |
|-------|------|----------|
| `rhoim:latest` | RHAIIS vLLM | Standard deployment, runtime model download |
| `rhoim:<model-name>` | RHAIIS vLLM + embedded model | Air-gap deployment, no download required |

### 8.2 Standard Image (Runtime Download)

**Characteristics:**
- Smaller image size (~15-20GB)
- Model downloaded on first boot
- Requires network access to HuggingFace (or mirror)
- Flexible: change model via config without rebuilding

**Best for:**
- Development and testing
- Cloud deployments with good network
- Environments where models change frequently

### 8.3 Pre-baked Model Image (Air-Gap)

**Characteristics:**
- Larger image size (model embedded, can be 50GB+)
- No network required after image pull
- Model guaranteed to match tested version
- Rebuild required to change model

**Build process:**
```dockerfile
FROM quay.io/redhat/rhoim:latest
RUN huggingface-cli download meta-llama/Llama-3-8B \
    --local-dir /opt/rhoim/models/meta-llama/Llama-3-8B
ENV MODEL_ID=/opt/rhoim/models/meta-llama/Llama-3-8B
ENV RHOIM_OFFLINE=true
```

**Best for:**
- Air-gapped environments
- Regulated industries requiring known-good artifacts
- Edge deployments with limited bandwidth

---

## 9. Roadmap & Future Considerations

### 9.1 Current Release Scope (v1.0)

- NVIDIA GPU support (Compute Capability 7.0+)
- Single model per instance
- OpenAI-compatible API via vLLM
- Prometheus metrics and health endpoints
- API key authentication
- Ignition/Afterburn for bare metal, K8s Secrets for Kubernetes
- Runtime model download and pre-baked image support

### 9.2 Future Roadmap

| Priority | Feature | Description |
|----------|---------|-------------|
| **High** | AMD ROCm support | Alternative GPU vendor for cost/availability flexibility |
| **High** | Helm charts | Official charts for OpenShift/Kubernetes deployment |
| **Medium** | OpenTelemetry tracing | Distributed tracing for request debugging |
| **Medium** | Model caching layer | Shared model cache across instances (S3, PVC) |
| **Medium** | Automatic GPU detection | Select optimal dtype/config based on detected GPU |
| **Low** | Multi-model serving | Serve multiple models from one instance |
| **Low** | Request queuing | Built-in queue with backpressure for burst handling |

### 9.3 Integration Points (Not Owned by RHOIM)

These capabilities are expected to be provided by the deployment platform:

- **TLS termination** - Ingress controller, load balancer
- **Autoscaling** - Kubernetes HPA, cloud autoscaling groups
- **Model orchestration** - OpenShift AI, KServe
- **Log aggregation** - OpenShift Logging, CloudWatch, Splunk
- **Secret rotation** - External Secrets Operator, Vault

---

## 10. Testing & Validation

### 10.1 Build-Time Validation

| Check | Description |
|-------|-------------|
| `bootc container lint` | Verify image meets bootc requirements |
| vLLM import test | Confirm vLLM and PyTorch load correctly |
| GPU library presence | Verify CUDA libraries are accessible |

### 10.2 Runtime Validation

| Test | Command | Expected Result |
|------|---------|-----------------|
| GPU detection | `nvidia-smi` | Lists available GPUs |
| Model loading | `curl /v1/models` | Returns model list |
| Health check | `curl /health` | Returns 200 OK |
| Readiness check | `curl /ready` | Returns 200 when model loaded |
| Inference | `curl /v1/chat/completions` | Returns generated text |
| Metrics | `curl /metrics` | Returns Prometheus format |

### 10.3 Integration Test Matrix

| Environment | GPU | Config Source | Model Source |
|-------------|-----|---------------|--------------|
| AWS EC2 g4dn | NVIDIA T4 | Ignition + Secrets Manager | HuggingFace download |
| Bare metal | NVIDIA A100 | Ignition + static secrets | Pre-baked image |
| OpenShift | NVIDIA GPU Operator | K8s Secrets | HuggingFace download |
| Local (Podman) | Host GPU passthrough | Environment variables | Local cache |

### 10.4 Performance Benchmarks

Baseline metrics to track across releases:
- Time from boot to first successful inference
- Tokens per second at various batch sizes
- GPU memory utilization vs model size
- Request latency percentiles (p50, p95, p99)

---

## Appendix A: Glossary

| Term | Definition |
|------|------------|
| **bootc** | Red Hat technology for bootable OCI containers |
| **RHAIIS** | Red Hat AI Infrastructure Services (provides vLLM runtime) |
| **vLLM** | High-performance LLM inference engine |
| **Ignition** | First-boot provisioning system for Fedora/RHEL CoreOS |
| **Afterburn** | Cloud metadata agent for Ignition-based systems |
| **CDI** | Container Device Interface (GPU passthrough standard) |
| **HPA** | Horizontal Pod Autoscaler (Kubernetes) |

---

## Appendix B: Related Documents

- `docs/runbooks/RUNBOOK-BUILD-IMAGE.md` - Image build procedures
- `docs/runbooks/RUNBOOK-CREATE-AMI.md` - AMI creation from bootc
- `docs/runbooks/RUNBOOK-INFRA.md` - Infrastructure provisioning
- `nvidia-bootc-base/ignition/` - Butane configuration files
