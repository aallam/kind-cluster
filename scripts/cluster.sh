#!/bin/sh
set -o errexit

CLUSTER_NAME='dev'
REG_NAME='local-registry'
REG_PORT='5000'

usage() {
  echo "Usage: $0 [create|delete|prune|token]"
  exit 1
}

check_cluster_exists() {
  if [ "$(kind get clusters | grep "${CLUSTER_NAME}")" = "${CLUSTER_NAME}" ]; then
    echo "ℹ️ Cluster already exists, skipping cluster creation"
    exit 0
  fi
}

start_local_registry() {
  if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
    docker run \
      -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "${REG_NAME}" \
      registry:2
  fi
  echo "🐳 Local registry running at localhost:${REG_PORT}"
}

create_kind_cluster() {
  cat <<EOF | kind create cluster --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
networking:
  disableDefaultCNI: true
  podSubnet: 192.168.0.0/16
nodes:
  - role: control-plane
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        kubeletExtraArgs:
          node-labels: "ingress-ready=true"
    extraPortMappings:
    - containerPort: 80
      hostPort: 80
      protocol: TCP
    - containerPort: 443
      hostPort: 443
      protocol: TCP
    - containerPort: 30000
      hostPort: 30000
    - containerPort: 32000
      hostPort: 32000
    - containerPort: 30100
      hostPort: 30100
    - containerPort: 30101
      hostPort: 30101
    - containerPort: 30102
      hostPort: 30102
  - role: worker
  - role: worker
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry]
    config_path = "/etc/containerd/certs.d"
EOF
}

configure_registry_for_nodes() {
  REGISTRY_DIR="/etc/containerd/certs.d/localhost:${REG_PORT}"
  for node in $(kind get nodes -n $CLUSTER_NAME); do
    docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
    echo "[host.\"http://${REG_NAME}:5000\"]" | docker exec -i "${node}" tee "${REGISTRY_DIR}/hosts.toml" > /dev/null
  done
}

connect_registry_to_cluster_network() {
  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
    docker network connect "kind" "${REG_NAME}"
  fi
}

install_network_plugin() {
  echo "🔌 Installing Network Plugin"
  kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml > /dev/null 2>&1
  kubectl wait --namespace kube-system --for=condition=ready pod --selector=k8s-app=calico-node --timeout=-1s > /dev/null 2>&1
}

install_ingress_controller() {
  echo "🌐 Installing Ingress Controller"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml > /dev/null 2>&1
  kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=-1s > /dev/null 2>&1
}

install_load_balancer_controller() {
  echo "🔀 Installing Load Balancer"
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml > /dev/null 2>&1
  kubectl wait --namespace metallb-system --for=condition=ready pod --selector=app=metallb --timeout=-1s > /dev/null 2>&1
  ip_base=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' kind | cut -d' ' -f1 | cut -d'.' -f1-2)
  ip_range_start="${ip_base}.255.200"
  ip_range_end="${ip_base}.255.250"
  kubectl apply -f - > /dev/null 2>&1 <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: example
  namespace: metallb-system
spec:
  addresses:
  - ${ip_range_start}-${ip_range_end}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF
}

install_metrics_server() {
  echo "📈 Installing Metrics Server"
  kubectl create -f https://gist.githubusercontent.com/aallam/571134905e1485f520978c09b1dc9786/raw/01c0a323cfbf37c17027805d2dd0d54f81579f85/metrics-server-insecure-tls.yaml > /dev/null 2>&1
  kubectl wait --namespace kube-system --for=condition=ready pod --selector=k8s-app=metrics-server --timeout=-1s > /dev/null 2>&1
}

install_dashboard() {
  echo "📊 Installing Dashboard"
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v2.7.0/aio/deploy/recommended.yaml > /dev/null 2>&1
  kubectl wait --namespace kubernetes-dashboard --for=condition=ready pod --selector=k8s-app=kubernetes-dashboard --timeout=-1s > /dev/null 2>&1
  echo "🔑 Creating Dashboard User"
  kubectl create -f https://gist.githubusercontent.com/aallam/15008b83cab60444684bff7f3184c309/raw/98260b5aaa25aac968d2a17da98b2032fa76b036/dashboard-user.yaml > /dev/null 2>&1
}

dashboard_token() {
  # shellcheck disable=SC1083
  kubectl get secret admin-user -n kubernetes-dashboard -o jsonpath={".data.token"} | base64 -d
}

create_resources() {
  echo "🏗️ Cluster provisioning.."
  check_cluster_exists
  start_local_registry
  create_kind_cluster
  configure_registry_for_nodes
  connect_registry_to_cluster_network
  echo "🛠Cluster configuration.."
  install_network_plugin
  install_ingress_controller
  install_load_balancer_controller
  install_metrics_server
  install_dashboard
  echo "🚀 Cluster ready!"
}

delete_resources() {
  echo "🔥 Deleting cluster"
  # Delete the kind cluster
  kind delete cluster --name ${CLUSTER_NAME}
}

prune_resources() {
  echo "🧹 Pruning resources"

  # Stop and remove the registry container
  kind delete cluster --name ${CLUSTER_NAME}

  # Remove the registry image
  docker stop ${REG_NAME} && docker rm ${REG_NAME}
}

if [ $# -eq 0 ]; then
  usage
fi

case "$1" in
  create)
    create_resources
    ;;
  delete)
    delete_resources
    ;;
  prune)
    prune_resources
    ;;
  dashboard-token)
    dashboard_token
    ;;
  dashboard)
    open "http://localhost:8001/api/v1/namespaces/kubernetes-dashboard/services/https:kubernetes-dashboard:/proxy/"
    ;;
  *)
    usage
    ;;
esac