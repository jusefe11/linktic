#!/bin/bash

case "$1" in
  cluster)
    echo "Cluster deployment"
    ;;
  infra)
    kubectl apply -f infra/
    ;;
  gateway)
    kubectl apply -f gateway/
    ;;
  argocd)
    kubectl apply -f root/root-app.yaml
    ;;
  observability)
    kubectl apply -f observability/
    ;;
  expose)
    echo "Starting port-forward and Ngrok"
    kubectl port-forward svc/todo-frontend 8080:80 -n todo
    ;;
  *)
    echo "Usage:"
    echo "./bootstrap.sh cluster"
    echo "./bootstrap.sh infra"
    echo "./bootstrap.sh gateway"
    echo "./bootstrap.sh argocd"
    echo "./bootstrap.sh observability"
    echo "./bootstrap.sh expose"
    ;;
esac
