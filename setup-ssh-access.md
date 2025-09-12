# SSH Access Setup for Private Key Transfer

## Prerequisites

1. **Generate SSH key pair** (if you don't have one):
   ```bash
   ssh-keygen -t rsa -b 4096 -C "your-email@example.com"
   ```

2. **Add your public key** to the `authorized_keys` file:
   ```bash
   cat ~/.ssh/id_rsa.pub >> authorized_keys
   ```

3. **Build and deploy** the container with SSH support:
   ```bash
   podman build -t your-registry/encrypted-model-downloader:latest .
   podman push your-registry/encrypted-model-downloader:latest
   kubectl apply -f encrypted-model-pod.yaml
   ```

## Transferring the Private Key

### Method 1: Using kubectl port-forward (Recommended for kind clusters)

1. **Set up port forwarding**:
   ```bash
   kubectl port-forward encrypted-model-inference 2222:22
   ```

2. **Transfer the private key**:
   ```bash
   scp -P 2222 your-private-key.pem root@localhost:/shared/keys/private.key
   ```

### Method 2: Direct pod IP access (if network allows)

1. **Get the pod IP**:
   ```bash
   kubectl get pod encrypted-model-inference -o jsonpath='{.status.podIP}'
   ```

2. **Transfer the private key**:
   ```bash
   scp your-private-key.pem root@<POD_IP>:/shared/keys/private.key
   ```

## Monitoring the Process

1. **Watch init container logs**:
   ```bash
   kubectl logs -f encrypted-model-inference -c model-downloader
   ```

2. **Check SSH daemon status**:
   The logs will show when SSH daemon starts and provide connection instructions.

3. **Verify key transfer**:
   Once you transfer the key, the init container will proceed with model download.

## Security Notes

- SSH access is only available during the init container phase
- The SSH daemon is automatically stopped after model download completes
- Use strong SSH keys and limit access to authorized users only
- Consider using kubectl exec instead of SSH for debugging if needed