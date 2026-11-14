variable "cloudflare_account_id" {
  description = "Cloudflare account ID for account-scoped Workers resources."
  type        = string
  default     = null
  nullable    = true
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
  description = "Cloudflare Zero Trust Access applications and their inline or reusable policy attachments managed at the account level."
  type        = any
  default     = {}
}

variable "workers_kv_namespaces" {
  description = "Cloudflare Workers KV namespaces managed at the account level."
  type        = any
  default     = {}
}

variable "tunnels" {
  description = "Cloudflare Zero Trust cloudflared tunnels keyed by a stable Terraform key."
  type        = any
  default     = {}
}

variable "tunnel_configs" {
  description = "Cloudflare Zero Trust cloudflared tunnel configurations keyed by tunnel key."
  type        = any
  default     = {}
}

variable "tunnel_routes" {
  description = "Cloudflare Zero Trust private network routes keyed by tunnel key, each containing a list of CIDR routes."
  type        = any
  default     = {}
}

variable "r2_buckets" {
  description = "Cloudflare R2 buckets and related bucket-level configuration."
  type        = any
  default     = {}

  validation {
    condition = try(
      alltrue([
        for bucket_name, bucket in var.r2_buckets : (
          alltrue([
            for domain in try(bucket.custom_domains, []) : (
              contains(keys(domain), "key")
              && contains(keys(domain), "domain")
              && contains(keys(domain), "zone_name")
              && contains(keys(domain), "enabled")
            )
          ])
          && alltrue([
            for notification in try(bucket.event_notifications, []) : (
              contains(keys(notification), "key")
              && contains(keys(notification), "queue_id")
              && contains(keys(notification), "rules")
            )
          ])
          && length(distinct([
            for domain in try(bucket.custom_domains, []) : domain.key
          ])) == length(try(bucket.custom_domains, []))
          && length(distinct([
            for notification in try(bucket.event_notifications, []) : notification.key
          ])) == length(try(bucket.event_notifications, []))
        )
      ]),
      false
    )
    error_message = "R2 custom domains and event notifications must include stable `key` values, unique within each list per bucket. Custom domains also require `domain`, `zone_name`, and `enabled`; event notifications require `queue_id` and `rules`."
  }
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

  validation {
    condition = try(
      alltrue([
        for zone_name, config in var.email_routing : (
          alltrue([
            for rule in try(config.rules, []) : (
              contains(keys(rule), "key")
              && contains(keys(rule), "matchers")
              && contains(keys(rule), "actions")
            )
          ])
          && length(distinct([for rule in try(config.rules, []) : rule.key])) == length(try(config.rules, []))
        )
      ]),
      false
    )
    error_message = "Email routing rules must include stable `key` values, unique per zone, plus `matchers` and `actions`."
  }
}

variable "secrets" {
  description = "Reusable encrypted values loaded from the secret tfvars file for use across Terraform resources."
  type        = map(string)
  default     = {}
}
