variable "org_id" {
  description = "Google Cloud organization ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account to attach to bootstrap-created projects."
  type        = string
}

variable "folder_name" {
  description = "Root folder created under the organization for managed projects."
  type        = string
}

variable "project_name" {
  description = "Control project ID and display name."
  type        = string
}

variable "project_services" {
  description = "Core APIs enabled in the control project."
  type        = set(string)
  default = [
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

variable "bucket_name" {
  description = "GCS bucket name used for shared Terraform state."
  type        = string
}

variable "bucket_location" {
  description = "Location for the shared Terraform state bucket."
  type        = string
}

variable "service_account_name" {
  description = "Account ID for the control service account."
  type        = string
  default     = "tf-control-sa"
}

variable "service_account_display_name" {
  description = "Display name for the control service account."
  type        = string
  default     = "Terraform Control Service Account"
}

variable "service_account_org_roles" {
  description = "Organization-level IAM roles granted to the control service account."
  type        = set(string)
  default = [
    "roles/billing.user",
  ]
}

variable "service_account_folder_roles" {
  description = "Folder-level IAM roles granted on the managed root folder."
  type        = set(string)
  default = [
    "roles/editor",
    "roles/resourcemanager.folderCreator",
    "roles/resourcemanager.projectCreator",
  ]
}

variable "service_account_project_roles" {
  description = "Project-level IAM roles granted on the control project."
  type        = set(string)
  default = [
    "roles/owner",
  ]
}

variable "bucket_force_destroy" {
  description = "Whether the bootstrap state bucket may be destroyed with contents."
  type        = bool
  default     = true
}

variable "bucket_soft_delete_retention_seconds" {
  description = "Soft delete retention for the bootstrap state bucket."
  type        = number
  default     = 7776000
}
