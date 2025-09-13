# Complete Demo: Encrypted Model Inference in TEE

This guide walks through the complete workflow from model download to encrypted inference using a local Kind cluster.

## Complete Demo Workflow

Execute these commands in order for the full end-to-end demo:

### 1. Setup Kind Cluster with Local Registry
```bash
# Start kind cluster with integrated registry
make kind

# Configure for local registry
make config-local
```

### 2. Download and Build Model
```bash
# Download model from Hugging Face
make fetch

# Build OCI artifact with modctl (local staging)
make oci

# Show current configuration
make show-config
```

### 3. Generate Encryption Keys
```bash
# Generate RSA keypair for model encryption
make gen-keys

# Generate SSH keypair for secure key transfer
make gen-ssh-key

# Setup SSH access for container
make setup-ssh-access
```

### 4. Encrypt and Push Model
```bash
# Encrypt the staged model and push to local registry
make encrypt
```

### 5. Build and Deploy Infrastructure
```bash
# Build the model downloader container
make build-push-downloader

# Deploy the pod with init container and vLLM app container
make deploy-encrypted-pod
```

### 6. Secure Key Transfer and Model Loading
```bash
# In Terminal 1: Setup port forwarding for SSH access
make setup-port-forward

# In Terminal 2: Transfer the private key to trigger model download
make transfer-key PRIVATE_KEY_PATH=./private.pem

# Monitor the entire process
make pod-status
```

### 7. Verify Inference Server
```bash
# Wait for vLLM server to be ready
make wait-for-pod

# Check that inference server is running
kubectl port-forward encrypted-model-inference 8000:8000 &

# Test inference endpoint (in another terminal)
curl -X POST "http://localhost:8000/v1/completions" \
  -H "Content-Type: application/json" \
  -d '{"model": "encrypted-model", "prompt": "Hello", "max_tokens": 50}'
```

### 8. Cleanup
```bash
# Stop port forwarding
make stop-port-forward

# Clean up everything including kind cluster
make clean
```

## What Happens During the Demo

### Security Architecture
- **TEE Environment**: The pod runs in a Trusted Execution Environment where memory is encrypted
- **Ramdisk Storage**: All decrypted content exists only in encrypted ramdisk memory (`/shared/ramdisk`)
- **Standard Init Container**: The downloader container itself is not encrypted - security comes from the TEE environment
- **No Disk Persistence**: Decrypted model never touches unencrypted storage outside the TEE ramdisk
- **Secure Key Transfer**: Private key transferred via SSH to trigger decryption within TEE memory

### Workflow Details
1. **Model Preparation**: HuggingFace model → modctl OCI artifact → encrypted with RSA key
2. **Container Setup**: Standard init container with skopeo + SSH server for secure key transfer
3. **Pod Deployment**: Init container waits for private key, app container waits for model
4. **Secure Transfer**: Private key transferred via SSH to trigger decryption within TEE ramdisk
5. **Model Loading**: Init container decrypts directly to TEE ramdisk, extracts layers, cleans up
6. **Inference Ready**: vLLM server starts with model from TEE encrypted ramdisk

### Expected Output
During the demo, you'll see:
- Model download and OCI artifact creation
- Encryption and registry push
- Pod deployment with init container waiting
- SSH key transfer triggering model decryption
- Layer extraction within encrypted memory
- vLLM server startup with encrypted model

## Prerequisites

- Docker/Podman with kind
- kubectl configured
- Go toolchain (for skopeo build)
- curl (for testing inference)

## Troubleshooting

**Kind cluster issues:**
```bash
kind delete cluster --name coco  # Reset cluster
make kind                        # Recreate
```

**Container build fails:**
```bash
# Check Containerfile logs for missing packages
# Try fallback skopeo option if custom build fails
```

**Pod stuck in init:**
```bash
make pod-status                  # Check init container logs
make setup-port-forward          # Ensure SSH access
```

**Inference not responding:**
```bash
kubectl logs encrypted-model-inference -c vllm-server  # Check vLLM logs
kubectl get pod encrypted-model-inference              # Verify pod status
```