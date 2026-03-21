locals {
  machine_types = {
    n2d_2cpu_8gb = "n2d-standard-2"
  }
}

resource "google_compute_instance" "vm1" {
  project                   = google_project.dev.project_id
  name                      = "vm1"
  zone                      = var.zone
  machine_type              = local.machine_types.n2d_2cpu_8gb
  tags                      = ["ssh"]
  can_ip_forward            = true
  allow_stopping_for_update = true
  metadata                  = {}
  metadata_startup_script   = "sudo apt update"

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian12.self_link
      size  = 200
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.address_1.address
    }
  }
}
