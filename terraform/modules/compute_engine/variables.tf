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
  default     = "cos-cloud/cos-stable"
}

variable "boot_disk_size" {
  description = "Size of the Compute Engine instance"
  type        = string
  default     = "20"
}

variable "static_ip_address" {
  description = "Static IP address of the Compute Engine instance"
  type        = string
  default     = ""
}

variable "startup_script" {
  description = "Startup script of the Compute Engine instance"
  type        = string
  default     = " #! /bin/bash\n docker images \"europe-west1-docker.pkg.dev/fluid-417204/fluid-droplets/fluid-droplet-dynamic-bundle-rails/web\" --format \"{{.ID}}\" | tail -n +2 | xargs -r docker rmi -f"
}

variable "email_service_account" {
  description = "Email of the service account"
  type        = string
}

# variable module container

variable "container_image" {
  description = "Image of the container"
  type        = string
  default     = "europe-west1-docker.pkg.dev/fluid-417204/fluid-droplets/fluid-droplet-dynamic-bundle-rails/web:latest"
}

variable "container_rails_master_key" {
  description = "Rails master key"
  type        = string
}

variable "container_db_url_production" {
  description = "DB production data"
  type        = string
  default     = ""
}

variable "container_db_url_production_queue" {
  description = "DB production queue"
  type        = string
  default     = ""
}

variable "container_db_url_production_cache" {
  description = "DB production cache"
  type        = string
  default     = ""
}

variable "container_db_url_production_cable" {
  description = "DB production cable"
  type        = string
  default     = ""
}

variable "network_tier" {
  description = "Network tier"
  type        = string
  default     = "STANDARD"
}

