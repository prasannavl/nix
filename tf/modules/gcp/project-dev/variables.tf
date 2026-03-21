variable "project_id" {
  description = "Google Cloud project ID."
  type        = string
}

variable "project_name" {
  description = "Google Cloud project display name."
  type        = string
}

variable "folder_id" {
  description = "Folder resource name under which the project will be created."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account attached to the project."
  type        = string
}

variable "region" {
  description = "Default region for regional resources."
  type        = string
}

variable "zone" {
  description = "Default zone for zonal resources."
  type        = string
}
