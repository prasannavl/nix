# DNS

## Scope

- Apply these rules when changing repo-managed DNS design, Terraform/OpenTofu
  DNS modeling, DNS adoption, or DNS migration workflows.
- Treat this as an architectural pattern document, not a one-off incident log.

## Stable Identity

- DNS resources must have stable logical identities that do not depend on list
  position.
- Do not key Terraform/OpenTofu DNS resources by array index when multiple
  records can share the same `zone/type/name`.
- DNS records should be keyed as `zone/key`, where `key` is an explicit durable
  field authored in tfvars.
- Prefer explicit durable record keys in tfvars, for example a user-chosen key
  or a normalized semantic key, instead of implicit position.
- If duplicate records are valid at the provider level, the logical key still
  needs to be explicit and durable. Do not rely on provider record IDs for repo
  authoring identity.

## Change Sequencing

- Prefer additive DNS changes first, then cleanup in a later wave if record
  identities or traffic paths are changing.
- When introducing a new record that changes serving topology, for example a new
  tunnel CNAME, do not combine that with unrelated renumbering or cleanup in the
  same apply unless state keys are already stable.
- For high-impact hostname cutovers:
  - create the new target first
  - verify the target is healthy
  - switch traffic
  - remove obsolete records only after verification
- Avoid same-apply replacement patterns where provider duplicate-record rules
  can reject in-place rewrites after partial progress.

## State Safety

- Snapshot remote state before DNS migration or adoption waves.
- If DNS record keys must change, prefer explicit state moves or imports over
  provider-side delete/recreate churn.
- When a plan shows widespread DNS address churn after inserting one record,
  stop and treat that as a state-model problem, not a routine plan.
- Partial DNS applies can leave live records and state addresses out of sync.
  Recovery should start with state inspection and live record inventory before
  another broad apply.

## Recovery Lessons

- On April 2, 2026, adding a new tunnel CNAME at the top of
  `tf/cloudflare-dns/dns.auto.tfvars` shifted downstream MX and TXT indices.
- That caused a partial apply:
  - some old records were deleted
  - some new records were created
  - later updates failed with Cloudflare duplicate-record errors
- The safe recovery pattern was:
  - snapshot state
  - inspect live DNS
  - move state addresses to the records that already existed live
  - apply only the truly missing records
- Record-address churn from positional keys is not acceptable as a normal DNS
  workflow. The durable fix is explicit `key` fields on every record.

## Creation Rules

- New DNS records should be introduced with explicit intent and a stable repo
  identity.
- For apex service changes, confirm the origin or tunnel is already healthy
  before switching the public record.
- For tunnel-backed hostnames, verify both:
  - the DNS record target
  - the tunnel connectivity and origin health
- For mail-related records, preserve exact content and priority semantics.
  Reordering MX or TXT records should not happen as incidental fallout from an
  unrelated change.

## Deletion Rules

- Deleting DNS records should be a separate conscious action when possible.
- Do not let deletion happen as an accidental side effect of list reordering,
  formatting changes, or inserting another record nearby.
- Before deleting records tied to mail, DKIM, SPF, verification, or tunnel
  service entrypoints, verify they are truly obsolete and not merely moving to a
  new logical address.

## Operational Checks

- Before apply:
  - inspect plan for unrelated DNS churn
  - stop if a single intended add causes broad updates or destroys
- After apply:
  - verify live DNS values
  - verify service health behind the affected hostname
  - confirm the next plan is quiet or limited to consciously accepted
    output-only drift

## Preferred Direction

- Keep the DNS model on explicit stable keys.
- Author DNS records with explicit stable `key` values in the repo, then map
  those keys directly to Terraform/OpenTofu `for_each`.
- Treat that as the durable default for safe DNS creation, deletion, and
  adoption.
