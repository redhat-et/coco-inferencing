# Build Instructions for Encrypted Model Downloader

## Environment Variables

Before starting, configure these key variables in the Makefile or override them:

```bash
REGISTRY=your-registry.com:5000          # Your container registry
MODEL=Qwen/Qwen3-0.5B                    # Model name (auto-converted to lowercase)
OCI_REGISTRY=quay.io                     # Registry hosting encrypted images  
ENCRYPTED_IMAGE=quay.io/user/model:encrypted  # Full encrypted model image name
```

## Quick Start (Complete Workflow)

```bash
# 1. Setup SSH access and build everything
make deploy-complete

# 2. Transfer your private key (in another terminal)
make transfer-key PRIVATE_KEY_PATH=/path/to/your/private.pem

# 3. Monitor the process
make pod-status
```

## Step-by-Step Instructions

### 1. Configuration

**Show current configuration:**
```bash
make show-config
```

**Configure for different scenarios:**
```bash
# For local kind cluster
make config-local

# For Quay.io registry  
make config-quay

# For custom registry and image
make config-custom CUSTOM_REGISTRY=your-registry.com CUSTOM_IMAGE=your-registry.com/model:encrypted
```

### 2. SSH Setup

```bash
make gen-ssh-key          # Generate SSH keypair if needed
make setup-ssh-access     # Add public key to authorized_keys
```

### 3. Container Build and Deployment

**Build and push the downloader container:**
```bash
make build-push-downloader
```

**Deploy the pod with auto-configuration:**
```bash
make deploy-encrypted-pod
```

### 4. Private Key Transfer

**Option A: Combined approach**
```bash
make transfer-and-wait PRIVATE_KEY_PATH=/path/to/your/private.pem
```

**Option B: Step by step**
```bash
# Terminal 1: Setup port forwarding
make setup-port-forward

# Terminal 2: Transfer the key  
make transfer-key PRIVATE_KEY_PATH=/path/to/your/private.pem

# Monitor progress
make wait-for-pod
```

## Required Environment Variables

The following variables must be set before deployment:

| Variable | Description | Example |
|----------|-------------|---------|
| `REGISTRY` | Your container registry | `localhost:5000` |
| `ENCRYPTED_IMAGE` | Full path to encrypted model image | `quay.io/user/model:encrypted` |
| `PRIVATE_KEY_PATH` | Path to your private key file | `/path/to/private.pem` |

**Override variables during make commands:**
```bash
make deploy-encrypted-pod REGISTRY=my-registry.com ENCRYPTED_IMAGE=my-registry.com/model:encrypted
```

## Monitoring and Management

**Check pod status and logs:**
```bash
make pod-status
```

**Individual monitoring commands:**
```bash
kubectl logs encrypted-model-inference -c model-downloader  # Init container logs
kubectl logs encrypted-model-inference -c vllm-server       # vLLM server logs
kubectl get pod encrypted-model-inference -o wide           # Pod status
```

**Cleanup:**
```bash
make delete-pod           # Delete the pod only
make stop-port-forward    # Stop SSH port forwarding
make clean               # Complete cleanup including kind cluster
```

## Prerequisites

Before deploying, ensure you have:

1. **Kubernetes cluster:** A running cluster (kind, minikube, or full cluster)
2. **Container registry access:** Push/pull access to your specified registry
3. **Private key file:** The decryption key for your encrypted model
4. **Encrypted model:** Pre-encrypted OCI model image in your registry

## Troubleshooting

**Container build fails:**
- Check Containerfile for package availability
- Try using standard skopeo: uncomment the fallback option in Containerfile

**Pod deployment fails:**
- Run `make validate-config` to check required variables
- Verify registry access and image existence

**SSH transfer fails:**
- Ensure port forwarding is running: `make setup-port-forward`
- Check SSH key setup: `make setup-ssh-access`