# Firewall applique a l'interface PUBLIQUE du bastion (le seul serveur qui en a une).
# Une seule regle entrante : SSH depuis ton IP. Tout le reste est rejete. Sortant : autorise.
# Pas de regle "interne" : les firewalls Hetzner ne filtrent pas les reseaux prives.
resource "hcloud_firewall" "bastion" {
  name   = "cka-bastion-fw"
  labels = local.labels

  rule {
    description = "SSH administrateur"
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_cidrs
  }
}
