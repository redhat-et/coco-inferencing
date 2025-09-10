REGISTRY=tosh.lan:5000
MODEL=Qwen/Qwen3-0.6B
MODEL_LC=$(shell echo $(MODEL) | tr '[:upper:]' '[:lower:]')
MODCTL=modctl
SKOPEO=skopeo
HF=huggingface-cli
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

run:	## Run the inferencing pod
	envsubst < inference-pod.yaml | kubectl apply -f -

clean:	## Clean everything up, also deleting the kind cluster
	-rm -f Modelfile
	-rm -rf model
	-rm -rf ramdisk
	-rm -f kind-config.yaml
	-kind delete cluster --name coco

configure-machine:	## Configure podman machine to use insecure registry
	envsubst < insecure-registry.conf.tmpl \
	| podman machine ssh 'cat > /etc/containers/registries.conf.d/insecure-registry.conf'

help:	## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: help
.DEFAULT_GOAL := help
