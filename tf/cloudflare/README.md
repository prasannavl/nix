# Legacy Cloudflare Project

The old monolithic `tf/cloudflare/` project has been replaced by three runnable
projects:

- `tf/cloudflare-dns/`
- `tf/cloudflare-platform/`
- `tf/cloudflare-apps/`

Reusable implementation still lives under `tf/modules/cloudflare/`.

Use these phases instead:

- DNS before host deploy: `./scripts/nixbot-deploy.sh --action tf-dns`
- Platform after host deploy: `./scripts/nixbot-deploy.sh --action tf-platform`
- Workers/apps after host deploy: `./scripts/nixbot-deploy.sh --action tf-apps`
- Full phased flow: `./scripts/nixbot-deploy.sh --action all`

See:

- `tf/README.md`
- `tf/cloudflare-dns/README.md`
- `tf/cloudflare-platform/README.md`
- `tf/cloudflare-apps/README.md`
