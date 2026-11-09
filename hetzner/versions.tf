terraform {
  required_version = ">= 1.5.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.70"
    }
  }
}

# Jeton API : lu dans la variable d'environnement HCLOUD_TOKEN.
# Volontairement AUCUNE variable Terraform pour le jeton : il ne peut donc finir ni dans un .tfvars, ni dans le state.
provider "hcloud" {}
