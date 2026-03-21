provider "google" {
  region                      = var.default_region
  zone                        = var.default_zone
  impersonate_service_account = var.impersonate_service_account
}
