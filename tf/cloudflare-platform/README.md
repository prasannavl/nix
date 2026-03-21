# OpenTofu Cloudflare Platform

This project manages non-app Cloudflare infrastructure that is safe to run
outside the host build itself.

Scope:

- account metadata like KV namespaces, Email Routing destination addresses, and
  Zero Trust Access
- Zero Trust cloudflared tunnels, their configs, and private network routes
- R2 buckets
- zone DNSSEC
- zone settings, security, rules, cache, and Email Routing

Tunnel inputs:

- `tunnels`: map of cloudflared tunnel definitions keyed by stable Terraform key
- `tunnel_configs`: map keyed by tunnel key with a `config` object
- `tunnel_routes`: map keyed by tunnel key with `routes = [{ network, ... }]`

Example shape:

```hcl
tunnels = {
  edge = {
    name = "edge"
  }
}

tunnel_configs = {
  edge = {
    config = {
      ingress = [
        {
          hostname = "app.example.com"
          service  = "http://localhost:3000"
        },
        {
          service = "http_status:404"
        }
      ]
    }
  }
}

tunnel_routes = {
  edge = {
    routes = [
      {
        network = "10.10.0.0/16"
        comment = "internal"
      }
    ]
  }
}
```

Import existing resources:

- Tunnel:
  `tofu import 'module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared.tunnel["edge"]' '<account_id>/<tunnel_id>'`
- Config:
  `tofu import 'module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_config.config["edge"]' '<account_id>/<tunnel_id>'`
- Route:
  `tofu import 'module.cloudflare_platform.cloudflare_zero_trust_tunnel_cloudflared_route.route["edge/10.10.0.0/16"]' '<account_id>/<route_id>'`

Runtime:

- `./scripts/nixbot-deploy.sh --action tf-platform`
- default state key: `cloudflare-platform/terraform.tfstate`

Inputs live in this directory's `*.auto.tfvars` files plus encrypted inputs
under `data/secrets/tf/cloudflare/` and `data/secrets/tf/cloudflare-platform/`.

When tunnel details should remain private, keep
`tf/cloudflare-platform/tunnels.auto.tfvars` empty and supply `tunnels`,
`tunnel_configs`, and `tunnel_routes` from the encrypted tunnel tfvars under
`data/secrets/tf/cloudflare-platform/`.
