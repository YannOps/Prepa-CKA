# Reseau prive : isole par projet, mais NI chiffre NI filtre par les firewalls Hetzner (FAQ officielle).
# La securite repose donc sur l'absence d'IP publique des noeuds : seul le bastion est joignable.
resource "hcloud_network" "lab" {
  name     = "cka-net"
  ip_range = local.network_cidr
  labels   = local.labels
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.lab.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = local.subnet_cidr
}

# Sortie Internet des noeuds (sans IP publique) : tout le trafic externe est route vers le bastion, qui fait le NAT
resource "hcloud_network_route" "default_via_bastion" {
  network_id  = hcloud_network.lab.id
  destination = "0.0.0.0/0"
  gateway     = local.bastion_ip

  depends_on = [hcloud_server.bastion]
}
