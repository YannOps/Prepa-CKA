#!/usr/bin/env bash
# =============================================================================
# show-versions.sh - Compare les versions reellement deployees a common/versions.env. COMMUN aux deux labs.
# A lancer sur le control-plane (utilisateur ubuntu) : bash /opt/cka/show-versions.sh
# Code retour 1 si un ecart est detecte sur une version figee.
# =============================================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
. "${DIR}/versions.env"

ecart=0
check() { # check <libelle> <attendu> <reel>
  if [ "$2" = "$3" ]; then printf '  %-16s %-14s OK\n' "$1" "$3"
  else printf '  %-16s %-14s ECART (attendu %s)\n' "$1" "${3:-absent}" "$2"; ecart=1; fi
}

echo "Noeuds :"
kubectl get nodes -o custom-columns='NOM:.metadata.name,KUBELET:.status.nodeInfo.kubeletVersion,RUNTIME:.status.nodeInfo.containerRuntimeVersion,OS:.status.nodeInfo.osImage,NOYAU:.status.nodeInfo.kernelVersion'
echo
echo "Versions figees (common/versions.env) :"
while read -r v; do check "kubelet" "v${K8S_VERSION}" "$v"; done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}')
check "kube-apiserver" "v${K8S_VERSION}" "$(kubectl -n kube-system get pod -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].image}' | sed 's/.*://')"
check "calico" "${CALICO_VERSION}" "$(kubectl -n calico-system get ds calico-node -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')"
check "helm" "${HELM_VERSION}" "$(helm version --short 2>/dev/null | sed 's/+.*//')"
check "ubuntu" "${UBUNTU_VERSION}" "$(. /etc/os-release && echo "${VERSION_ID}")"
exit "${ecart}"
