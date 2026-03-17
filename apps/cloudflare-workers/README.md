# Cloudflare Workers

This directory holds repo-managed Cloudflare Worker source trees.

The Terraform stack under `tf/` is the control plane. Worker code lives here and
is referenced from `tf/cloudflare-apps/workers.auto.tfvars` or encrypted tfvars
files under `data/secrets/tf/cloudflare/workers/`.

Recommended layout:

- `apps/cloudflare-workers/<worker>/src/index.js`
- `apps/cloudflare-workers/<worker>/public/` for optional static assets
- `apps/cloudflare-workers/<worker>/assets/` for assets-only Workers managed
  through Cloudflare Static Assets

Minimal `tf/cloudflare-apps/workers.auto.tfvars` example:

```hcl
workers = {
  example-worker = {
    compatibility_date = "2026-03-15"
    main_module        = "src/index.js"

    modules = [
      {
        name         = "src/index.js"
        content_file = "../apps/cloudflare-workers/example-worker/src/index.js"
        content_type = "application/javascript+module"
      }
    ]

    routes = [
      {
        zone_name = "example.com"
        pattern   = "example.com/api/*"
      }
    ]

    custom_domains = [
      {
        zone_name = "example.com"
        hostname  = "worker.example.com"
      }
    ]

    bindings = [
      {
        name = "ENV"
        type = "plain_text"
        text = "prod"
      },
      {
        name = "API_TOKEN"
        type = "secret_text"
        text = "load-from-encrypted-tfvars-instead"
      }
    ]
  }
}
```

For sensitive values, keep the worker definition in a `*.tfvars.age` file under
`data/secrets/tf/cloudflare/workers/` and let
`scripts/nixbot-deploy.sh --action tf-apps` decrypt it at runtime.

Assets-only Workers are also supported. In that case the Worker definition can
omit modules and provide only:

```hcl
workers = {
  static-site = {
    compatibility_date = "2026-03-15"
    assets = {
      directory = "../apps/cloudflare-workers/static-site/assets"
      config = {
        run_worker_first = false
      }
    }
  }
}
```

If you want a reproducible pre-deploy build, expose the built asset directory as
a Nix package and sync that output back into the local worker `dist/` directory
before running `scripts/nixbot-deploy.sh --action tf-apps`.
