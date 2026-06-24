# Bootstrap targets per block. Most of the platform is GitOps-managed; these targets cover the
# imperative bootstrap layer and convenience wrappers. Requires KUBECONFIG=infra/kubeconfig.
# Detailed commands: docs/RUNBOOK.md
SHELL := /bin/bash
KUBECONFIG ?= $(PWD)/infra/kubeconfig
export KUBECONFIG
PROFILE ?= juan-test

.PHONY: help cluster infra gateway argocd observability expose status clean

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

cluster: ## Bootstrap k3s + Calico on the 3 EC2 nodes (see docs/RUNBOOK.md Phase 0-1)
	@echo "See docs/RUNBOOK.md Phase 0 (AWS infra) and Phase 1 (k3s+Calico)."
	@echo "Key scripts: infra/k3s/install-server.sh, infra/calico/*"

infra: ## cert-manager local CA + container registry
	helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --set crds.enabled=true --wait
	kubectl apply -f gitops/manifests/cert-manager/clusterissuers.yaml
	kubectl apply -f gitops/manifests/registry/registry.yaml

gateway: ## Gateway API v1.4 CRDs + Istio + main Gateway
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml
	istioctl install --set profile=demo -y
	kubectl apply -f gitops/manifests/gateway/main-gateway.yaml

argocd: ## Install ArgoCD and apply the App-of-Apps root (everything else follows via GitOps)
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.2/manifests/install.yaml
	kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge -p '{"data":{"server.insecure":"true"}}'
	kubectl apply -f gitops/root-app.yaml

observability: ## kube-prometheus-stack + Istio addons (Jaeger/Kiali/Loki) + dashboards
	helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f infra/observability/kube-prom-values.yaml --wait
	kubectl apply -f gitops/manifests/observability/

expose: ## Public tunnel (Cloudflare TryCloudflare) for the ToDo frontend
	kubectl apply -f gitops/manifests/expose/cloudflared.yaml
	@sleep 8; kubectl logs -n todo deploy/cloudflared | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | head -1

status: ## Show platform health
	kubectl get applications -n argocd -o custom-columns='APP:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
	kubectl get cluster todo-pg -n todo
	kubectl get pods -n todo

clean: ## Tear down all AWS resources (instances, EBS, SG, key) by tag
	aws ec2 describe-instances --profile $(PROFILE) --filters Name=tag:Project,Values=k8s-lab Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text | xargs -r aws ec2 terminate-instances --profile $(PROFILE) --instance-ids
	@echo "Instances terminating. Delete SG/key after they're gone."
