module "gcp_bootstrap" {
  source = "../modules/gcp/bootstrap"

  org_id               = var.org_id
  billing_account_id   = var.billing_account_id
  folder_name          = var.folder_name
  project_name         = var.project_name
  bucket_name          = var.bucket_name
  bucket_location      = var.bucket_location
  service_account_name = var.service_account_name
}
