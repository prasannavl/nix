resource "google_compute_firewall" "ssh" {
  name          = "allow-22"
  network       = google_compute_network.main.id
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["ssh"]
  project       = google_project.dev.project_id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}
