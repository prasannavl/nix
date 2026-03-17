locals {
  email_routing_rule_flat = flatten([
    for zone_name, config in var.email_routing : [
      for index, rule in try(config.rules, []) : merge(rule, {
        zone_name = zone_name
        tf_key    = "${zone_name}/email-rule/${index}"
      })
    ]
  ])

  email_routing_rules = {
    for rule in local.email_routing_rule_flat : rule.tf_key => rule
  }

  email_routing_catch_alls = {
    for zone_name, config in var.email_routing : zone_name => config.catch_all
    if try(config.catch_all, null) != null
  }
}

resource "cloudflare_email_routing_settings" "email_routing_settings" {
  for_each = {
    for zone_name, config in var.email_routing : zone_name => config
    if try(config.settings, false)
  }

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
}

resource "cloudflare_email_routing_dns" "email_routing_dns" {
  for_each = {
    for zone_name, config in var.email_routing : zone_name => config
    if try(config.dns, false)
  }

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
}

resource "cloudflare_email_routing_rule" "email_routing_rule" {
  for_each = local.email_routing_rules

  zone_id  = data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id
  name     = try(each.value.name, null)
  enabled  = try(each.value.enabled, null)
  priority = try(each.value.priority, null)
  matchers = each.value.matchers
  actions  = each.value.actions
}

resource "cloudflare_email_routing_catch_all" "email_routing_catch_all" {
  for_each = local.email_routing_catch_alls

  zone_id  = data.cloudflare_zone.zone_feature[each.key].zone_id
  name     = try(each.value.name, null)
  enabled  = try(each.value.enabled, null)
  matchers = each.value.matchers
  actions  = each.value.actions
}
