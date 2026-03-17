variable "zones" {
  description = "Cloudflare zones and their authoritative public-safe DNS records."
  type        = any

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.zones : [
          for record in try(zone.records, []) : (
            contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

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

variable "workers_kv_namespaces" {
  description = "Cloudflare Workers KV namespaces managed at the account level."
  type        = any
  default     = {}
}

variable "access_identity_providers" {
  description = "Cloudflare Zero Trust Access identity providers managed at the account level."
  type        = any
  default     = {}
}

variable "access_groups" {
  description = "Cloudflare Zero Trust Access groups managed at the account level."
  type        = any
  default     = {}
}

variable "access_policies" {
  description = "Cloudflare Zero Trust Access reusable policies managed at the account level."
  type        = any
  default     = {}
}

variable "access_applications" {
  description = "Cloudflare Zero Trust Access applications and their policy attachments managed at the account level."
  type        = any
  default     = {}
}

variable "r2_buckets" {
  description = "Cloudflare R2 buckets and related bucket-level configuration."
  type        = any
  default     = {}
}

variable "zone_dnssec" {
  description = "Cloudflare DNSSEC configuration keyed by zone name."
  type        = any
  default     = {}
}

variable "zone_settings" {
  description = "Cloudflare zone settings keyed by zone name, each with a `settings` list of `{ setting_id, value }`."
  type        = any
  default     = {}
}

variable "zone_security_settings" {
  description = "Cloudflare SSL/TLS and related security-oriented zone settings keyed by zone name, each with a `settings` list of `{ setting_id, value }`."
  type        = any
  default     = {}
}

variable "zone_certificate_packs" {
  description = "Advanced certificate packs keyed by an arbitrary Terraform key, each with `zone_name`, `type`, `certificate_authority`, `validation_method`, and `validity_days`."
  type        = any
  default     = {}
}

variable "zone_universal_ssl_settings" {
  description = "Universal SSL overrides keyed by zone name. Only set zones whose value differs from Cloudflare defaults."
  type        = map(bool)
  default     = {}
}

variable "zone_total_tls" {
  description = "Total TLS overrides keyed by zone name."
  type        = any
  default     = {}
}

variable "zone_authenticated_origin_pulls_settings" {
  description = "Authenticated Origin Pulls overrides keyed by zone name."
  type        = map(bool)
  default     = {}
}

variable "rulesets" {
  description = "Cloudflare rulesets keyed by an arbitrary Terraform key. Set `zone_name` for zone-scoped rulesets, otherwise they are account-scoped."
  type        = any
  default     = {}
}

variable "page_rules" {
  description = "Legacy Cloudflare page rules keyed by an arbitrary Terraform key."
  type        = any
  default     = {}
}

variable "tiered_cache" {
  description = "Cloudflare Smart Tiered Cache setting keyed by zone name (`on` or `off`)."
  type        = map(string)
  default     = {}
}

variable "regional_tiered_cache" {
  description = "Cloudflare Regional Tiered Cache setting keyed by zone name (`on` or `off`)."
  type        = map(string)
  default     = {}
}

variable "zone_cache_reserve" {
  description = "Cloudflare Cache Reserve setting keyed by zone name (`on` or `off`)."
  type        = map(string)
  default     = {}
}

variable "zone_cache_variants" {
  description = "Cloudflare cache variants keyed by zone name."
  type        = any
  default     = {}
}

variable "email_routing_addresses" {
  description = "Cloudflare Email Routing destination addresses, keyed by email value."
  type        = set(string)
  default     = []
}

variable "email_routing" {
  description = "Cloudflare Email Routing zone configuration keyed by zone name."
  type        = any
  default     = {}
}

variable "secret_zones_main" {
  description = "Cloudflare zones and authoritative main DNS records whose values should stay encrypted in-repo until apply."
  type        = any
  default     = {}

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.secret_zones_main : [
          for record in try(zone.records, []) : (
            contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each main secret DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

variable "secret_zones_stage" {
  description = "Cloudflare zones and authoritative staging DNS records whose values should stay encrypted in-repo until apply."
  type        = any
  default     = {}

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.secret_zones_stage : [
          for record in try(zone.records, []) : (
            contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each staging secret DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

variable "secret_zones_archive" {
  description = "Cloudflare zones and authoritative archived DNS records whose values should stay encrypted in-repo until apply."
  type        = any
  default     = {}

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.secret_zones_archive : [
          for record in try(zone.records, []) : (
            contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each archived secret DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

variable "secret_zones_inactive" {
  description = "Cloudflare zones and authoritative inactive DNS records whose values should stay encrypted in-repo until apply."
  type        = any
  default     = {}

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.secret_zones_inactive : [
          for record in try(zone.records, []) : (
            contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each inactive secret DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

variable "secrets" {
  description = "Reusable encrypted values loaded from the secret tfvars file for use across Terraform resources."
  type        = map(string)
  default     = {}
}
