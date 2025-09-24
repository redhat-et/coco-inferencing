REGISTRY=localhost:5001
MODEL=Qwen/Qwen3-0.6B
MODEL_LC=$(shell echo $(MODEL) | tr '[:upper:]' '[:lower:]')
MODCTL=modctl
SKOPEO=skopeo
SKOPEO_IMAGE?=quay.io/ifont/skopeo:dev
USE_SKOPEO_CONTAINER?=true
HF=hf
CACHEDIR=.modctl

# TLS configuration
USE_TLS?=false
SKOPEO_TLS_FLAGS=$(if $(filter true,$(USE_TLS)),,--dest-tls-verify=false --src-tls-verify=false)
PODMAN_TLS_FLAGS=$(if $(filter true,$(USE_TLS)),,--tls-verify=false)

# Skopeo command configuration
SKOPEO_CMD=$(if $(filter true,$(USE_SKOPEO_CONTAINER)),podman run --rm --net=host -v $(PWD):/workspace:Z -v $(PWD)/policy.json:/etc/containers/policy.json:Z -w /workspace $(SKOPEO_IMAGE),$(SKOPEO))

# Pod configuration variables
OCI_REGISTRY=$(REGISTRY)
MODEL_NAME=$(MODEL_LC)
ENCRYPTED_IMAGE=$(REGISTRY)/$(MODEL_LC):encrypted
DOWNLOADER_IMAGE=$(REGISTRY)/encrypted-model-downloader:latest

export

fetch:	## Fetch image from Huggingface
	$(HF) download $(MODEL) --local-dir model

oci:	## Build OCI artifact for model
	$(MODCTL) modelfile generate model
	$(MODCTL) build --storage-dir $(CACHEDIR) -t localhost/$(MODEL_LC):latest -f Modelfile model
	./modctl-to-oci.sh localhost/$(MODEL_LC) latest $(CACHEDIR) staging

gen-keys:	## Generate crypto keypair
	openssl genpkey -algorithm RSA -out private.pem -pkeyopt rsa_keygen_bits:4096
	openssl rsa -pubout -in private.pem -out public.pem

gen-ssh-key:	## Generate SSH keypair for container access
	@if [ ! -f ~/.ssh/id_rsa ]; then \
		echo "Generating SSH keypair..."; \
		ssh-keygen -t rsa -b 4096 -C "coco-inferencing@$(shell hostname)" -f ~/.ssh/id_rsa -N ""; \
	else \
		echo "SSH keypair already exists at ~/.ssh/id_rsa"; \
	fi

setup-ssh-access:	## Setup SSH access by adding public key to authorized_keys
	@echo "Adding SSH public key to ./model-downloader/authorized_keys..."
	@if [ -f ~/.ssh/id_rsa.pub ]; then \
		cp ~/.ssh/id_rsa.pub ./model-downloader/authorized_keys; \
		echo "SSH public key added to ./model-downloader/authorized_keys"; \
	else \
		echo "SSH public key not found. Run 'make gen-ssh-key' first."; \
		exit 1; \
	fi

encrypt:	## Encrypt the model (registry -> registry)
	$(SKOPEO_CMD) copy --encryption-key jwe:public.pem $(SKOPEO_TLS_FLAGS) \
		dir:staging \
		docker://$(REGISTRY)/$(MODEL_LC):encrypted

decrypt:	## Decrypt the modek (registry -> registry)
	$(SKOPEO_CMD) copy --decryption-key private.pem $(SKOPEO_TLS_FLAGS) \
		docker://$(REGISTRY)/$(MODEL_LC):encrypted \
		dir:decrypted

pull:	## Pull and extract model from registry
	$(MODCTL) pull --extract-dir ramdisk --extract-from-remote --plain-http \
		$(REGISTRY)/$(MODEL_LC):decrypted

kind:	## Start a kind cluster with local registry
	envsubst < kind-config.yaml.tmpl > kind-config.yaml
	CLUSTER_NAME=coco CONFIG_FILE=kind-config.yaml ./kind-with-registry.sh

build-downloader:	## Build the encrypted model downloader container
	podman build -t $(REGISTRY)/encrypted-model-downloader:latest model-downloader

push-downloader:	## Push the encrypted model downloader container
	podman push $(PODMAN_TLS_FLAGS) $(REGISTRY)/encrypted-model-downloader:latest

build-push-downloader: build-downloader push-downloader	## Build and push the encrypted model downloader container

validate-config:	## Validate required configuration variables
	@echo "Validating configuration..."
	@if [ -z "$(REGISTRY)" ]; then echo "Error: REGISTRY not set"; exit 1; fi
	@if [ -z "$(MODEL_NAME)" ]; then echo "Error: MODEL_NAME not set"; exit 1; fi
	@if [ -z "$(DOWNLOADER_IMAGE)" ]; then echo "Error: DOWNLOADER_IMAGE not set"; exit 1; fi
	@if [ -z "$(OCI_REGISTRY)" ]; then echo "Error: OCI_REGISTRY not set"; exit 1; fi
	@echo "Configuration validation passed"

update-pod-config: validate-config	## Update pod YAML with current environment variables
	@echo "Updating pod YAML configuration..."
	@sed -e 's|localhost:5001/encrypted-model-downloader:latest|$(DOWNLOADER_IMAGE)|g' \
	     -e 's|value: "localhost:5001"|value: "$(OCI_REGISTRY)"|g' \
	     -e 's|value: "qwen/qwen3-0.6b"|value: "$(MODEL_NAME)"|g' \
	     -e '/name: USE_TLS/{n;s|value: "false"|value: "$(USE_TLS)"|;}' \
	     encrypted-model-pod.yaml > encrypted-model-pod.yaml.tmp
	@mv encrypted-model-pod.yaml.tmp encrypted-model-pod.yaml
	@echo "Pod YAML updated with:"
	@echo "  Downloader image: $(DOWNLOADER_IMAGE)"
	@echo "  OCI registry: $(OCI_REGISTRY)"
	@echo "  Model name: $(MODEL_NAME)"
	@echo "  Use TLS: $(USE_TLS)"

deploy-encrypted-pod: 	## Deploy the encrypted model inference pod (use REGISTRY and OCI_REGISTRY vars for kind)
	@echo "Deploying encrypted model inference pod..."
	@echo "Using REGISTRY=$(REGISTRY) for init container image"
	@echo "Using OCI_REGISTRY=$(OCI_REGISTRY) for internal model registry"
	@$(MAKE) update-pod-config REGISTRY=$(REGISTRY) OCI_REGISTRY=$(OCI_REGISTRY)
	@kubectl apply -f encrypted-model-pod.yaml

deploy-encrypted-pod-kind:	## Deploy pod configured for Kind cluster (sets correct registries)
	@echo "Deploying encrypted model inference pod for Kind cluster..."
	@$(MAKE) deploy-encrypted-pod REGISTRY=localhost:5001 OCI_REGISTRY=kind-registry:5000

delete-pod:	## Delete the encrypted model inference pod
	kubectl delete pod encrypted-model-inference --ignore-not-found=true

wait-for-pod:	## Wait for pod to be running
	@echo "Waiting for pod to be ready..."
	@kubectl wait --for=condition=Ready pod/encrypted-model-inference --timeout=600s || \
	(echo "Pod failed to become ready. Checking logs..." && kubectl logs encrypted-model-inference -c model-downloader)

pod-status:	## Show pod status and logs
	@echo "=== Pod Status ==="
	@kubectl get pod encrypted-model-inference -o wide || echo "Pod not found"
	@echo ""
	@echo "=== Init Container Logs ==="
	@kubectl logs encrypted-model-inference -c model-downloader --tail=20 || echo "No logs available"

setup-port-forward:	## Setup port forwarding for SSH access
	@echo "Setting up port forwarding for SSH access..."
	@echo "Access will be available on localhost:2222"
	@kubectl port-forward encrypted-model-inference 2222:22 &
	@echo "Port forwarding started in background. PID: $$!"
	@echo "To stop: kill $$!"

transfer-key:	## Transfer private key via kubectl cp (requires PRIVATE_KEY_PATH variable)
	@if [ -z "$(PRIVATE_KEY_PATH)" ]; then \
		echo "Error: Please specify PRIVATE_KEY_PATH variable"; \
		echo "Usage: make transfer-key PRIVATE_KEY_PATH=/path/to/your/private.pem"; \
		exit 1; \
	fi
	@echo "Transferring private key: $(PRIVATE_KEY_PATH)"
	@kubectl cp "$(PRIVATE_KEY_PATH)" encrypted-model-inference:/shared/keys/private.key -c model-downloader
	@echo "Private key transferred successfully!"

stop-port-forward:	## Stop port forwarding processes
	@echo "Stopping port forwarding processes..."
	@pkill -f "kubectl port-forward encrypted-model-inference" || echo "No port forwarding processes found"

run:	## Run the inferencing pod
	envsubst < inference-pod.yaml | kubectl apply -f -

# Configuration targets for different scenarios
config-local:	## Configure for local registry (kind cluster)
	$(eval REGISTRY=$(REGISTRY))
	$(eval OCI_REGISTRY=$(OCI_REGISTRY))
	$(eval MODEL_NAME=$(MODEL_LC))
	$(eval ENCRYPTED_IMAGE=$(ENCRYPTED_IMAGE))
	$(eval DOWNLOADER_IMAGE=$(DOWNLOADER_IMAGE))
	@echo "Configuration set for local registry:"
	@echo "  REGISTRY: $(REGISTRY)"
	@echo "  OCI_REGISTRY: $(OCI_REGISTRY)"
	@echo "  MODEL_NAME: $(MODEL_NAME)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"
	@echo "  DOWNLOADER_IMAGE: $(DOWNLOADER_IMAGE)"

config-quay:	## Configure for Quay.io registry
	$(eval OCI_REGISTRY=quay.io)
	$(eval ENCRYPTED_IMAGE=quay.io/$(shell echo $(USER))/$(MODEL_LC):encrypted)
	@echo "Configuration set for Quay.io registry:"
	@echo "  OCI_REGISTRY: $(OCI_REGISTRY)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"

config-custom:	## Configure with custom variables (use CUSTOM_REGISTRY, CUSTOM_IMAGE)
	@if [ -z "$(CUSTOM_REGISTRY)" ]; then \
		echo "Error: Please specify CUSTOM_REGISTRY variable"; \
		echo "Usage: make config-custom CUSTOM_REGISTRY=your-registry.com CUSTOM_IMAGE=your-image:tag"; \
		exit 1; \
	fi
	@if [ -z "$(CUSTOM_IMAGE)" ]; then \
		echo "Error: Please specify CUSTOM_IMAGE variable"; \
		echo "Usage: make config-custom CUSTOM_REGISTRY=your-registry.com CUSTOM_IMAGE=your-image:tag"; \
		exit 1; \
	fi
	$(eval OCI_REGISTRY=$(CUSTOM_REGISTRY))
	$(eval ENCRYPTED_IMAGE=$(CUSTOM_IMAGE))
	@echo "Configuration set for custom registry:"
	@echo "  OCI_REGISTRY: $(OCI_REGISTRY)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"

show-config:	## Show current configuration
	@echo "Current configuration:"
	@echo "  REGISTRY: $(REGISTRY)"
	@echo "  MODEL: $(MODEL)"
	@echo "  MODEL_LC: $(MODEL_LC)"
	@echo "  MODEL_NAME: $(MODEL_NAME)"
	@echo "  USE_TLS: $(USE_TLS)"
	@echo "  OCI_REGISTRY: $(OCI_REGISTRY)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"
	@echo "  DOWNLOADER_IMAGE: $(DOWNLOADER_IMAGE)"
	@echo ""
	@echo "Skopeo Configuration:"
	@echo "  USE_SKOPEO_CONTAINER: $(USE_SKOPEO_CONTAINER)"
	@echo "  SKOPEO_IMAGE: $(SKOPEO_IMAGE)"
	@echo "  SKOPEO_CMD: $(SKOPEO_CMD)"
	@echo ""
	@echo "TLS Configuration:"
	@echo "  To enable TLS: make <target> USE_TLS=true"
	@echo "  To disable TLS: make <target> USE_TLS=false (default)"
	@echo ""
	@echo "Skopeo Usage:"
	@echo "  Use container: make <target> USE_SKOPEO_CONTAINER=true (default)"
	@echo "  Use local binary: make <target> USE_SKOPEO_CONTAINER=false"
	@echo "  Custom image: make <target> SKOPEO_IMAGE=your-registry/skopeo:tag"

# Complete workflow targets
deploy-complete: gen-ssh-key setup-ssh-access build-push-downloader deploy-encrypted-pod	## Complete deployment workflow

transfer-key-default:	## Transfer default private.pem key
	@echo "Transferring default private key: private.pem"
	@kubectl cp private.pem encrypted-model-inference:/shared/keys/private.key -c model-downloader
	@echo "Private key transferred successfully!"

transfer-and-wait: transfer-key wait-for-pod	## Transfer key and wait for pod completion

transfer-and-wait-default: transfer-key-default wait-for-pod	## Transfer default key and wait for pod completion

clean:	## Clean everything up, also deleting the kind cluster
	-rm -f Modelfile
	-rm -rf model
	-rm -rf ramdisk
	-rm -f kind-config.yaml
	-make stop-port-forward
	-make delete-pod
	-kind delete cluster --name coco
	-podman rm -f kind-registry

configure-machine:	## Configure podman machine to use insecure registry
	envsubst < insecure-registry.conf.tmpl \
	| podman machine ssh 'cat > /etc/containers/registries.conf.d/insecure-registry.conf'

vllm-image:	## Build a vllm image
	mkdir -p cache
	podman build -t vllm-cpu -v `pwd`/cache:/root/.cache:z vllm

# KBS and Attestation targets
deploy-kbs:	## Deploy KBS and mock attestation service
	@echo "Deploying KBS infrastructure..."
	@kubectl apply -f mock-attestation-service.yaml
	@kubectl apply -f kbs-deployment.yaml
	@echo "Waiting for services to be ready..."
	@kubectl wait --for=condition=ready pod -l app=mock-attestation-service --timeout=60s
	@kubectl wait --for=condition=ready pod -l app=kbs --timeout=60s
	@echo "✅ KBS infrastructure deployed successfully!"

populate-kbs-secrets:	## Populate KBS with private key
	@echo "Populating KBS with private key..."
	@kubectl create configmap kbs-secrets --from-file=private.key=private.pem --dry-run=client -o yaml | kubectl apply -f -
	@kubectl rollout restart deployment/kbs
	@echo "✅ KBS secrets populated and restarted!"

kbs-policy-allow:	## Set attestation policy to ALLOW access
	@echo "Setting attestation policy to ALLOW..."
	@kubectl patch configmap mock-as-config --patch='{"data":{"attestation-policy.json":"{\"version\":\"1.0\",\"demo_mode\":true,\"policies\":{\"allow_scenario\":{\"enabled\":true,\"description\":\"Allow access - simulates successful attestation\",\"response\":{\"status\":\"success\",\"tee_evidence\":{\"platform\":\"simulated-tee\",\"security_version\":2,\"measurement\":\"abc123def456\"},\"resource_policy\":{\"allow_access\":true}}},\"deny_scenario\":{\"enabled\":false,\"description\":\"Deny access - simulates failed attestation\",\"response\":{\"status\":\"failed\",\"error\":\"Invalid TEE measurement\",\"tee_evidence\":{\"platform\":\"unknown\",\"security_version\":0},\"resource_policy\":{\"allow_access\":false}}}}}"}}' 
	@kubectl rollout restart deployment/mock-attestation-service
	@echo "✅ Policy set to ALLOW - attestation will succeed"

kbs-policy-deny:	## Set attestation policy to DENY access  
	@echo "Setting attestation policy to DENY..."
	@kubectl patch configmap mock-as-config --patch='{"data":{"attestation-policy.json":"{\"version\":\"1.0\",\"demo_mode\":true,\"policies\":{\"allow_scenario\":{\"enabled\":false,\"description\":\"Allow access - simulates successful attestation\",\"response\":{\"status\":\"success\",\"tee_evidence\":{\"platform\":\"simulated-tee\",\"security_version\":2,\"measurement\":\"abc123def456\"},\"resource_policy\":{\"allow_access\":true}}},\"deny_scenario\":{\"enabled\":true,\"description\":\"Deny access - simulates failed attestation\",\"response\":{\"status\":\"failed\",\"error\":\"Invalid TEE measurement\",\"tee_evidence\":{\"platform\":\"unknown\",\"security_version\":0},\"resource_policy\":{\"allow_access\":false}}}}}"}}' 
	@kubectl rollout restart deployment/mock-attestation-service
	@echo "✅ Policy set to DENY - attestation will fail"

kbs-status:	## Show KBS and attestation service status
	@echo "=== KBS Infrastructure Status ==="
	@kubectl get pods -l app=kbs -o wide
	@kubectl get pods -l app=mock-attestation-service -o wide
	@echo ""
	@echo "=== Current Attestation Policy ==="
	@kubectl exec -it deployment/mock-attestation-service -- curl -s http://localhost:8080/policy | python3 -m json.tool

delete-kbs:	## Delete KBS infrastructure
	@echo "Deleting KBS infrastructure..."
	@kubectl delete -f kbs-deployment.yaml --ignore-not-found=true
	@kubectl delete -f mock-attestation-service.yaml --ignore-not-found=true
	@echo "✅ KBS infrastructure deleted"

clean-k8s:	## Clean up all Kubernetes resources (pods, services, deployments)
	@echo "🧹 Cleaning up all Kubernetes resources..."
	@kubectl delete pod encrypted-model-inference --ignore-not-found=true
	@kubectl delete -f kbs-deployment.yaml --ignore-not-found=true
	@kubectl delete -f mock-attestation-service.yaml --ignore-not-found=true
	@kubectl delete secret kbs-tls-certs --ignore-not-found=true
	@kubectl delete secret kbs-auth-keys --ignore-not-found=true
	@pkill -f "kubectl port-forward" || echo "No port forwarding processes found"
	@echo "✅ All Kubernetes resources cleaned up"

clean-temp-files:	## Clean up temporary certificate and key files
	@echo "🗑️ Cleaning up temporary files..."
	@rm -f kbs-auth-private.pem kbs-auth-public.pem
	@rm -f kbs-auth-private-ed25519.key kbs-auth-public-ed25519.pub  
	@rm -f kbs-tls-private.pem kbs-tls-cert.pem
	@echo "✅ Temporary files cleaned up"

## KBS Demo Workflow Targets

gen-kbs-certs:	## Generate production-ready certificates for KBS
	@echo "🔐 Generating production-ready certificates for KBS..."
	@echo "Generating Ed25519 authentication keys..."
	@openssl genpkey -algorithm ed25519 > kbs-auth-private-ed25519.key
	@openssl pkey -in kbs-auth-private-ed25519.key -pubout -out kbs-auth-public-ed25519.pub
	@chmod 600 kbs-auth-private-ed25519.key
	@echo "Generating TLS certificates..."
	@openssl req -x509 -newkey rsa:4096 -keyout kbs-tls-private.pem -out kbs-tls-cert.pem -days 365 -nodes -subj "/C=US/ST=Demo/L=Demo/O=CoCo/OU=KBS/CN=kbs-service"
	@chmod 600 kbs-tls-private.pem
	@echo "✅ KBS certificates generated successfully!"

setup-kbs-secrets:	## Create Kubernetes secrets for KBS certificates
	@echo "🔑 Creating Kubernetes secrets for KBS..."
	@kubectl create secret generic kbs-tls-certs --from-file=cert.pem=kbs-tls-cert.pem --from-file=key.pem=kbs-tls-private.pem --dry-run=client -o yaml | kubectl apply -f -
	@kubectl create secret generic kbs-auth-keys --from-file=public.pub=kbs-auth-public-ed25519.pub --dry-run=client -o yaml | kubectl apply -f -
	@echo "✅ KBS secrets created successfully!"

deploy-kbs-production:	## Deploy production KBS with proper certificates and attestation
	@echo "🚀 Deploying production-ready KBS infrastructure..."
	@$(MAKE) gen-kbs-certs
	@$(MAKE) setup-kbs-secrets
	@$(MAKE) deploy-kbs
	@$(MAKE) populate-kbs-secrets
	@echo "✅ Production KBS deployment complete!"

demo-kbs-allow:	## Run complete KBS demo with ALLOW scenario
	@echo "🎬 Running complete KBS demo - ALLOW scenario"
	@$(MAKE) deploy-kbs-production
	@$(MAKE) kbs-policy-allow
	@$(MAKE) build-push-downloader
	@$(MAKE) deploy-encrypted-pod-kind
	@echo "✅ KBS ALLOW demo deployed! Check logs with: kubectl logs encrypted-model-inference -c model-downloader -f"

demo-kbs-deny:	## Run complete KBS demo with DENY scenario  
	@echo "🎬 Running complete KBS demo - DENY scenario"
	@$(MAKE) deploy-kbs-production
	@$(MAKE) kbs-policy-deny
	@$(MAKE) build-push-downloader
	@$(MAKE) deploy-encrypted-pod-kind
	@echo "✅ KBS DENY demo deployed! Check logs with: kubectl logs encrypted-model-inference -c model-downloader -f"

demo-reset:	## Reset demo environment and clean up all resources
	@echo "🔄 Resetting demo environment..."
	@$(MAKE) clean-k8s
	@$(MAKE) clean-temp-files
	@echo "✅ Demo environment reset complete!"

help:	## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: help
.DEFAULT_GOAL := help
