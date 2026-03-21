resource "google_project" "dev" {
  name            = var.project_name
  project_id      = var.project_id
  folder_id       = var.folder_id
  billing_account = var.billing_account_id
}

resource "google_project_service" "dev" {
  for_each = toset(local.services)

  project                    = google_project.dev.project_id
  disable_dependent_services = true
  disable_on_destroy         = false
  service                    = each.value
}

resource "google_compute_project_metadata" "dev" {
  project = google_project.dev.project_id

  metadata = {
    serial-port-enable = "FALSE"
    enable-oslogin     = "FALSE"
    enable-oslogin-2fa = "FALSE"
    ssh-keys           = "x:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAAsB0nJcxF0wjuzXK0VTF1jbQbT24C1MM8NesCuwBb github_prasannavl"
  }
}
