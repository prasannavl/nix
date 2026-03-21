resource "google_folder" "root" {
  display_name = var.folder_name
  parent       = "organizations/${var.org_id}"
}

resource "google_project" "control" {
  name            = var.project_name
  project_id      = var.project_name
  folder_id       = google_folder.root.name
  billing_account = var.billing_account_id
}

resource "google_project_service" "control" {
  for_each = var.project_services

  project                    = google_project.control.project_id
  disable_dependent_services = true
  disable_on_destroy         = true
  service                    = each.value
}

resource "google_service_account" "control" {
  account_id   = var.service_account_name
  display_name = var.service_account_display_name
  project      = google_project.control.project_id
}

resource "google_organization_iam_binding" "control" {
  for_each = var.service_account_org_roles

  org_id = var.org_id
  role   = each.value

  members = [
    "serviceAccount:${google_service_account.control.email}",
  ]
}

resource "google_folder_iam_binding" "root" {
  for_each = var.service_account_folder_roles

  folder = google_folder.root.name
  role   = each.value

  members = [
    "serviceAccount:${google_service_account.control.email}",
  ]
}

resource "google_project_iam_binding" "control" {
  for_each = var.service_account_project_roles

  project = google_project.control.project_id
  role    = each.value

  members = [
    "serviceAccount:${google_service_account.control.email}",
  ]
}

resource "google_storage_bucket" "control" {
  name          = var.bucket_name
  location      = var.bucket_location
  force_destroy = var.bucket_force_destroy
  project       = google_project.control.project_id

  uniform_bucket_level_access = true

  soft_delete_policy {
    retention_duration_seconds = var.bucket_soft_delete_retention_seconds
  }
}
