# Cloudflare DNS Stable Record Keys

- Date: 2026-04-14
- Scope: `tf/modules/cloudflare/dns.tf`, `tf/cloudflare-dns/**`, and the
  plaintext DNS tfvars under `data/secrets/tf/cloudflare-dns/`.

## Decision

- DNS records now carry an explicit `key` field, and Terraform addresses use
  `zone/key` instead of `zone/type/name/index`.
- Visible DNS tfvars were updated to include stable keys for every record.
- For mutable records, keys should be semantic or slot-based rather than
  content-derived.
- `tf/cloudflare-dns/moved.tf` carries one-time state moves from the old
  positional addresses to the new key-based addresses.

## Why

- Positional DNS addresses were already called out in repo docs as unsafe.
- Inserting or reordering records changed Terraform addresses for unrelated
  records and risked partial applies plus duplicate-record failures.

## Follow-up Risk Review

- Other Cloudflare resources still use positional keys in some list-driven
  inputs:
  - `tf/modules/cloudflare/workers.tf` for Worker routes and custom domains
  - `tf/modules/cloudflare/zone-email-routing.tf` for email routing rules
  - `tf/modules/cloudflare/r2.tf` for R2 custom domains and event notifications
- Those should be migrated the same way if stable list reordering is needed.
