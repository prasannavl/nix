variable "control_project_id" {
  description = "Bootstrap-created control project ID used to locate the managed folder."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account attached to managed projects."
  type        = string
}

variable "default_region" {
  description = "Default region for project resources."
  type        = string
}

variable "default_zone" {
  description = "Default zone for zonal resources."
  type        = string
}

variable "impersonate_service_account" {
  description = "Service account email used by Terraform for normal control-plane operation."
  type        = string
  default     = null
}

variable "dev_project_id" {
  description = "Dev Google Cloud project ID."
  type        = string
}

variable "dev_project_name" {
  description = "Dev Google Cloud project display name."
  type        = string
}
