locals {
  zone_feature_page_rule_zone_names = toset([
    for key, rule in var.page_rules : rule.zone_name
  ])

  zone_feature_ruleset_zone_names = toset([
    for key, ruleset in var.rulesets : ruleset.zone_name
    if try(ruleset.zone_name, null) != null
  ])

  zone_feature_certificate_pack_zone_names = toset([
    for key, pack in var.zone_certificate_packs : pack.zone_name
  ])

  zone_feature_zone_names = toset(flatten([
    keys(var.zone_dnssec),
    keys(var.zone_settings),
    keys(var.zone_security_settings),
    keys(var.zone_universal_ssl_settings),
    keys(var.zone_total_tls),
    keys(var.zone_authenticated_origin_pulls_settings),
    tolist(local.zone_feature_page_rule_zone_names),
    tolist(local.zone_feature_ruleset_zone_names),
    tolist(local.zone_feature_certificate_pack_zone_names),
    keys(var.tiered_cache),
    keys(var.regional_tiered_cache),
    keys(var.zone_cache_reserve),
    keys(var.zone_cache_variants),
    keys(var.email_routing),
  ]))
}

data "cloudflare_zone" "zone_feature" {
  for_each = local.zone_feature_zone_names

  filter = {
    match  = "all"
    name   = each.key
    status = "active"
  }
}
