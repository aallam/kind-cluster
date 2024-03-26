#!/bin/sh

usage() {
  echo "Usage: $0 [install]"
  exit 1
}

install_argocd() {
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
}

case "$1" in
  install)
    install_argocd
    ;;
  *)
    usage
    ;;
esac
