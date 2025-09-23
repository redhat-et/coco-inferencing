# KBS Attestation Demo Guide

This guide demonstrates the Key Broker Service (KBS) integration with configurable attestation policies for encrypted model inference.

## Overview

The KBS demo replaces the manual `kubectl cp` method with automatic attestation-based key retrieval. The setup includes:

- **KBS (Key Broker Service)**: Manages encrypted secrets
- **Mock Attestation Service**: Simulates TEE attestation with configurable allow/deny policies
- **Enhanced Init Container**: Uses KBS client instead of waiting for manual key transfer

## Demo Scenarios

### Scenario 1: Successful Attestation (ALLOW)
```bash
# Set policy to allow access
make kbs-policy-allow

# Deploy pod - will succeed in getting the key
make deploy-encrypted-pod
```

### Scenario 2: Failed Attestation (DENY) 
```bash
# Set policy to deny access
make kbs-policy-deny

# Deploy pod - will fail to get the key
make deploy-encrypted-pod
```

## Complete Demo Workflow

### 1. Setup Infrastructure
```bash
# Start kind cluster and registry
make kind

# Deploy KBS infrastructure
make deploy-kbs

# Populate KBS with private key
make populate-kbs-secrets

# Build and push updated downloader container
make build-push-downloader
```

### 2. Demo: Successful Access
```bash
# Configure policy to allow access
make kbs-policy-allow

# Deploy the inference pod (for Kind cluster)
make deploy-encrypted-pod-kind

# Monitor the logs - should see successful attestation
kubectl logs encrypted-model-inference -c model-downloader -f

# Expected output:
# 🔐 KBS-based Private Key Retrieval
# ✅ Services are ready!
# 🔍 Requesting attestation...
# ✅ Attestation successful!
# 🔑 Requesting secret: private.key
# ✅ Secret retrieved successfully!
# ✅ Private key saved to /shared/keys/private.key
```

### 3. Demo: Access Denied
```bash
# Delete previous pod
kubectl delete pod encrypted-model-inference

# Configure policy to deny access
make kbs-policy-deny

# Deploy the inference pod again (for Kind cluster)
make deploy-encrypted-pod-kind

# Monitor the logs - should see failed attestation
kubectl logs encrypted-model-inference -c model-downloader -f

# Expected output:
# 🔐 KBS-based Private Key Retrieval
# ✅ Services are ready!
# 🔍 Requesting attestation...
# ❌ Attestation failed!
#    Reason: Invalid TEE measurement
# 💥 Key retrieval failed!
```

### 4. Policy Management
```bash
# Check current policy
make kbs-status

# Switch between policies
make kbs-policy-allow   # Enable access
make kbs-policy-deny    # Disable access

# View attestation service logs
kubectl logs deployment/mock-attestation-service
```

## Key Components

### Mock Attestation Service
- **Policy Configuration**: JSON-based policy switching
- **Simulation**: Generates realistic TEE evidence
- **Logging**: Clear allow/deny decisions with reasons

### KBS Client (Python)
- **Attestation Flow**: Simulates TEE evidence generation
- **Secret Retrieval**: Retrieves private key from KBS
- **Error Handling**: Clear failure messages for debugging

### Enhanced Init Container
- **Automatic Retrieval**: No manual key transfer needed
- **Attestation Integration**: Uses KBS client for key access
- **Fallback Logging**: Detailed error reporting

## Customization for Vendor Integration

The mock attestation service can be easily replaced with a real vendor solution:

1. **Replace Mock AS**: Update `mock-attestation-service.yaml` with real AS endpoint
2. **Update Evidence Generation**: Modify `kbs-client.py` to use real TEE evidence
3. **Configure Policies**: Update KBS policies for production requirements

## Troubleshooting

```bash
# Check all components
make kbs-status

# View logs
kubectl logs deployment/kbs
kubectl logs deployment/mock-attestation-service
kubectl logs encrypted-model-inference -c model-downloader

# Reset demo
make delete-kbs
make deploy-kbs
make populate-kbs-secrets
```

## Security Notes

- **Demo Mode**: Current setup uses simulated attestation for demonstration
- **Policy Flexibility**: Easy switching between allow/deny for storyline demos
- **Vendor Ready**: Architecture supports replacing mock components with real attestation
- **TEE Simulation**: Generates realistic evidence structure for testing