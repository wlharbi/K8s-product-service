#!/usr/bin/env bash
# Lab helper for fresh CentOS Stream 9 VMs reached only through a web console
# (no copy-paste, no SSH from outside). It runs the long setup commands so you
# only type short ones. All commands run on master (CentOS9-01):
#
#   sudo bash scripts/lab-setup.sh server                # prepare master, install k3s server + ingress-nginx
#   bash scripts/lab-setup.sh join USER@IP2 USER@IP3     # prepare each worker over SSH and join it
#   bash scripts/lab-setup.sh image [TAG]                # build the image, load it on every node (default 1.0.0)
#   bash scripts/lab-setup.sh status                     # show nodes and pods
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT")"
WORKERS_FILE="$HOME/.product-service-workers"
K3S=/usr/local/bin/k3s
KUBECTL=/usr/local/bin/kubectl
INGRESS_NGINX=https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.0/deploy/static/provider/cloud/deploy.yaml

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

step() { echo; echo ">>> $*"; }
need_root() {
  if [ "$(id -u)" -ne 0 ]; then echo "run this with sudo: sudo bash $0 $*"; exit 1; fi
}
server_ip() { hostname -I | awk '{print $1}'; }

# Packages, time sync and firewall rules every node needs. Optional arg: new hostname.
prepare() {
  need_root prepare
  step "Installing packages"
  dnf install -y podman make git tar ethtool chrony curl openssh-clients

  step "Starting time sync (TLS between nodes fails if clocks drift)"
  systemctl enable --now chronyd

  if systemctl is-active --quiet firewalld; then
    step "Opening k3s ports and trusting the pod/service networks"
    firewall-cmd --permanent --add-port=6443/tcp --add-port=10250/tcp --add-port=8472/udp
    firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16 --add-source=10.43.0.0/16
    firewall-cmd --reload
  fi

  if [ -n "${1:-}" ]; then
    step "Setting hostname to $1"
    hostnamectl set-hostname "$1"
  fi
}

server() {
  need_root server
  prepare

  step "Installing k3s server (Traefik disabled; the manifests use ingress-nginx)"
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik --write-kubeconfig-mode 600" sh -

  step "Giving ${SUDO_USER:-root} its own kubeconfig"
  local user="${SUDO_USER:-root}" home
  home="$(getent passwd "$user" | cut -d: -f6)"
  mkdir -p "$home/.kube"
  cp /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
  chown -R "$user": "$home/.kube"
  chmod 600 "$home/.kube/config"

  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  step "Waiting for the node to be Ready"
  until "$KUBECTL" get nodes >/dev/null 2>&1; do sleep 2; done
  "$KUBECTL" wait --for=condition=Ready node --all --timeout=180s

  step "Installing ingress-nginx (lab Part 2)"
  "$KUBECTL" apply -f "$INGRESS_NGINX"
  # rollout status waits for the pod to exist; `kubectl wait` fails if run before it is created
  "$KUBECTL" -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=300s

  echo
  echo "Server ready. Next: bash $0 join USER@WORKER1_IP USER@WORKER2_IP"
}

# Runs on each worker (called by `join`). Args: SERVER_IP TOKEN [HOSTNAME]
agent() {
  need_root agent
  prepare "${3:-}"
  step "Installing k3s agent and joining $1"
  curl -sfL https://get.k3s.io | K3S_URL="https://$1:6443" K3S_TOKEN="$2" sh -
}

join() {
  [ $# -ge 1 ] || { echo "usage: $0 join USER@IP2 USER@IP3"; exit 1; }
  local token ip seen i=1
  token="$($SUDO cat /var/lib/rancher/k3s/server/node-token)"
  ip="$(server_ip)"
  seen=" $(hostname) "

  if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
    step "Creating an SSH key on master"
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519" -q
  fi

  step "Packing the project"
  tar czf /tmp/product-service.tar.gz -C "$(dirname "$PROJECT")" \
    --exclude=.venv --exclude=__pycache__ --exclude='*.db' "$PROJECT_NAME"

  for host in "$@"; do
    step "Worker $i: $host (type its password when asked; only needed once)"
    ssh-copy-id -o StrictHostKeyChecking=accept-new "$host"

    local name newname=""
    name="$(ssh "$host" hostname)"
    case "$name" in
      localhost*) newname="worker$i" ;;
      *) case "$seen" in *" $name "*) newname="worker$i" ;; esac ;;
    esac
    seen="$seen${newname:-$name} "

    scp /tmp/product-service.tar.gz "$host:/tmp/"
    ssh -t "$host" "tar xzf /tmp/product-service.tar.gz -C ~ && sudo bash ~/$PROJECT_NAME/scripts/lab-setup.sh agent $ip $token $newname"

    touch "$WORKERS_FILE"
    grep -qx "$host" "$WORKERS_FILE" || echo "$host" >> "$WORKERS_FILE"
    i=$((i + 1))
  done

  step "Cluster nodes"
  "$KUBECTL" get nodes -o wide
}

image() {
  local tag="${1:-1.0.0}" ref tarball=/tmp/product-service-image.tar
  ref="docker.io/library/product-service:$tag"

  step "Building $ref (docker.io/library/ prefix so k3s finds it by its short name)"
  cd "$PROJECT"
  podman build -t "$ref" .
  podman save "$ref" -o "$tarball"

  step "Loading the image on master"
  $SUDO "$K3S" ctr images import "$tarball"

  if [ -s "$WORKERS_FILE" ]; then
    local hosts host
    mapfile -t hosts < "$WORKERS_FILE"
    for host in "${hosts[@]}"; do
      step "Loading the image on $host"
      scp "$tarball" "$host:/tmp/"
      ssh -t "$host" "sudo $K3S ctr images import $tarball"
    done
  fi
  echo; echo "Image $ref is on every node."
}

status() {
  "$KUBECTL" get nodes -o wide
  echo
  "$KUBECTL" get pods -A -o wide
}

case "${1:-}" in
  prepare) shift; prepare "$@" ;;
  server)  server ;;
  agent)   shift; agent "$@" ;;
  join)    shift; join "$@" ;;
  image)   shift; image "$@" ;;
  status)  status ;;
  *) sed -n '2,10p' "$0"; exit 1 ;;
esac
