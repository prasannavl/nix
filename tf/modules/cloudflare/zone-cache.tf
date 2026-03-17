resource "cloudflare_tiered_cache" "tiered_cache" {
  for_each = var.tiered_cache

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  value   = each.value
}

resource "cloudflare_regional_tiered_cache" "regional_tiered_cache" {
  for_each = var.regional_tiered_cache

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  value   = each.value
}

resource "cloudflare_zone_cache_reserve" "cache_reserve" {
  for_each = var.zone_cache_reserve

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  value   = each.value
}

resource "cloudflare_zone_cache_variants" "cache_variants" {
  for_each = var.zone_cache_variants

  zone_id = data.cloudflare_zone.zone_feature[each.key].zone_id
  value   = each.value
}
