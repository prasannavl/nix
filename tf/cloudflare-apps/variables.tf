variable "cloudflare_account_id" {
  description = "Cloudflare account ID for account-scoped Workers resources."
  type        = string
  default     = null
  nullable    = true
}

variable "workers" {
  description = "Cloudflare Workers services, versions, routes, and custom domains managed by this stack."
  type        = any
  default     = {}

  validation {
    condition = can(
      alltrue([
        for worker_name, worker in var.workers : (
          (
            (
              contains(keys(worker), "main_module")
              && contains(keys(worker), "modules")
              && length(try(worker.modules, [])) > 0
              && alltrue([
                for module in try(worker.modules, []) : (
                  contains(keys(module), "name")
                  && contains(keys(module), "content_file")
                  && contains(keys(module), "content_type")
                )
              ])
              && contains([for module in try(worker.modules, []) : module.name], worker.main_module)
            )
            || try(worker.assets, null) != null
          )
          && alltrue([
            for route in try(worker.routes, []) : (
              contains(keys(route), "pattern")
              && contains(keys(route), "zone_name")
            )
          ])
          && alltrue([
            for domain in try(worker.custom_domains, []) : (
              contains(keys(domain), "hostname")
              && contains(keys(domain), "zone_name")
            )
          ])
        )
      ])
    )
    error_message = "Each worker must either declare `main_module` plus a non-empty `modules` list with `name`, `content_file`, and `content_type`, or provide `assets` for an assets-only Worker. Any routes or custom domains must include `zone_name`."
  }
}

variable "workers_main" {
  description = "Cloudflare Workers map sourced from main worker tfvars file."
  type        = any
  default     = {}
}

variable "workers_archive" {
  description = "Cloudflare Workers map sourced from archive worker tfvars file."
  type        = any
  default     = {}
}

variable "workers_stage" {
  description = "Cloudflare Workers map sourced from stage worker tfvars file."
  type        = any
  default     = {}
}

variable "secrets" {
  description = "Reusable encrypted values loaded from the secret tfvars file for use across Terraform resources."
  type        = map(string)
  default     = {}
}
