# DNS (Terraform / OpenTofu)

## Scope

- Apply these rules when editing `*.tfvars` or `*.tf` files that define DNS
  records, and when advising on DNS changes.

## Record list ordering

- **Always append new records at the end of a zone's `records` list.** Never
  insert in the middle or reorder existing entries.
  - **Why:** The Terraform module builds `for_each` keys using the array index
    (e.g., `zone/TYPE/name/index`). Inserting or reordering shifts every
    subsequent index, causing Terraform to destroy and recreate all those
    records rather than just adding the new one. This creates unnecessary churn,
    risks brief DNS outages from delete-before-create race conditions, and can
    trigger Cloudflare API conflicts.
- When removing a record, comment it out or replace its content with an
  equivalent no-op if index preservation matters. Prefer a `state rm` +
  list-edit over a bare list removal when many records follow.

## Record structure

Each record in the `records` list is an HCL object. Required fields:

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

## Merge order and index implications

The module merges records from multiple sources in a fixed order:

1. Public `zones` variable (`.auto.tfvars`)
2. Secret zones main
3. Secret zones stage
4. Secret zones archive
5. Secret zones inactive

Records from earlier sources get lower indices. Adding records to a source that
precedes another will shift indices in the later sources. When adding records to
a zone that spans multiple sources, be aware of the combined index space.

## Applying DNS changes

- DNS changes are applied via the `dns` Terraform phase
  (`nixbot tf/cloudflare-dns` or as part of `nixbot run`/`nixbot tf`).
- Always review the plan before applying -- watch for unexpected
  destroy/recreate pairs, which signal an index shift.
