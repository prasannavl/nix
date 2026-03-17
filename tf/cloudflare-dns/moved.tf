moved {
  from = cloudflare_dns_record.record
  to   = module.cloudflare_dns.cloudflare_dns_record.record
}

moved {
  from = data.cloudflare_zone.zone
  to   = module.cloudflare_dns.data.cloudflare_zone.zone
}
