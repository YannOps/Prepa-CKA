locals {
  # --- Versions : meme fichier que le lab Hyper-V (common/versions.env)
  common_dir = "${path.module}/../common"
  versions = {
    for m in regexall("(?m)^([A-Z0-9_]+)=(\\S+)", file("${local.common_dir}/versions.env")) : m[0] => m[1]
  }
  image = "ubuntu-${local.versions.UBUNTU_VERSION}"

  # --- Reseau prive (le CIDR des noeuds sert aussi a l'autodetection Calico)
  network_cidr    = "10.0.0.0/16"
  subnet_cidr     = "10.0.1.0/24"
  network_gateway = cidrhost(local.network_cidr, 1) # 10.0.0.1, passerelle du reseau Hetzner
  bastion_ip      = cidrhost(local.subnet_cidr, 5)

  # Memes noms que le lab Hyper-V : les exercices et le seed fonctionnent a l'identique
  nodes = {
    "cka-cp1" = { ip = cidrhost(local.subnet_cidr, 10), role = "cp" }
    "cka-w1"  = { ip = cidrhost(local.subnet_cidr, 11), role = "worker" }
    "cka-w2"  = { ip = cidrhost(local.subnet_cidr, 12), role = "worker" }
  }
  control_plane = one([for name, n in local.nodes : merge(n, { name = name }) if n.role == "cp"])

  hosts_entries = join("\n", concat(
    ["${local.bastion_ip} cka-bastion"],
    [for name, n in local.nodes : "${n.ip} ${name}"],
  ))

  # --- Fichiers communs deposes dans /opt/cka (base64 : aucun souci d'indentation YAML)
  common_node_files = ["versions.env", "bootstrap-node.sh", "show-versions.sh"]
  common_cp_files   = ["init-cp.sh"]
  common_files_b64 = {
    for f in concat(local.common_node_files, local.common_cp_files) :
    f => base64encode(replace(file("${local.common_dir}/${f}"), "\r\n", "\n"))
  }

  sshd_hardening = file("${path.module}/templates/sshd-hardening.conf")
  ssh_public_key = trimspace(file("${path.module}/${var.ssh_public_key_path}"))

  labels = { lab = "cka" }
}
