resource "cloudflare_zone_dnssec" "dnssec" {
  for_each = var.zone_dnssec

  zone_id             = data.cloudflare_zone.zone_feature[each.key].zone_id
  status              = try(each.value.status, null)
  dnssec_multi_signer = try(each.value.dnssec_multi_signer, null)
  dnssec_presigned    = try(each.value.dnssec_presigned, null)
  dnssec_use_nsec3    = try(each.value.dnssec_use_nsec3, null)
}
