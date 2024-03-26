.PHONY: cluster-create cluster-delete cluster-prune install

all: cluster-create

cluster-create: # setup the environment: kubernetes cluster and local docker registry
	@./scripts/cluster.sh create

cluster-delete: # delete the kubernetes cluster
	@./scripts/cluster.sh delete

cluster-prune: # remove all the resources created by setup
	@./scripts/cluster.sh prune

install: # install the dependencies
	@./scripts/deps.sh prune

cluster-dashboard:
	@./scripts/cluster.sh dashboard

cluster-dashboard-token:
	@./scripts/cluster.sh dashboard-token

argocd-install:
	@./scripts/argocd.sh install