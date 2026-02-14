# fluid droplet template production
# project variables
project_id = "PROJECT_ID"
region     = "europe-west1"

# compute engine variables for jobs console
vm_name      = "fluid-droplet-template-jobs-console"
machine_type = "e2-small"
zone         = "europe-west1-b"

# labels for the instance
environment            = "production"
purpose_compute_engine = "jobs"
project                = "fluid-droplet-template"

# service account email to compute engine
email_service_account = "YOUR_SERVICE_ACCOUNT_EMAIL"

# variable module container
#master key
container_rails_master_key        = "YOUR_MASTER_KEY"
container_image                   = "europe-west1-docker.pkg.dev/PROJECT_ID/fluid-droplets/fluid-droplet-template-rails/web:latest"
container_db_url_production       = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production?host="
container_db_url_production_queue = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_queue?host="
container_db_url_production_cache = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_cache?host="
container_db_url_production_cable = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_cable?host="

# cloud_run fluid droplet shiphero
cloud_run_app_name = "fluid-droplet-template"
vpc_network_cloud_run = "fluid-egress-vpc"
vpc_subnet_cloud_run = "fluid-egress-vpc"

cloud_sql_instances_cloud_run = [
  "PROJECT_ID:europe-west1:fluid-droplet-template"
]
environment_variables_cloud_run = {
  "CABLE_DATABASE_URL"  = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_cable?host=/cloudsql/PROJECT_ID:europe-west1:fluid-droplet-template",
  "CACHE_DATABASE_URL"  = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_cache?host=/cloudsql/PROJECT_ID:europe-west1:fluid-droplet-template",
  "DATABASE_URL"        = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production?host=/cloudsql/PROJECT_ID:europe-west1:fluid-droplet-template",
  "QUEUE_DATABASE_URL"  = "postgresql://template_production_user:YOUR_PASSWORD@localhost/fluid_droplet_template_production_queue?host=/cloudsql/PROJECT_ID:europe-west1:fluid-droplet-template",
  "RACK_ENV"            = "production",
  "RAILS_ENV"           = "production",
  "RAILS_LOG_TO_STDOUT" = "enabled",
  "RAILS_MASTER_KEY"    = "YOUR_MASTER_KEY",
  "SENTRY_DSN"          = "https://1f9df1b5771c72f4957124899ef29b50@o553113.ingest.us.sentry.io/4510556532899840"
}

# Postgres variables
postgres_user_name = "template_production_user"
postgres_password_production_user = "YOUR_PASSWORD"
postgres_name_instance = "fluid-droplet-template"
postgres_name_database = "fluid_droplet_template_production"
postgres_ip_public_database = false
postgres_private_network = "projects/PROJECT_ID/global/networks/fluid-egress-vpc"


# cloud run migrations
cloud_run_migrations_name = "fluid-droplet-template-migrations"