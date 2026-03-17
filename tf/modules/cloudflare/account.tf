resource "cloudflare_workers_kv_namespace" "namespace" {
  for_each = var.workers_kv_namespaces

  account_id = var.cloudflare_account_id
  title      = try(each.value.title, each.key)
}

resource "cloudflare_email_routing_address" "address" {
  for_each = var.email_routing_addresses

  account_id = var.cloudflare_account_id
  email      = each.key
}

output "managed_workers_kv_namespaces" {
  value = {
    for key, namespace in cloudflare_workers_kv_namespace.namespace : key => {
      id    = namespace.id
      title = namespace.title
    }
  }
}

output "managed_email_routing_addresses" {
  value = {
    for email, address in cloudflare_email_routing_address.address : email => {
      id       = address.id
      verified = address.verified
    }
  }
}
