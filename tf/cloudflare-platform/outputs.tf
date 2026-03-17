output "managed_workers_kv_namespaces" {
  value = module.cloudflare_platform.managed_workers_kv_namespaces
}

output "managed_access_identity_providers" {
  value = module.cloudflare_platform.managed_access_identity_providers
}

output "managed_access_groups" {
  value = module.cloudflare_platform.managed_access_groups
}

output "managed_access_policies" {
  value = module.cloudflare_platform.managed_access_policies
}

output "managed_access_applications" {
  value = module.cloudflare_platform.managed_access_applications
}

output "managed_email_routing_addresses" {
  value = module.cloudflare_platform.managed_email_routing_addresses
}

output "managed_r2_buckets" {
  value = module.cloudflare_platform.managed_r2_buckets
}

output "managed_zone_rulesets" {
  value = module.cloudflare_platform.managed_zone_rulesets
}
