# Cloudflare Email Routing

## Goal

Enable or change Cloudflare Email Routing from this repo while keeping the
declarative state in Terraform and handling the required manual verification
step for destination addresses.

## Source Of Truth

- Account-level destination addresses:
  `data/secrets/tf/cloudflare/account.tfvars.age`
- Zone routing state:
  `data/secrets/tf/cloudflare-platform/email-routing-<group>.tfvars.age`
- DNS records for the zone:
  `data/secrets/tf/cloudflare-dns/project-<group>.tfvars.age`
- Terraform resources: `tf/modules/cloudflare/account.tf`
  `tf/modules/cloudflare/zone-email-routing.tf` via the project root in
  `tf/cloudflare-platform/`

## Add A Destination Address

1. Decrypt or edit `data/secrets/tf/cloudflare/account.tfvars.age`.
2. Add the email address to `email_routing_addresses`.
3. Run `./scripts/nixbot.sh --action tf-platform --dry`.
4. Run `./scripts/nixbot.sh --action tf-platform`.
5. Wait for Cloudflare to send the verification email.
6. Open the verification email and complete the confirmation link.
7. Run `./scripts/nixbot.sh --action tf-platform --dry` again to confirm the
   address now shows as verified.

## Enable Email Routing For A Zone

1. Pick the correct zone group file under
   `data/secrets/tf/cloudflare-platform/`.
2. Add or update the zone under `email_routing`.
3. Set `settings = true` when the zone should have Email Routing provisioned.
4. Set `dns = true` only when you want Terraform to manage the Cloudflare MX,
   SPF, and DKIM records needed to make the zone ready.
5. Add any explicit routing rules under `rules`.
6. Add a `catch_all` block only when the catch-all behavior is intentionally
   different from Cloudflare's default drop rule.
7. Run `./scripts/nixbot.sh --action tf-platform --dry`.
8. Run `./scripts/nixbot.sh --action tf-platform`.

## Add Or Change A Forwarding Rule

1. Make sure the destination address already exists in `email_routing_addresses`
   and has been manually verified.
2. Edit the zone's `email_routing` entry in the right group file.
3. Add or update a rule:

```hcl
email_routing = {
  "example.com" = {
    settings = true
    dns      = true
    rules = [
      {
        name    = "forward-sales"
        enabled = true
        matchers = [
          {
            field = "to"
            type  = "literal"
            value = "sales@example.com"
          }
        ]
        actions = [
          {
            type  = "forward"
            value = ["dest@example.net"]
          }
        ]
      }
    ]
  }
}
```

1. Run `./scripts/nixbot.sh --action tf-platform --dry`.
2. Run `./scripts/nixbot.sh --action tf-platform`.

## Verification Notes

- Destination-address verification is inherently manual. Terraform can create
  the address, but it cannot click the email confirmation link for you.
- `cloudflare_email_routing_address` exposes `verified` after the mailbox owner
  completes verification.
- If a zone stays `misconfigured`, check the Cloudflare Email Routing DNS
  records for missing MX, SPF, or DKIM entries and add them through the DNS
  group tfvars or `dns = true`.
