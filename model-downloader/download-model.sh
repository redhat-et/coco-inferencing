#!/bin/bash
set -euo pipefail

echo "Starting encrypted model download process..."

# Environment variables with defaults
PRIVATE_KEY_FILE="${PRIVATE_KEY_FILE:-/shared/keys/private.key}"
OCI_REGISTRY="${OCI_REGISTRY:-quay.io}"
MODEL_NAME="${MODEL_NAME:-qwen/qwen3-0.6b}"
MODEL_DIR="${MODEL_DIR:-/shared/ramdisk}"
USE_TLS="${USE_TLS:-false}"
DECRYPTED_DIR="${MODEL_DIR}/decrypted"

# Construct encrypted image name from registry and model name
ENCRYPTED_IMAGE="${OCI_REGISTRY}/${MODEL_NAME}:encrypted"

echo "Configuration:"
echo "  Private key file: $PRIVATE_KEY_FILE"
echo "  OCI registry: $OCI_REGISTRY"
echo "  Encrypted image: $ENCRYPTED_IMAGE"
echo "  Model directory (ramdisk): $MODEL_DIR"
echo "  Decrypted OCI directory: $DECRYPTED_DIR"
echo "  Use TLS: $USE_TLS"

# Create necessary directories in ramdisk (TEE encrypted memory)
mkdir -p "$MODEL_DIR"
mkdir -p "$DECRYPTED_DIR"
mkdir -p "$(dirname "$PRIVATE_KEY_FILE")"

# Start SSH daemon for SCP access
echo "Starting SSH daemon for private key transfer..."
/usr/sbin/sshd -D &
SSH_PID=$!

# Get pod IP for SCP instructions
POD_IP=$(hostname -I | awk '{print $1}')
echo "SSH server started. You can now SCP the private key file:"
echo "  scp your-private-key.pem root@${POD_IP}:${PRIVATE_KEY_FILE}"
echo "  (Use kubectl port-forward if needed: kubectl port-forward encrypted-model-inference 2222:22)"

# Step 1: Retrieve private key via KBS attestation
echo "Step 1: Retrieving private key via KBS attestation..."
python3 /usr/local/bin/kbs-client.py

if [ ! -f "$PRIVATE_KEY_FILE" ]; then
    echo "ERROR: KBS key retrieval failed - private key not found at $PRIVATE_KEY_FILE"
    echo "This could be due to:"
    echo "  - Attestation policy denial"
    echo "  - KBS service unavailable"
    echo "  - Invalid TEE evidence"
    exit 1
fi

echo "✅ Private key successfully retrieved via KBS attestation: $PRIVATE_KEY_FILE"

# Verify key file permissions
chmod 400 "$PRIVATE_KEY_FILE"

# Step 2: Pull and decrypt the OCI image directly to ramdisk (TEE encrypted memory)
echo "Step 2: Pulling and decrypting OCI image directly to ramdisk..."
echo "Pulling encrypted image: $ENCRYPTED_IMAGE"
echo "Target directory (in TEE encrypted memory): $DECRYPTED_DIR"

# Use custom skopeo to pull and decrypt the image directly to ramdisk
# This ensures the decrypted content only exists in TEE encrypted memory

# Configure TLS verification based on USE_TLS setting
if [ "$USE_TLS" = "true" ]; then
    TLS_FLAGS=""
    echo "Using TLS verification for registry connection"
else
    TLS_FLAGS="--src-tls-verify=false"
    echo "Disabling TLS verification for registry connection"
fi

skopeo copy \
    --decryption-key "$PRIVATE_KEY_FILE" \
    $TLS_FLAGS \
    "docker://$ENCRYPTED_IMAGE" \
    "dir:$DECRYPTED_DIR"

echo "Image successfully pulled and decrypted to ramdisk: $DECRYPTED_DIR"

# Step 3: Unpack the OCI image layers within ramdisk (TEE encrypted memory)
echo "Step 3: Unpacking OCI image layers within ramdisk..."

# Check if manifest.json exists in ramdisk
if [ ! -f "$DECRYPTED_DIR/manifest.json" ]; then
    echo "Error: manifest.json not found in $DECRYPTED_DIR"
    exit 1
fi

echo "Found manifest.json in ramdisk, extracting layers..."

# Create final model directory within ramdisk
FINAL_MODEL_DIR="$MODEL_DIR/model"
mkdir -p "$FINAL_MODEL_DIR"

# Extract each layer from the manifest directly within ramdisk
for layer in $(jq -r '.layers[] | .digest' "$DECRYPTED_DIR/manifest.json"); do
    layer_file="${layer:7}"  # Remove 'sha256:' prefix
    layer_path="$DECRYPTED_DIR/$layer_file"
    
    echo "Extracting layer: $layer_file (within TEE encrypted memory)"
    
    if [ -f "$layer_path" ]; then
        tar xf "$layer_path" -C "$FINAL_MODEL_DIR"
    else
        echo "Warning: Layer file not found: $layer_path"
    fi
done

echo "Step 4: Model extraction completed within TEE encrypted memory"
echo "Model is now available in: $FINAL_MODEL_DIR"

# List contents for verification
echo "Final model directory contents:"
ls -la "$FINAL_MODEL_DIR"

# Clean up decrypted OCI artifacts to save ramdisk space
echo "Cleaning up decrypted OCI artifacts to save ramdisk space..."
rm -rf "$DECRYPTED_DIR"

echo "Ramdisk usage after cleanup:"
df -h "$MODEL_DIR"

echo "=== ENCRYPTED MODEL VERIFICATION COMPLETE ==="
echo "Model successfully decrypted and extracted to TEE ramdisk!"

# Stop SSH daemon
echo "Stopping SSH daemon..."
kill $SSH_PID 2>/dev/null || true

echo "Init container completed successfully!"
