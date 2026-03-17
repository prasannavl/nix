resource "cloudflare_ruleset" "ruleset" {
  for_each = var.rulesets

  account_id  = try(each.value.zone_name, null) == null ? var.cloudflare_account_id : null
  zone_id     = try(each.value.zone_name, null) != null ? data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id : null
  name        = each.value.name
  description = try(each.value.description, null)
  kind        = each.value.kind
  phase       = each.value.phase
  rules       = try(each.value.rules, null)

  lifecycle {
    precondition {
      condition = (
        try(each.value.zone_name, null) != null
        || (
          var.cloudflare_account_id != null
          && trimspace(var.cloudflare_account_id) != ""
        )
      )
      error_message = "Account-level rulesets require `cloudflare_account_id`; zone-level rulesets require `zone_name`."
    }
  }
}

resource "cloudflare_page_rule" "page_rule" {
  for_each = var.page_rules

  zone_id  = data.cloudflare_zone.zone_feature[each.value.zone_name].zone_id
  target   = each.value.target
  actions  = each.value.actions
  priority = try(each.value.priority, null)
  status   = try(each.value.status, null)
}

output "managed_zone_rulesets" {
  value = {
    for key, ruleset in cloudflare_ruleset.ruleset : key => {
      id    = ruleset.id
      kind  = ruleset.kind
      phase = ruleset.phase
      zone  = try(var.rulesets[key].zone_name, null)
    }
  }
}
