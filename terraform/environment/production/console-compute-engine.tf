
# Compute Engine instance Jobs
module "rails_console" {
  source = "../../modules/compute_engine"

  vm_name                = var.vm_name
  machine_type           = var.machine_type
  zone                   = var.zone
  environment            = var.environment
  project                = var.project
  purpose_compute_engine = var.purpose_compute_engine

  boot_disk_image = "ubuntu-os-cloud/ubuntu-2404-lts"

  email_service_account = var.email_service_account

  # Depends on
  depends_on = [
    google_sql_database.database_production,
    google_sql_database.database_production_queue,
    google_sql_database.database_production_cache,
    google_sql_database.database_production_cable,
    google_sql_user.users
  ]
}

