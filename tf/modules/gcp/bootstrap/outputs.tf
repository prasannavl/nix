output "folder_id" {
  description = "Managed folder resource name."
  value       = google_folder.root.name
}

output "control_project_id" {
  description = "Control project ID."
  value       = google_project.control.project_id
}

output "control_service_account_email" {
  description = "Control service account email."
  value       = google_service_account.control.email
}

output "control_state_bucket_name" {
  description = "Control state bucket name."
  value       = google_storage_bucket.control.name
}
