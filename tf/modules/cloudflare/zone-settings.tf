locals {
  zone_settings_flat = flatten([
    for zone_name, config in var.zone_settings : [
      for setting in try(config.settings, []) : merge(setting, {
        zone_name = zone_name
        tf_key    = "${zone_name}/${setting.setting_id}"
      })
    ]
  ])

  zone_settings_by_key = {
    for setting in local.zone_settings_flat : setting.tf_key => setting
  }
}

resource "cloudflare_zone_setting" "general_setting" {
  for_each = local.zone_settings_by_key

  zone_id    = data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id
  setting_id = each.value.setting_id
  value      = each.value.value
}
