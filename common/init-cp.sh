#!/usr/bin/env bash
# =============================================================================
# init-cp.sh - Initialise le control-plane (kubeadm init + Calico + Helm). COMMUN aux deux labs.
# Lance en root sur le control-plane :
#   bash /opt/cka/init-cp.sh <ip-du-control-plane> <cidr-du-reseau-des-noeuds>
# Idempotent etape par etape : relancable apres un echec partiel (ex. Calico en erreur).
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
. "${DIR}/versions.env"

CP_IP="${1:?usage : init-cp.sh <ip-cp> <cidr-noeuds>}"
NODE_CIDR="${2:?usage : init-cp.sh <ip-cp> <cidr-noeuds>}"
CALICO_URL="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
export KUBECONFIG=/etc/kubernetes/admin.conf

log() { printf '[init-cp] %s\n' "$*"; }

# ----------------------------------------------------------------- kubeadm init
if [ -f /etc/kubernetes/admin.conf ]; then
  log "Control-plane deja initialise"
else
  log "kubeadm init (Kubernetes ${K8S_VERSION})"
  kubeadm init \
    --kubernetes-version="v${K8S_VERSION}" \
    --apiserver-advertise-address="${CP_IP}" \
    --control-plane-endpoint="${CP_IP}:6443" \
    --pod-network-cidr="${POD_CIDR}" \
    --node-name="$(hostname)"
fi

if id ubuntu >/dev/null 2>&1; then
  install -d -o ubuntu -g ubuntu -m 700 /home/ubuntu/.kube
  install -o ubuntu -g ubuntu -m 600 /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
fi

# ----------------------------------------------------------------- Helm (version exacte, somme de controle verifiee)
if helm version --short 2>/dev/null | grep -q "^${HELM_VERSION}+"; then
  log "Helm ${HELM_VERSION} deja installe"
else
  log "Helm ${HELM_VERSION}"
  ARCH="$(dpkg --print-architecture)"
  TARBALL="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  TMP="$(mktemp -d)"
  curl -fsSL -o "${TMP}/${TARBALL}" "https://get.helm.sh/${TARBALL}"
  curl -fsSL -o "${TMP}/${TARBALL}.sha256sum" "https://get.helm.sh/${TARBALL}.sha256sum"
  (cd "${TMP}" && sha256sum -c "${TARBALL}.sha256sum" >/dev/null)
  tar -xzf "${TMP}/${TARBALL}" -C "${TMP}"
  install -m 755 "${TMP}/linux-${ARCH}/helm" /usr/local/bin/helm
  rm -rf "${TMP}"
fi

# ----------------------------------------------------------------- Calico (operateur Tigera)
if kubectl get installation default >/dev/null 2>&1; then
  log "Calico deja installe"
else
  log "Calico ${CALICO_VERSION}"
  kubectl apply --server-side -f "${CALICO_URL}/operator-crds.yaml" >/dev/null
  kubectl apply --server-side -f "${CALICO_URL}/tigera-operator.yaml" >/dev/null
  kubectl wait --for=condition=Established crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io --timeout=180s >/dev/null
  # VXLAN : fonctionne sur les deux plateformes (le reseau prive Hetzner ne route pas les IP de pods).
  # Autodetection de l'IP du noeud par CIDR : evite l'interface de gestion (Multipass) ou l'interface publique.
  kubectl apply -f - <<EOF
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: ${POD_CIDR}
        encapsulation: VXLAN
        natOutgoing: Enabled
        nodeSelector: all()
    nodeAddressAutodetectionV4:
      cidrs:
        - "${NODE_CIDR}"
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
EOF
fi

log "Control-plane pret"
