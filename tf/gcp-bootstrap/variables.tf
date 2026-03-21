variable "org_id" {
  description = "Google Cloud organization ID."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account used for the control project."
  type        = string
}

variable "folder_name" {
  description = "Managed root folder name."
  type        = string
}

variable "project_name" {
  description = "Control project ID and display name."
  type        = string
}

variable "bucket_name" {
  description = "Shared Terraform state bucket name."
  type        = string
}

variable "bucket_location" {
  description = "Shared Terraform state bucket location."
  type        = string
}

variable "service_account_name" {
  description = "Control service account ID."
  type        = string
  default     = "tf-control-sa"
}
