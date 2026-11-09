resource "hcloud_ssh_key" "lab" {
  name       = "cka-lab"
  public_key = local.ssh_public_key
  labels     = local.labels
}

# Repartit les noeuds sur des hotes physiques differents (gratuit)
resource "hcloud_placement_group" "nodes" {
  name   = "cka-nodes"
  type   = "spread"
  labels = local.labels
}

# --- Bastion : seul point d'entree public, passerelle NAT des noeuds.
# Joue le role de la machine de depart de l'examen (on s'y connecte, puis ssh vers les noeuds).
resource "hcloud_server" "bastion" {
  name         = "cka-bastion"
  image        = local.image
  server_type  = var.bastion_server_type
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.lab.id]
  firewall_ids = [hcloud_firewall.bastion.id]
  labels       = merge(local.labels, { role = "bastion" })

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.lab.id
    ip         = local.bastion_ip
  }

  user_data = templatefile("${path.module}/templates/bastion.yaml.tftpl", {
    ssh_public_key   = local.ssh_public_key
    sshd_hardening   = local.sshd_hardening
    private_cidr     = local.network_cidr
    public_interface = var.public_interface
    hosts_entries    = local.hosts_entries
  })

  depends_on = [hcloud_network_subnet.nodes]
}

# --- Noeuds Kubernetes : AUCUNE IP publique, sortie Internet via le bastion
resource "hcloud_server" "node" {
  for_each = local.nodes

  name               = each.key
  image              = local.image
  server_type        = var.node_server_type
  location           = var.location
  ssh_keys           = [hcloud_ssh_key.lab.id]
  placement_group_id = hcloud_placement_group.nodes.id
  labels             = merge(local.labels, { role = each.value.role })

  public_net {
    ipv4_enabled = false
    ipv6_enabled = false
  }

  network {
    network_id = hcloud_network.lab.id
    ip         = each.value.ip
  }

  user_data = templatefile("${path.module}/templates/node.yaml.tftpl", {
    ssh_public_key  = local.ssh_public_key
    sshd_hardening  = local.sshd_hardening
    node_ip         = each.value.ip
    network_gateway = local.network_gateway
    hosts_entries   = local.hosts_entries
    files = {
      for f in(each.value.role == "cp" ? concat(local.common_node_files, local.common_cp_files) : local.common_node_files) :
      f => local.common_files_b64[f]
    }
  })

  # La route par defaut et le bastion doivent exister avant le premier demarrage (installation des paquets)
  depends_on = [hcloud_network_subnet.nodes, hcloud_network_route.default_via_bastion]
}
