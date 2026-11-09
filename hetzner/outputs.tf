output "bastion_ipv4" {
  description = "IP publique du bastion"
  value       = hcloud_server.bastion.ipv4_address
}

output "nodes" {
  description = "Noeuds Kubernetes : nom => IP privee"
  value       = { for name, n in local.nodes : name => n.ip }
}

output "control_plane" {
  description = "Nom et IP du control-plane"
  value       = { name = local.control_plane.name, ip = local.control_plane.ip }
}

output "node_cidr" {
  description = "Reseau des noeuds (autodetection Calico)"
  value       = local.subnet_cidr
}

output "versions" {
  description = "Versions lues dans common/versions.env"
  value       = local.versions
}
