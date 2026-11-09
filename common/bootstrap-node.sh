#!/usr/bin/env bash
# =============================================================================
# bootstrap-node.sh - Prepare un noeud Kubernetes. COMMUN aux labs Hyper-V et Hetzner.
# Depose dans /opt/cka par le cloud-init de chaque plateforme, avec versions.env, puis lance en root :
#   bash /opt/cka/bootstrap-node.sh <ip-du-noeud>
# Idempotent. Ne met jamais a jour un kubelet/kubeadm deja installe (sinon il annulerait un exercice d'upgrade).
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
. "${DIR}/versions.env"

NODE_IP="${1:?usage : bootstrap-node.sh <ip-du-noeud>}"
K8S_MINOR="${K8S_VERSION%.*}"
PKG_VER="${K8S_VERSION}-${K8S_PKG_REVISION}"
export DEBIAN_FRONTEND=noninteractive
APT=(apt-get -q -y -o Acquire::Retries=5 -o Dpkg::Options::=--force-confold)

log() { printf '[bootstrap] %s\n' "$*"; }

# ----------------------------------------------------------------- acces Internet
# Sur Hetzner, les noeuds sortent par le NAT du bastion, qui peut finir son cloud-init apres eux.
log "Attente de l'acces a pkgs.k8s.io"
for i in $(seq 1 60); do
  curl -fsS --max-time 5 -o /dev/null https://pkgs.k8s.io/ && break
  [ "$i" -eq 60 ] && { echo "pkgs.k8s.io injoignable apres 10 min (route par defaut, DNS, NAT ?)"; exit 1; }
  sleep 10
done

# ----------------------------------------------------------------- noyau
log "Modules noyau et sysctl"
mkdir -p /etc/modules-load.d /etc/sysctl.d
cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system >/dev/null
swapoff -a
sed -i -E '/\sswap\s/ s/^([^#])/#\1/' /etc/fstab

# ----------------------------------------------------------------- paquets
log "Paquets de base"
"${APT[@]}" update
"${APT[@]}" install apt-transport-https ca-certificates curl gpg containerd jq bash-completion vim

log "Depot Kubernetes v${K8S_MINOR}"
mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" \
  | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
  > /etc/apt/sources.list.d/kubernetes.list
"${APT[@]}" update

if dpkg -s kubeadm >/dev/null 2>&1; then
  log "kubeadm deja installe ($(dpkg-query -W -f='${Version}' kubeadm)) : pas de reinstallation"
else
  log "kubelet / kubeadm / kubectl ${PKG_VER}"
  "${APT[@]}" install "kubelet=${PKG_VER}" "kubeadm=${PKG_VER}" "kubectl=${PKG_VER}"
fi
apt-mark hold kubelet kubeadm kubectl >/dev/null
"${APT[@]}" install etcd-client || log "etcd-client indisponible, ignore"

# ----------------------------------------------------------------- containerd
log "containerd : cgroup systemd + image pause attendue par kubeadm"
mkdir -p /etc/containerd
if [ ! -f /etc/containerd/config.toml ] || ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
fi
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
  || { echo "SystemdCgroup introuvable dans /etc/containerd/config.toml"; exit 1; }
# containerd 1.x : sandbox_image = "..." ; containerd 2.x : sandbox = '...'
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" 2>/dev/null | grep '/pause:' || true)"
if [ -n "${PAUSE_IMAGE}" ]; then
  sed -i -E "s#^([[:space:]]*)(sandbox_image|sandbox)([[:space:]]*)=.*#\1\2\3= \"${PAUSE_IMAGE}\"#" /etc/containerd/config.toml
fi
cat > /etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
EOF
systemctl enable containerd >/dev/null
systemctl restart containerd

# ----------------------------------------------------------------- kubelet
log "kubelet lie a ${NODE_IP}"
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/default/kubelet
systemctl enable --now kubelet >/dev/null

# ----------------------------------------------------------------- confort shell (alias k + completion)
if id ubuntu >/dev/null 2>&1 && ! grep -q 'alias k=kubectl' /home/ubuntu/.bashrc 2>/dev/null; then
  echo 'source <(kubectl completion bash); alias k=kubectl; complete -o default -F __start_kubectl k' >> /home/ubuntu/.bashrc
fi

log "Noeud pret (Kubernetes ${K8S_VERSION})"
