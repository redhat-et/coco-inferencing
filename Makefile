REGISTRY=tosh.lan:5000
MODEL=ibm-granite/granite-3.3-2b-instruct:latest
export

kind:	## Start a kind cluster
	envsubst < kind-config.yaml.tmpl > kind-config.yaml
	kind create cluster --config kind-config.yaml --name coco

init-container:	## Build the init container
	podman build -t $(REGISTRY)/model-init:latest -f model-init.containerfile .
	podman push $(REGISTRY)/model-init:latest

run:	## Run the inferencing pod
	envsubst < inference-pod.yaml | kubectl apply -f -

clean:	## Clean everything up, also deleting the kind cluster
	-rm -f kind-config.yaml
	-kind delete cluster --name coco

configure-machine:	## Configure podman machine to use insecure registry
	envsubst < insecure-registry.conf.tmpl \
	| podman machine ssh 'cat > /etc/containers/registries.conf.d/insecure-registry.conf'

help:	## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: help
.DEFAULT_GOAL := help
