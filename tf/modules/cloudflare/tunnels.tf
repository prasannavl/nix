locals {
  tunnel_routes_flat = {
    for route in flatten([
      for tunnel_key, route_group in var.tunnel_routes : [
        for route in try(route_group.routes, []) : {
          key                = format("%s/%s", tunnel_key, route.network)
          tunnel_key         = tunnel_key
          network            = route.network
          comment            = try(route.comment, null)
          virtual_network_id = try(route.virtual_network_id, null)
        }
      ]
    ]) : route.key => route
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "tunnel" {
  for_each = var.tunnels

  account_id    = var.cloudflare_account_id
  name          = try(each.value.name, each.key)
  tunnel_secret = try(each.value.tunnel_secret, try(each.value.secret, null))
  config_src    = try(each.value.config_src, "cloudflare")
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "config" {
  for_each = var.tunnel_configs

  account_id = var.cloudflare_account_id
  tunnel_id = try(
    cloudflare_zero_trust_tunnel_cloudflared.tunnel[each.key].id,
    each.value.tunnel_id,
  )

  config = each.value.config
}

resource "cloudflare_zero_trust_tunnel_cloudflared_route" "route" {
  for_each = local.tunnel_routes_flat

  account_id = var.cloudflare_account_id
  tunnel_id = try(
    cloudflare_zero_trust_tunnel_cloudflared.tunnel[each.value.tunnel_key].id,
    try(var.tunnel_routes[each.value.tunnel_key].tunnel_id, null),
  )
  network            = each.value.network
  comment            = each.value.comment
  virtual_network_id = each.value.virtual_network_id
}

output "managed_tunnels" {
  value = {
    for key, tunnel in cloudflare_zero_trust_tunnel_cloudflared.tunnel : key => {
      id         = tunnel.id
      name       = tunnel.name
      account_id = tunnel.account_id
    }
  }
}

output "managed_tunnel_configs" {
  value = {
    for key, tunnel_config in cloudflare_zero_trust_tunnel_cloudflared_config.config : key => {
      id        = tunnel_config.id
      tunnel_id = tunnel_config.tunnel_id
    }
  }
}

output "managed_tunnel_routes" {
  value = {
    for key, route in cloudflare_zero_trust_tunnel_cloudflared_route.route : key => {
      id                 = route.id
      tunnel_id          = route.tunnel_id
      network            = route.network
      virtual_network_id = try(route.virtual_network_id, null)
      comment            = try(route.comment, null)
    }
  }
}
