# DNS (Terraform / OpenTofu)

## Scope

- Apply these rules when editing `*.tfvars` or `*.tf` files that define DNS
  records, and when advising on DNS changes.

## Record keys

- Every DNS record object must include a stable `key`.
- Terraform addressing for DNS records is `zone/key`, not array position.
- Pick semantic keys that will stay valid through routine edits, for example
  `www-cname`, `mx-mailgun-mxa`, or `spf-txt`.
- Avoid content-derived keys for mutable records such as `A`, `AAAA`, `MX`, and
  verification records. Prefer durable slot or purpose names such as `apex-a-1`,
  `apex-mx-1`, `www-cname`, or `dmarc-txt`.
- `key` must be unique within the zone across all merged DNS inputs.

## Record list ordering

- Record order is no longer part of Terraform identity.
- Keep lists readable, but do not rely on position for safety.
- Reordering should still be intentional because it affects diff readability,
  but it should not trigger resource replacement by itself.

## Record structure

Each record in the `records` list is an HCL object. Required fields:

- `key` -- stable Terraform identity within the zone
- `name` -- subdomain label (e.g., `"docs"`, `"@"` for apex, `"sub.x"` for
  nested)
- `type` -- DNS record type in upper case (`"CNAME"`, `"A"`, `"MX"`, `"TXT"`,
  etc.)
- `content` or `data` -- record value (use `content` for most types; `data` for
  structured types like `SRV`)

Common optional fields:

- `ttl` -- time-to-live; `1` means "automatic" in Cloudflare
- `proxied` -- `true` to route through Cloudflare's proxy (orange cloud);
  required `true` for tunnel CNAMEs, typically `false` for MX/TXT/non-HTTP
- `priority` -- required for `MX` records
- `comment`, `tags` -- metadata

## Wiring patterns

### CNAME to a Cloudflare Tunnel

Point a hostname at a tunnel by creating a proxied CNAME whose content is
`<tunnel-id>.cfargotunnel.com`:

```hcl
{
  content = "<tunnel-uuid>.cfargotunnel.com"
  name    = "<subdomain>"
  proxied = true
  ttl     = 1
  type    = "CNAME"
}
```

- The tunnel must already exist (imported or created via the platform phase).
- `proxied = true` is mandatory -- Cloudflare tunnels require the orange-cloud
  proxy.

### CNAME to an external service

```hcl
{
  content = "target.example.com"
  name    = "<subdomain>"
  proxied = false
  ttl     = 1
  type    = "CNAME"
}
```

- Set `proxied = false` for services that handle their own TLS or for
  verification CNAMEs (DKIM, domain connect, etc.).

### A record (direct IP)

```hcl
{
  content = "1.2.3.4"
  name    = "@"
  proxied = false
  ttl     = 1
  type    = "A"
}
```

- Multiple A records on the same name are valid (round-robin).

### MX record

```hcl
{
  content  = "mx.example.com"
  name     = "@"
  priority = 10
  ttl      = 1
  type     = "MX"
}
```

- MX records are never proxied.
- Lower `priority` values are preferred by sending mail servers.

### TXT record

```hcl
{
  content = "v=spf1 include:example.com ~all"
  name    = "@"
  ttl     = 1
  type    = "TXT"
}
```

- Used for SPF, DKIM, DMARC, domain verification, etc.
- Never proxied.

## Where records live

- DNS records are defined in secret tfvars files consumed by the
  `cloudflare-dns` Terraform project.
- Records are split across project files by lifecycle tier (main, stage,
  archive, inactive). Each file defines a map of zone names to
  `{ records = [...] }`.
- Public (non-secret) records can go in the corresponding `.auto.tfvars` files
  under the Terraform project directory.
- DNS records are **only** managed through the DNS Terraform project. Do not
  define DNS records in the platform or apps phases.

## Merge order and key implications

The module merges records from multiple sources in a fixed order:

1. Public `zones` variable (`.auto.tfvars`)
2. Secret zones main
3. Secret zones stage
4. Secret zones archive
5. Secret zones inactive

Records from all sources share the same zone-level `key` namespace. Keep `key`
values unique even when a zone spans multiple source files.

## Applying DNS changes

- DNS changes are applied via the `dns` Terraform phase
  (`nixbot tf/cloudflare-dns` or as part of `nixbot run`/`nixbot tf`).
- Always review the plan before applying -- watch for unexpected
  destroy/recreate pairs, which signal a key collision or a real behavioral
  change rather than harmless reordering.
