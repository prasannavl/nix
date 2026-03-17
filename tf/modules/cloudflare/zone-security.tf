locals {
  zone_security_settings_flat = flatten([
    for zone_name, config in var.zone_security_settings : [
      for setting in try(config.settings, []) : merge(setting, {
        zone_name = zone_name
        tf_key    = "${zone_name}/${setting.setting_id}"
      })
    ]
  ])

  zone_security_settings_by_key = {
    for setting in local.zone_security_settings_flat : setting.tf_key => setting
  }
}

resource "cloudflare_zone_setting" "security_setting" {
  for_each = local.zone_security_settings_by_key

  zone_id    = data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id
  setting_id = each.value.setting_id
  value      = each.value.value
}

resource "cloudflare_certificate_pack" "certificate_pack" {
  for_each = var.zone_certificate_packs

  zone_id               = data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id
  type                  = each.value.type
  hosts                 = try(each.value.hosts, null)
  validation_method     = each.value.validation_method
  validity_days         = each.value.validity_days
  certificate_authority = each.value.certificate_authority
  cloudflare_branding   = try(each.value.cloudflare_branding, null)
}

resource "cloudflare_universal_ssl_setting" "universal_ssl" {
  for_each = var.zone_universal_ssl_settings

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  enabled = each.value
}

resource "cloudflare_total_tls" "total_tls" {
  for_each = var.zone_total_tls

  zone_id               = data.cloudflare_zone.zone_feature[each.key].zone_id
  enabled               = each.value.enabled
  certificate_authority = try(each.value.certificate_authority, null)
}

resource "cloudflare_authenticated_origin_pulls_settings" "authenticated_origin_pulls" {
  for_each = var.zone_authenticated_origin_pulls_settings

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  enabled = each.value
}
