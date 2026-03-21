data "google_projects" "control" {
  filter = "id:${var.control_project_id}"
}

locals {
  folder_id = data.google_projects.control.projects[0].parent.id
}

module "dev" {
  source = "../modules/gcp/project-dev"

  project_id         = var.dev_project_id
  project_name       = var.dev_project_name
  folder_id          = local.folder_id
  billing_account_id = var.billing_account_id
  region             = var.default_region
  zone               = var.default_zone
}
