resource "google_compute_network" "main" {
  name                    = "main"
  auto_create_subnetworks = false
  project                 = google_project.dev.project_id
}

resource "google_compute_subnetwork" "main" {
  name          = "main"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.main.id
  region        = var.region
  project       = google_project.dev.project_id
}

resource "google_compute_address" "address_1" {
  name    = "address-1"
  region  = var.region
  project = google_project.dev.project_id
}
