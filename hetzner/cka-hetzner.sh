#!/usr/bin/env bash
# =============================================================================
# cka-hetzner.sh - Lab CKA sur Hetzner Cloud : bastion + 3 noeuds kubeadm prives (Calico).
# Equivalent de hyperv/cka-lab.ps1 : memes noms de noeuds, memes versions (common/versions.env),
# memes scripts de preparation (common/*.sh), meme seed. A lancer depuis Linux/WSL.
#
# Usage : ./hetzner/cka-hetzner.sh <action> [-y]
#   create      cree l'infrastructure (Terraform) puis le cluster (kubeadm init + join)
#   seed        charge realiste (common/cka-seed.sh) sur cka-cp1
#   status      serveurs factures, noeuds, controle des versions
#   update-ip   met a jour ton IP publique dans le firewall du bastion (apres changement d'IP)
#   ssh-config  regenere hetzner/ssh/config et l'Include dans ~/.ssh/config
#   destroy     supprime TOUT (plus rien n'est facture)
#   -y          pas de confirmation (create / destroy)
#
# Prerequis : terraform, ssh, curl, jq, et un jeton API Hetzner (projet dedie, Lecture/Ecriture) :
#   read -rs HCLOUD_TOKEN && export HCLOUD_TOKEN
# Reglages optionnels (variables d'environnement) :
#   CKA_LOCATION (fsn1)  CKA_BASTION_TYPE (cpx12)  CKA_NODE_TYPE (cpx22)  CKA_ADMIN_CIDR (IP detectee en /32)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "${HERE}")"
COMMON="${REPO}/common"
SSH_DIR="${HERE}/ssh"
SSH_KEY="${SSH_DIR}/cka_lab_ed25519"
SSH_CONFIG="${SSH_DIR}/config"
KNOWN_HOSTS="${SSH_DIR}/known_hosts"
USER_SSH_CONFIG="${HOME}/.ssh/config"
MARK_BEGIN="# >>> CKA-LAB-HETZNER"
MARK_END="# <<< CKA-LAB-HETZNER"
API="https://api.hetzner.cloud/v1"

# shellcheck source=../common/versions.env
. "${COMMON}/versions.env"

export TF_VAR_location="${CKA_LOCATION:-fsn1}"
export TF_VAR_bastion_server_type="${CKA_BASTION_TYPE:-cpx12}"
export TF_VAR_node_server_type="${CKA_NODE_TYPE:-cpx22}"
export TF_IN_AUTOMATION=1

ACTION="${1:-}"
YES=0
[ "${2:-}" = "-y" ] && YES=1

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$1" "${*:2}"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[erreur]\033[0m %s\n' "$*" >&2; exit 1; }
tf()   { terraform -chdir="${HERE}" "$@"; }
sshl() { ssh -F "${SSH_CONFIG}" "$@"; }
scpl() { scp -F "${SSH_CONFIG}" "$@"; }

# Appel API Hetzner. Le jeton passe par un descripteur de fichier, jamais par la ligne de commande
# (sinon visible dans la liste des processus).
api() {
  curl -fsS --max-time 20 -H @<(printf 'Authorization: Bearer %s\n' "${HCLOUD_TOKEN}") "${API}/$1"
}

confirm() { # confirm <question>
  [ "${YES}" -eq 1 ] && return 0
  local r; read -r -p "$1 Tape OUI : " r; [ "${r}" = "OUI" ]
}

# ----------------------------------------------------------------- prerequis
check_prereqs() {
  local c
  for c in terraform ssh ssh-keygen scp curl jq; do
    command -v "${c}" >/dev/null || die "${c} introuvable"
  done
  [ -n "${HCLOUD_TOKEN:-}" ] || die "HCLOUD_TOKEN absent. Cree un jeton Lecture/Ecriture dans un projet Hetzner dedie au lab, puis :
  read -rs HCLOUD_TOKEN && export HCLOUD_TOKEN"
  api "locations" >/dev/null || die "Jeton refuse par l'API Hetzner (invalide, revoque, ou en lecture seule ?)"
}

# Types de serveurs connus, commandables a cet emplacement, et cout horaire estime
check_availability() {
  local loc="${TF_VAR_location}" dcs t id price where ok
  local -A hourly=()
  dcs="$(api "datacenters?per_page=50")"
  for t in "${TF_VAR_bastion_server_type}" "${TF_VAR_node_server_type}"; do
    local st; st="$(api "server_types?name=${t}")"
    id="$(jq -r '.server_types[0].id // empty' <<<"${st}")"
    [ -n "${id}" ] || die "Type de serveur inconnu : ${t}"
    ok="$(jq -r --arg loc "${loc}" --argjson id "${id}" \
      '[.datacenters[] | select(.location.name == $loc) | (.server_types.available | index($id)) != null] | any' <<<"${dcs}" 2>/dev/null || echo unknown)"
    if [ "${ok}" = "false" ]; then
      where="$(jq -r --argjson id "${id}" \
        '[.datacenters[] | select((.server_types.available | index($id)) != null) | .location.name] | unique | join(", ")' <<<"${dcs}")"
      die "${t} non commandable a ${loc} actuellement. Disponible : ${where:-nulle part}.
  Essaie : CKA_LOCATION=<emplacement> ou CKA_NODE_TYPE / CKA_BASTION_TYPE=<autre type>"
    elif [ "${ok}" = "unknown" ]; then
      warn "Disponibilite de ${t} non verifiable via l'API, on continue"
    fi
    price="$(jq -r --arg loc "${loc}" '.server_types[0].prices[] | select(.location == $loc) | .price_hourly.gross' <<<"${st}" | head -1)"
    log dispo "${t} commandable a ${loc} (${price:-?} EUR/h TTC)"
    hourly["${t}"]="${price:-0}"
  done
  log cout "Estimation : $(awk -v b="${hourly[${TF_VAR_bastion_server_type}]}" -v n="${hourly[${TF_VAR_node_server_type}]}" \
    'BEGIN{printf "%.3f", b + 3*n}') EUR/h TTC pour le lab (facture a l'heure, meme eteint : pense a destroy)"
}

ensure_key() {
  install -d -m 700 "${SSH_DIR}"
  if [ ! -f "${SSH_KEY}" ]; then
    log ssh "Generation de la cle ${SSH_KEY}"
    ssh-keygen -q -t ed25519 -N "" -C cka-lab-hetzner -f "${SSH_KEY}"
  fi
  chmod 600 "${SSH_KEY}"
}

# IP publique autorisee en SSH sur le bastion
set_admin_cidr() {
  local cidr="${CKA_ADMIN_CIDR:-}" ip
  if [ -z "${cidr}" ]; then
    ip="$(curl -fsS --max-time 10 https://api.ipify.org || true)"
    [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "IP publique non detectee : relance avec CKA_ADMIN_CIDR=<ton-ip>/32"
    cidr="${ip}/32"
  fi
  export TF_VAR_admin_cidrs="[\"${cidr}\"]"
  log fw "SSH autorise depuis ${cidr}"
}

tf_init() { tf init -input=false >/dev/null; }

# ----------------------------------------------------------------- acces SSH (ProxyJump via le bastion)
write_ssh_config() {
  local bastion nodes name ip
  bastion="$(tf output -raw bastion_ipv4)"
  nodes="$(tf output -json nodes)"
  {
    echo "# Genere par cka-hetzner.sh - ne pas modifier"
    printf 'Host cka-bastion\n  HostName %s\n' "${bastion}"
    printf '  User ubuntu\n  IdentityFile "%s"\n  IdentitiesOnly yes\n  UserKnownHostsFile "%s"\n  StrictHostKeyChecking accept-new\n\n' "${SSH_KEY}" "${KNOWN_HOSTS}"
    while read -r name ip; do
      printf 'Host %s\n  HostName %s\n  ProxyJump cka-bastion\n' "${name}" "${ip}"
      printf '  User ubuntu\n  IdentityFile "%s"\n  IdentitiesOnly yes\n  UserKnownHostsFile "%s"\n  StrictHostKeyChecking accept-new\n\n' "${SSH_KEY}" "${KNOWN_HOSTS}"
    done < <(jq -r 'to_entries[] | "\(.key) \(.value)"' <<<"${nodes}")
  } > "${SSH_CONFIG}"
  chmod 600 "${SSH_CONFIG}"
  # Seule trace dans ~/.ssh/config : un Include EN TETE (apres un bloc Host, il ne s'appliquerait qu'a ce Host)
  install -d -m 700 "${HOME}/.ssh"
  touch "${USER_SSH_CONFIG}"; chmod 600 "${USER_SSH_CONFIG}"
  local tmp; tmp="$(mktemp)"
  { printf '%s\nInclude "%s"\n%s\n\n' "${MARK_BEGIN}" "${SSH_CONFIG}" "${MARK_END}"; strip_ssh_include; } > "${tmp}"
  cat "${tmp}" > "${USER_SSH_CONFIG}"; rm -f "${tmp}"
  log ssh "ssh cka-bastion | ssh cka-cp1 | ssh cka-w1 | ssh cka-w2"
}

strip_ssh_include() { # contenu de ~/.ssh/config sans le bloc du lab
  awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '$0==b{skip=1;next} $0==e{skip=0; if((getline)>0 && $0!="") print; next} !skip' "${USER_SSH_CONFIG}"
}

wait_ssh() { # wait_ssh <hote>
  local i
  for i in $(seq 1 60); do
    sshl -o ConnectTimeout=5 -o BatchMode=yes "$1" true 2>/dev/null && return 0
    sleep 5
  done
  die "$1 injoignable en SSH apres 5 min"
}

# ----------------------------------------------------------------- actions
cmd_create() {
  check_prereqs
  check_availability
  ensure_key
  set_admin_cidr
  log tf "Versions (common/versions.env) : Ubuntu ${UBUNTU_VERSION}, Kubernetes ${K8S_VERSION}, Calico ${CALICO_VERSION}, Helm ${HELM_VERSION}"
  tf_init
  if [ "${YES}" -eq 1 ]; then tf apply -input=false -auto-approve; else tf apply -input=false; fi
  : > "${KNOWN_HOSTS}"   # nouvelles VM = nouvelles cles d'hote
  chmod 600 "${KNOWN_HOSTS}"
  write_ssh_config

  local nodes cp_name cp_ip node_cidr name rc join
  nodes="$(tf output -json nodes | jq -r 'keys[]')"
  cp_name="$(tf output -json control_plane | jq -r .name)"
  cp_ip="$(tf output -json control_plane | jq -r .ip)"
  node_cidr="$(tf output -raw node_cidr)"

  log ssh "Attente du bastion"
  wait_ssh cka-bastion
  for name in ${nodes}; do
    log vm "Attente de cloud-init sur ${name} (preparation du noeud, quelques minutes)"
    wait_ssh "${name}"
    rc=0; sshl "${name}" cloud-init status --wait >/dev/null || rc=$?
    [ "${rc}" -eq 0 ] || [ "${rc}" -eq 2 ] || die "cloud-init en erreur sur ${name} : ssh ${name} sudo tail -50 /var/log/cloud-init-output.log"
  done

  log k8s "kubeadm init + Calico + Helm sur ${cp_name} (common/init-cp.sh)"
  sshl "${cp_name}" sudo bash /opt/cka/init-cp.sh "${cp_ip}" "${node_cidr}"
  join="$(sshl "${cp_name}" sudo kubeadm token create --print-join-command)"
  [[ "${join}" == "kubeadm join"* ]] || die "Commande de join invalide : ${join}"
  for name in ${nodes}; do
    [ "${name}" = "${cp_name}" ] && continue
    if sshl "${name}" test -f /etc/kubernetes/kubelet.conf; then log k8s "${name} deja joint"; continue; fi
    log k8s "Join ${name}"
    # shellcheck disable=SC2086
    sshl "${name}" sudo ${join}
  done
  log k8s "Attente des noeuds Ready (images Calico, quelques minutes)"
  sshl "${cp_name}" kubectl wait --for=condition=Ready nodes --all --timeout=900s
  sshl "${cp_name}" bash /opt/cka/show-versions.sh || warn "Ecart de versions detecte (voir ci-dessus)"

  cat <<EOF

=== Lab CKA Hetzner pret ===
  Acces     : ssh cka-cp1   (via le bastion, comme a l'examen)
  Seed      : ./hetzner/cka-hetzner.sh seed
  Etat      : ./hetzner/cka-hetzner.sh status
  FIN       : ./hetzner/cka-hetzner.sh destroy   <- le lab est facture tant qu'il existe
EOF
}

cmd_seed() {
  [ -f "${SSH_CONFIG}" ] || die "Lab absent (pas de ${SSH_CONFIG}) : lance create"
  log seed "Copie de cka-seed.sh et versions.env sur cka-cp1"
  scpl -q "${COMMON}/cka-seed.sh" "${COMMON}/versions.env" cka-cp1:
  sshl cka-cp1 bash cka-seed.sh
}

cmd_status() {
  check_prereqs
  log api "Serveurs du lab factures en ce moment :"
  api "servers?label_selector=lab%3Dcka" | jq -r '.servers[] | "  \(.name)\t\(.server_type.name)\t\(.status)\t\(.datacenter.location.name)"'
  if [ -f "${SSH_CONFIG}" ] && sshl -o ConnectTimeout=5 -o BatchMode=yes cka-cp1 true 2>/dev/null; then
    echo
    sshl cka-cp1 kubectl get nodes -o wide
    echo
    sshl cka-cp1 bash /opt/cka/show-versions.sh || true
  fi
}

cmd_update_ip() {
  check_prereqs
  ensure_key
  set_admin_cidr
  tf_init
  tf apply -input=false -auto-approve -target=hcloud_firewall.bastion
}

cmd_ssh_config() {
  tf_init
  write_ssh_config
}

cmd_destroy() {
  check_prereqs
  confirm "Supprimer DEFINITIVEMENT le lab Hetzner (serveurs, reseau, firewall, cle) ?" || { echo "Abandon."; exit 0; }
  ensure_key
  # La valeur importe peu pour detruire, mais la variable est obligatoire
  export TF_VAR_admin_cidrs="[\"${CKA_ADMIN_CIDR:-192.0.2.1/32}\"]"
  tf_init
  tf destroy -input=false -auto-approve
  rm -f "${SSH_CONFIG}" "${KNOWN_HOSTS}"
  if [ -f "${USER_SSH_CONFIG}" ]; then
    local tmp; tmp="$(mktemp)"; strip_ssh_include > "${tmp}"; cat "${tmp}" > "${USER_SSH_CONFIG}"; rm -f "${tmp}"
  fi
  local left
  left="$(api "servers?label_selector=lab%3Dcka" | jq '.servers | length')"
  [ "${left}" = "0" ] && log ok "Lab supprime : plus aucun serveur facture." \
    || warn "${left} serveur(s) avec le label lab=cka existent encore : verifie la console Hetzner."
  echo "Conserves : la cle SSH (${SSH_KEY}) et le cache Terraform."
}

case "${ACTION}" in
  create)     cmd_create ;;
  seed)       cmd_seed ;;
  status)     cmd_status ;;
  update-ip)  cmd_update_ip ;;
  ssh-config) cmd_ssh_config ;;
  destroy)    cmd_destroy ;;
  *) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
