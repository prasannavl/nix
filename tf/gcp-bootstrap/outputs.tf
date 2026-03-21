output "folder_id" {
  value = module.gcp_bootstrap.folder_id
}

output "control_project_id" {
  value = module.gcp_bootstrap.control_project_id
}

output "control_service_account_email" {
  value = module.gcp_bootstrap.control_service_account_email
}

output "control_state_bucket_name" {
  value = module.gcp_bootstrap.control_state_bucket_name
}
