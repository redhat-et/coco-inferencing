REGISTRY=tosh.lan:5000
MODEL=Qwen/Qwen3-0.6B
MODEL_LC=$(shell echo $(MODEL) | tr '[:upper:]' '[:lower:]')
MODCTL=modctl
SKOPEO=skopeo
HF=huggingface-cli

# Pod configuration variables
OCI_REGISTRY=$(REGISTRY)
ENCRYPTED_IMAGE=$(REGISTRY)/$(MODEL_LC):encrypted
DOWNLOADER_IMAGE=$(REGISTRY)/encrypted-model-downloader:latest

export

fetch:	## Fetch image from Huggingface
	$(HF) download $(MODEL) --local-dir model

oci:	## Build OCI artifact for model
	$(MODCTL) modelfile generate model
	$(MODCTL) build -t $(REGISTRY)/$(MODEL_LC):latest -f Modelfile model

push:	## Push OCI artifact to registry
	$(MODCTL) push --plain-http $(REGISTRY)/$(MODEL_LC):latest

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
	@echo "Adding SSH public key to authorized_keys..."
	@if [ -f ~/.ssh/id_rsa.pub ]; then \
		cp ~/.ssh/id_rsa.pub authorized_keys; \
		echo "SSH public key added to authorized_keys"; \
	else \
		echo "SSH public key not found. Run 'make gen-ssh-key' first."; \
		exit 1; \
	fi

encrypt:	## Encrypt the model (registry -> registry)
	$(SKOPEO) copy --encryption-key jwe:public.pem \
		docker://$(REGISTRY)/$(MODEL_LC):latest \
		docker://$(REGISTRY)/$(MODEL_LC):encrypted

decrypt:	## Decrypt the modek (registry -> registry)
	$(SKOPEO) copy --decryption-key private.pem \
		docker://$(REGISTRY)/$(MODEL_LC):encrypted \
		docker://$(REGISTRY)/$(MODEL_LC):decrypted

pull:	## Pull and extract model from registry
	$(MODCTL) pull --extract-dir ramdisk --extract-from-remote --plain-http \
		$(REGISTRY)/$(MODEL_LC):decrypted

kind:	## Start a kind cluster
	envsubst < kind-config.yaml.tmpl > kind-config.yaml
	kind create cluster --config kind-config.yaml --name coco

init-container:	## Build the init container
	podman build -t $(REGISTRY)/model-init:latest -f model-init.containerfile .
	podman push $(REGISTRY)/model-init:latest

build-downloader:	## Build the encrypted model downloader container
	podman build -t $(REGISTRY)/encrypted-model-downloader:latest .

push-downloader:	## Push the encrypted model downloader container
	podman push $(REGISTRY)/encrypted-model-downloader:latest

build-push-downloader: build-downloader push-downloader	## Build and push the encrypted model downloader container

validate-config:	## Validate required configuration variables
	@echo "Validating configuration..."
	@if [ -z "$(REGISTRY)" ]; then echo "Error: REGISTRY not set"; exit 1; fi
	@if [ -z "$(ENCRYPTED_IMAGE)" ]; then echo "Error: ENCRYPTED_IMAGE not set"; exit 1; fi
	@if [ -z "$(DOWNLOADER_IMAGE)" ]; then echo "Error: DOWNLOADER_IMAGE not set"; exit 1; fi
	@if [ -z "$(OCI_REGISTRY)" ]; then echo "Error: OCI_REGISTRY not set"; exit 1; fi
	@echo "Configuration validation passed"

update-pod-config: validate-config	## Update pod YAML with current environment variables
	@echo "Updating pod YAML configuration..."
	@sed -e 's|your-registry/encrypted-model-downloader:latest|$(DOWNLOADER_IMAGE)|g' \
	     -e 's|value: "quay.io"|value: "$(OCI_REGISTRY)"|g' \
	     -e 's|value: "your-registry/encrypted-model:latest"|value: "$(ENCRYPTED_IMAGE)"|g' \
	     encrypted-model-pod.yaml > encrypted-model-pod.yaml.tmp
	@mv encrypted-model-pod.yaml.tmp encrypted-model-pod.yaml
	@echo "Pod YAML updated with:"
	@echo "  Downloader image: $(DOWNLOADER_IMAGE)"
	@echo "  OCI registry: $(OCI_REGISTRY)"
	@echo "  Encrypted image: $(ENCRYPTED_IMAGE)"

deploy-encrypted-pod: update-pod-config	## Deploy the encrypted model inference pod
	@echo "Deploying encrypted model inference pod..."
	@kubectl apply -f encrypted-model-pod.yaml

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

transfer-key:	## Transfer private key via SCP (requires PRIVATE_KEY_PATH variable)
	@if [ -z "$(PRIVATE_KEY_PATH)" ]; then \
		echo "Error: Please specify PRIVATE_KEY_PATH variable"; \
		echo "Usage: make transfer-key PRIVATE_KEY_PATH=/path/to/your/private.pem"; \
		exit 1; \
	fi
	@echo "Transferring private key: $(PRIVATE_KEY_PATH)"
	@echo "Make sure port forwarding is running (make setup-port-forward)"
	@sleep 2
	@scp -P 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		$(PRIVATE_KEY_PATH) root@localhost:/shared/keys/private.key
	@echo "Private key transferred successfully!"

stop-port-forward:	## Stop port forwarding processes
	@echo "Stopping port forwarding processes..."
	@pkill -f "kubectl port-forward encrypted-model-inference" || echo "No port forwarding processes found"

run:	## Run the inferencing pod
	envsubst < inference-pod.yaml | kubectl apply -f -

# Configuration targets for different scenarios
config-local:	## Configure for local registry (kind cluster)
	$(eval REGISTRY=localhost:5000)
	$(eval OCI_REGISTRY=localhost:5000)
	$(eval ENCRYPTED_IMAGE=localhost:5000/$(MODEL_LC):encrypted)
	$(eval DOWNLOADER_IMAGE=localhost:5000/encrypted-model-downloader:latest)
	@echo "Configuration set for local registry:"
	@echo "  REGISTRY: $(REGISTRY)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"

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
	@echo "  OCI_REGISTRY: $(OCI_REGISTRY)"
	@echo "  ENCRYPTED_IMAGE: $(ENCRYPTED_IMAGE)"
	@echo "  DOWNLOADER_IMAGE: $(DOWNLOADER_IMAGE)"

# Complete workflow targets
deploy-complete: gen-ssh-key setup-ssh-access build-push-downloader deploy-encrypted-pod	## Complete deployment workflow

transfer-and-wait: setup-port-forward transfer-key wait-for-pod	## Setup port forwarding, transfer key, and wait for pod

clean:	## Clean everything up, also deleting the kind cluster
	-rm -f Modelfile
	-rm -rf model
	-rm -rf ramdisk
	-rm -f kind-config.yaml
	-make stop-port-forward
	-make delete-pod
	-kind delete cluster --name coco

configure-machine:	## Configure podman machine to use insecure registry
	envsubst < insecure-registry.conf.tmpl \
	| podman machine ssh 'cat > /etc/containers/registries.conf.d/insecure-registry.conf'

help:	## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: help
.DEFAULT_GOAL := help
