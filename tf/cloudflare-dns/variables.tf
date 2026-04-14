variable "cloudflare_account_id" {
  description = "Optional account ID accepted so provider-level Cloudflare tfvars can be shared across all Cloudflare projects."
  type        = string
  default     = null
  nullable    = true
}

variable "secrets" {
  description = "Optional shared encrypted values accepted so provider-level Cloudflare tfvars can be shared across all Cloudflare projects."
  type        = map(string)
  default     = {}
}

variable "zones" {
  description = "Cloudflare zones and their authoritative public-safe DNS records."
  type        = any

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.zones : [
          for record in try(zone.records, []) : (
            contains(keys(record), "key")
            && contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each DNS record must include `key`, `name`, `type`, and either `content` or `data`."
  }
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
            contains(keys(record), "key")
            && contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each main secret DNS record must include `key`, `name`, `type`, and either `content` or `data`."
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
            contains(keys(record), "key")
            && contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each staging secret DNS record must include `key`, `name`, `type`, and either `content` or `data`."
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
            contains(keys(record), "key")
            && contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each archived secret DNS record must include `key`, `name`, `type`, and either `content` or `data`."
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
            contains(keys(record), "key")
            && contains(keys(record), "name")
            && contains(keys(record), "type")
            && (
              contains(keys(record), "content")
              || contains(keys(record), "data")
            )
          )
        ]
      ]))
    )
    error_message = "Each inactive secret DNS record must include `key`, `name`, `type`, and either `content` or `data`."
  }
}
