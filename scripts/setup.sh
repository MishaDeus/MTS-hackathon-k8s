#!/usr/bin/env bash
set -Eeuo pipefail

# Reproducible single-node Kubernetes + Cilium + Gateway API + MetalLB +
# Prometheus + Filebeat setup for Ubuntu 24.04 / WSL2.
#
# Optional environment variables:
#   K8S_VERSION=1.37
#   CILIUM_VERSION=1.20.2
#   GATEWAY_API_VERSION=v1.6.1
#   METALLB_RANGE=192.168.0.200-192.168.0.202
#   FILEBEAT_IMAGE=docker.elastic.co/beats/filebeat:9.5.4

REPO_DIR="${REPO_DIR:-$HOME/hackathon-k8s}"

K8S_VERSION="${K8S_VERSION:-1.37}"
CILIUM_VERSION="${CILIUM_VERSION:-1.20.2}"
GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.6.1}"
METALLB_RANGE="${METALLB_RANGE:-192.168.0.200-192.168.0.202}"
FILEBEAT_IMAGE="${FILEBEAT_IMAGE:-docker.elastic.co/beats/filebeat:9.5.4}"

CONTAINERD_CONFIG="/etc/containerd/config.toml"

log() {
  printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

warn() {
  printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

[[ $EUID -ne 0 ]] || die "Run as a normal user with sudo access, not as root."

[[ -d "$REPO_DIR" ]] || die "Repository not found: $REPO_DIR"

source /etc/os-release

[[ "${ID:-}" == "ubuntu" ]] || die "This script requires Ubuntu."
[[ "${VERSION_ID:-}" == "24.04" ]] || die "This script requires Ubuntu 24.04."

log "Checking WSL/systemd"

if ! grep -qi microsoft /proc/version; then
  warn "Microsoft/WSL kernel was not detected."
  warn "The script may still work on native Ubuntu, but it was designed for WSL2."
fi

PID1="$(ps -p 1 -o comm= | tr -d ' ')"

if [[ "$PID1" != "systemd" ]]; then
  die "systemd is not PID 1. Enable systemd in WSL before running setup."
fi

log "Installing base packages"

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates \
  curl \
  gpg \
  apt-transport-https \
  jq \
  conntrack \
  socat \
  ebtables \
  ethtool \
  iptables \
  iproute2 \
  bash-completion \
  tar \
  gzip

log "Disabling swap"

sudo swapoff -a || true

# Remove active swap entries from fstab if any exist.
if [[ -f /etc/fstab ]]; then
  sudo sed -i \
    -E '/^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]/ s/^/# disabled-by-hackathon-k8s /' \
    /etc/fstab || true
fi

log "Configuring kernel modules"

sudo modprobe overlay
sudo modprobe br_netfilter

sudo tee /etc/modules-load.d/kubernetes.conf >/dev/null <<'EOF'
overlay
br_netfilter
EOF

log "Configuring Kubernetes networking sysctl"

sudo tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system >/dev/null

log "Installing containerd"

if ! command -v containerd >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y containerd
fi

CONTAINERD_VERSION="$(containerd --version | awk '{print $3}' | cut -d. -f1)"

log "Detected containerd major version: $CONTAINERD_VERSION"

sudo mkdir -p /etc/containerd

# Generate a clean default config only if one does not already exist.
if [[ ! -s "$CONTAINERD_CONFIG" ]]; then
  containerd config default | sudo tee "$CONTAINERD_CONFIG" >/dev/null
fi

if [[ "$CONTAINERD_VERSION" -ge 2 ]]; then
  log "Configuring containerd 2.x for systemd cgroups"

  sudo sed -i \
    '/^[[:space:]]*disabled_plugins[[:space:]]*=/ s/"cri"//' \
    "$CONTAINERD_CONFIG" || true

  if grep -q 'io.containerd.cri.v1.runtime' "$CONTAINERD_CONFIG"; then
    if grep -q 'SystemdCgroup' "$CONTAINERD_CONFIG"; then
      sudo sed -i \
        -E 's/^[[:space:]]*SystemdCgroup[[:space:]]*=.*/            SystemdCgroup = true/' \
        "$CONTAINERD_CONFIG"
    else
      sudo tee -a "$CONTAINERD_CONFIG" >/dev/null <<'EOF'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
    fi
  else
    warn "containerd 2.x CRI runtime section was not found in config."
    warn "Regenerating containerd configuration."
    containerd config default | sudo tee "$CONTAINERD_CONFIG" >/dev/null

    sudo tee -a "$CONTAINERD_CONFIG" >/dev/null <<'EOF'

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
  fi
else
  log "Configuring containerd 1.x for systemd cgroups"

  sudo sed -i \
    '/^[[:space:]]*disabled_plugins[[:space:]]*=/ s/"cri"//' \
    "$CONTAINERD_CONFIG" || true

  if grep -q 'io.containerd.grpc.v1.cri' "$CONTAINERD_CONFIG"; then
    sudo sed -i \
      -E 's/^[[:space:]]*SystemdCgroup[[:space:]]*=.*/            SystemdCgroup = true/' \
      "$CONTAINERD_CONFIG"
  else
    sudo tee -a "$CONTAINERD_CONFIG" >/dev/null <<'EOF'

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true
EOF
  fi
fi

sudo systemctl enable --now containerd
sudo systemctl restart containerd

systemctl is-active --quiet containerd \
  || die "containerd is not running"

log "Installing Kubernetes packages"

K8S_KEYRING="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
K8S_LIST="/etc/apt/sources.list.d/kubernetes.list"

sudo mkdir -p /etc/apt/keyrings

if [[ ! -f "$K8S_KEYRING" ]]; then
  curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | sudo gpg --dearmor -o "$K8S_KEYRING"
fi

echo "deb [signed-by=${K8S_KEYRING}] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" \
  | sudo tee "$K8S_LIST" >/dev/null

sudo apt-get update

sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  kubelet \
  kubeadm \
  kubectl

sudo apt-mark hold kubelet kubeadm kubectl >/dev/null

sudo systemctl enable kubelet

log "Checking Kubernetes tools"

kubectl version --client
kubeadm version
kubelet --version
containerd --version

log "Installing Helm if necessary"

if ! command -v helm >/dev/null 2>&1; then
  HELM_VERSION="v3.22.0"
  HELM_ARCHIVE="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz"

  curl -fsSL \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
    -o "$HELM_ARCHIVE"

  rm -rf /tmp/helm-linux-amd64

  tar -xzf "$HELM_ARCHIVE" -C /tmp

  sudo install -m 0755 \
    /tmp/linux-amd64/helm \
    /usr/local/bin/helm

  rm -rf /tmp/linux-amd64 "$HELM_ARCHIVE"
fi

helm version

log "Detecting WSL/Kubernetes node IP"

API_IP="$(
  ip route get 8.8.8.8 2>/dev/null |
    awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
)"

[[ -n "${API_IP:-}" ]] || die "Could not detect node/API IP"

echo "API_IP=$API_IP"

log "Preparing proxy bypasses"

CURRENT_NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

EXTRA_NO_PROXY="localhost,127.0.0.1,${API_IP},192.168.0.200,192.168.0.201,192.168.0.202,10.0.0.0/8,10.96.0.0/12"

if [[ -n "$CURRENT_NO_PROXY" ]]; then
  NEW_NO_PROXY="${CURRENT_NO_PROXY},${EXTRA_NO_PROXY}"
else
  NEW_NO_PROXY="$EXTRA_NO_PROXY"
fi

export NO_PROXY="$NEW_NO_PROXY"
export no_proxy="$NEW_NO_PROXY"

cat > "$HOME/.hackathon-k8s-env" <<EOF
export NO_PROXY="${NEW_NO_PROXY}"
export no_proxy="${NEW_NO_PROXY}"
EOF

echo "Saved shell environment to:"
echo "  $HOME/.hackathon-k8s-env"

log "Checking Kubernetes cluster"

CLUSTER_EXISTS=false

if kubectl get nodes >/dev/null 2>&1; then
  CLUSTER_EXISTS=true
fi

if [[ "$CLUSTER_EXISTS" == false ]]; then

  log "Initializing kubeadm single-node cluster"

  sudo kubeadm init \
    --apiserver-advertise-address="$API_IP" \
    --pod-network-cidr=10.244.0.0/16 \
    --skip-phases=addon/kube-proxy

else

  log "Existing Kubernetes cluster detected"

fi

log "Configuring kubeconfig"

mkdir -p "$HOME/.kube"

sudo cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"

sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

export KUBECONFIG="$HOME/.kube/config"

kubectl cluster-info

log "Removing single-node control-plane taint"

kubectl taint nodes --all \
  node-role.kubernetes.io/control-plane- \
  2>/dev/null || true

log "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kubectl apply --server-side -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing/upgrading Cilium ${CILIUM_VERSION}"

helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
helm repo update cilium >/dev/null

helm upgrade --install cilium cilium/cilium \
  --version "$CILIUM_VERSION" \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="$API_IP" \
  --set k8sServicePort=6443 \
  --set gatewayAPI.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set operator.replicas=1 \
  --wait \
  --timeout 10m

log "Waiting for Cilium and CoreDNS"

kubectl -n kube-system rollout status \
  ds/cilium \
  --timeout=10m

kubectl -n kube-system rollout status \
  deployment/cilium-operator \
  --timeout=10m

kubectl -n kube-system rollout status \
  deployment/coredns \
  --timeout=10m

log "Installing MetalLB"

helm repo add metallb \
  https://metallb.github.io/metallb \
  >/dev/null 2>&1 || true

helm repo update metallb >/dev/null

helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system \
  --create-namespace \
  --wait \
  --timeout 10m

# Keep the repository manifest authoritative.
# METALLB_RANGE can optionally replace the default range.
if [[ "$METALLB_RANGE" == "192.168.0.200-192.168.0.202" ]]; then

  kubectl apply \
    -f "$REPO_DIR/manifests/metallb/ip-pool.yaml"

else

  log "Applying custom MetalLB range: $METALLB_RANGE"

  sed \
    "s/192\.168\.0\.200-192\.168\.0\.202/${METALLB_RANGE}/g" \
    "$REPO_DIR/manifests/metallb/ip-pool.yaml" \
    | kubectl apply -f -

fi

log "Deploying application"

kubectl apply \
  -f "$REPO_DIR/manifests/app/"

log "Deploying Gateway API resources"

# GatewayClass is owned by Cilium Helm.
# Do NOT apply gatewayclass.yaml manually.

kubectl apply \
  -f "$REPO_DIR/manifests/gateway/gateway.yaml"

kubectl apply \
  -f "$REPO_DIR/manifests/gateway/httproute.yaml"

log "Installing Prometheus/Grafana"

kubectl apply \
  -f "https://raw.githubusercontent.com/cilium/cilium/${CILIUM_VERSION}/examples/kubernetes/addons/prometheus/monitoring-example.yaml"

log "Deploying Filebeat"

# The repository manifest is authoritative.
# It contains the ConfigMap, RBAC and DaemonSet.
kubectl apply \
  -f "$REPO_DIR/manifests/logging/filebeat.yaml"

log "Waiting for application/logging/monitoring"

kubectl rollout status \
  deployment/nginx \
  --timeout=5m

kubectl -n kube-system rollout status \
  daemonset/filebeat \
  --timeout=10m

kubectl -n cilium-monitoring rollout status \
  deployment/prometheus \
  --timeout=10m

log "Waiting for Gateway"

for i in {1..30}; do

  GATEWAY_IP="$(
    kubectl get gateway web-gateway \
      -o jsonpath='{.status.addresses[0].value}' \
      2>/dev/null || true
  )"

  if [[ -n "$GATEWAY_IP" ]]; then
    echo "Gateway IP: $GATEWAY_IP"
    break
  fi

  sleep 2

done

GATEWAY_IP="$(
  kubectl get gateway web-gateway \
    -o jsonpath='{.status.addresses[0].value}' \
    2>/dev/null || true
)"

if [[ -z "$GATEWAY_IP" ]]; then
  warn "Gateway does not have an external IP yet."
else

  if [[ "$NEW_NO_PROXY" != *"$GATEWAY_IP"* ]]; then
    NEW_NO_PROXY="${NEW_NO_PROXY},${GATEWAY_IP}"

    export NO_PROXY="$NEW_NO_PROXY"
    export no_proxy="$NEW_NO_PROXY"

    cat > "$HOME/.hackathon-k8s-env" <<EOF
export NO_PROXY="${NEW_NO_PROXY}"
export no_proxy="${NEW_NO_PROXY}"
EOF
  fi

fi

log "Final cluster state"

kubectl get nodes -o wide

kubectl get pods -A

kubectl get gateway,httproute -A

kubectl get svc -A | \
  grep -E 'cilium-gateway|prometheus|nginx' || true

cat <<EOF

============================================================
Setup complete
============================================================

Kubernetes API IP:
  ${API_IP}

Gateway IP:
  ${GATEWAY_IP:-not assigned yet}

MetalLB range:
  ${METALLB_RANGE}

For a new WSL shell:
  source "$HOME/.hackathon-k8s-env"

Then verify:
  "$REPO_DIR/scripts/verify.sh"

Test Gateway:
  curl --noproxy '*' http://${GATEWAY_IP:-192.168.0.200}/

============================================================
EOF
