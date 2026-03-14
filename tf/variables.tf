variable "zones" {
  description = "Cloudflare zones and their authoritative public-safe DNS records."
  type = any

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

variable "secret_zones" {
  description = "Cloudflare zones and authoritative DNS records whose values should stay encrypted in-repo until apply."
  type = any
  default = {}

  validation {
    condition = can(
      alltrue(flatten([
        for zone_name, zone in var.secret_zones : [
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
    error_message = "Each secret DNS record must include `name`, `type`, and either `content` or `data`."
  }
}

variable "secrets" {
  description = "Reusable encrypted values loaded from the secret tfvars file for use across Terraform resources."
  type        = map(string)
  default     = {}
}
