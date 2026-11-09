variable "admin_cidrs" {
  description = "Adresses autorisees en SSH sur le bastion (ton IP publique en /32). Renseigne par cka-hetzner.sh."
  type        = list(string)

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs doit contenir au moins un CIDR IPv4 valide, ex. [\"203.0.113.7/32\"]."
  }
  validation {
    condition     = !anytrue([for c in var.admin_cidrs : endswith(c, "/0")])
    error_message = "SSH ouvert a tout Internet refuse : indique ton IP publique en /32."
  }
}

variable "location" {
  description = "Emplacement Hetzner (fsn1, nbg1, hel1 : zone reseau eu-central)."
  type        = string
  default     = "fsn1"
}

variable "network_zone" {
  description = "Zone du reseau prive, doit contenir var.location."
  type        = string
  default     = "eu-central"
}

variable "bastion_server_type" {
  description = "Type du bastion (point d'entree SSH + NAT sortant)."
  type        = string
  default     = "cpx12"
}

variable "node_server_type" {
  description = "Type des noeuds Kubernetes (kubeadm exige 2 vCPU / 2 Go pour le control-plane)."
  type        = string
  default     = "cpx22"
}

variable "ssh_public_key_path" {
  description = "Cle publique du lab, generee par cka-hetzner.sh (la cle privee ne quitte jamais le poste)."
  type        = string
  default     = "ssh/cka_lab_ed25519.pub"
}

variable "public_interface" {
  description = "Interface publique du bastion sur les images Ubuntu Hetzner."
  type        = string
  default     = "eth0"
}
