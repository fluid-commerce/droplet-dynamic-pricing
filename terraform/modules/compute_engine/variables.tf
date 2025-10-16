# Define map variables compute engine

variable "vm_name" {
  description = "Name of the Compute Engine instance"
  type        = string
}

variable "machine_type" {
  description = "Machine type of the Compute Engine instance"
  type        = string
}

variable "zone" {
  description = "Zone of the Compute Engine instance"
  type        = string
}

variable "environment" {
  description = "Environment of the Compute Engine instance"
  type        = string
}

variable "project" {
  description = "Project of the Compute Engine instance"
  type        = string
}

variable "purpose_compute_engine" {
  description = "Purpose of the Compute Engine instance"
  type        = string
}

variable "boot_disk_image" {
  description = "Image of the Compute Engine instance"
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "boot_disk_size" {
  description = "Size of the Compute Engine instance"
  type        = string
  default     = "20"
}

variable "startup_script" {
  description = "Startup script of the Compute Engine instance"
  type        = string
  default     = " #! /bin/bash\n docker images \"europe-west1-docker.pkg.dev/fluid-417204/fluid-droplets/fluid-droplet-dynamic-pricing-rails/web\" --format \"{{.ID}}\" | tail -n +2 | xargs -r docker rmi -f"
}

variable "email_service_account" {
  description = "Email of the service account"
  type        = string
}
# variable "network_tier" {
#   description = "Network tier"
#   type        = string
#   default     = "STANDARD"
# }

