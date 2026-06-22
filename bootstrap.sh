#!/usr/bin/env bash
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
HELM=${HELM:-helm}
REPO_URL=${REPO_URL:-https://github.com/jusefe11/linktic.git}

require() { command -v "$1" >/dev/null || { echo "Falta el comando: $1" >&2; exit 1; }; }

cluster() {
  require "$KUBECTL"
  "$KUBECTL" get nodes -o wide
  "$KUBECTL" get --raw=/readyz
}

infra() {
  require "$KUBECTL"; require "$HELM"
  "$KUBECTL" apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.1/standard-install.yaml
  "$HELM" repo add jetstack https://charts.jetstack.io --force-update
  "$HELM" repo add metallb https://metallb.github.io/metallb --force-update
  "$HELM" repo add longhorn https://charts.longhorn.io --force-update
  "$HELM" repo add cnpg https://cloudnative-pg.github.io/charts --force-update
  "$HELM" upgrade --install cert-manager jetstack/cert-manager -n cert-manager --create-namespace --version v1.20.2 --set crds.enabled=true --wait
  "$HELM" upgrade --install metallb metallb/metallb -n metallb-system --create-namespace --version 0.16.1 --set speaker.frr.enabled=false --wait
  "$HELM" upgrade --install longhorn longhorn/longhorn -n longhorn-system --create-namespace --version 1.12.0 --set preUpgradeChecker.jobEnabled=false --set persistence.defaultClassReplicaCount=2 --wait --timeout 30m
  "$HELM" upgrade --install cloudnative-pg cnpg/cloudnative-pg -n cnpg-system --create-namespace --version 0.28.3 --wait
}

gateway() {
  require "$HELM"; require "$KUBECTL"
  "$HELM" repo add istio https://istio-release.storage.googleapis.com/charts --force-update
  "$HELM" upgrade --install istio-base istio/base -n istio-system --create-namespace --version 1.30.1 --wait
  "$HELM" upgrade --install istiod istio/istiod -n istio-system --version 1.30.1 --wait
  "$KUBECTL" apply -k infra/platform
}

argocd() {
  require "$HELM"; require "$KUBECTL"
  "$HELM" repo add argo https://argoproj.github.io/argo-helm --force-update
  "$HELM" upgrade --install argo-cd argo/argo-cd -n argocd --create-namespace --set configs.params.server\\.insecure=true --wait --timeout 15m
  "$KUBECTL" apply -f root/root-app.yaml
}

observability() {
  require "$KUBECTL"
  "$KUBECTL" apply -k observability/platform
  "$KUBECTL" get pods -n monitoring
}

expose() {
  require "$KUBECTL"
  "$KUBECTL" rollout restart deployment/cloudflared -n public-tunnel
  "$KUBECTL" logs -n public-tunnel deployment/cloudflared --tail=100 | grep -Eo 'https://[-a-z0-9]+\.trycloudflare\.com' | tail -1
}

status() {
  require "$KUBECTL"
  "$KUBECTL" get nodes
  "$KUBECTL" get gatewayclass,gateway,httproute -A
  "$KUBECTL" get applications.argoproj.io -n argocd
  "$KUBECTL" get clusters.postgresql.cnpg.io -n todo
  "$KUBECTL" get pvc -A
  "$KUBECTL" get pods -A | grep -vE 'Running|Completed' || true
}

case "${1:-}" in
  cluster|infra|gateway|argocd|observability|expose|status) "$1" ;;
  *) echo "Uso: $0 {cluster|infra|gateway|argocd|observability|expose|status}"; exit 1 ;;
esac
