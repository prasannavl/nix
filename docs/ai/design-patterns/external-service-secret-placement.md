# External Service Secret Placement

For stack-scoped credentials owned by an external provider, store the encrypted
source under that stack's external-provider secret tree:

```text
data/secrets/<stack>/ext/<provider>/<secret>.age
```

Use this for provider-owned SMTP relay logins, SaaS API keys, OAuth app secrets,
webhook signing secrets, and third-party service tokens.

Keep service-local secrets under a service tree only when the secret belongs to
the hosted service itself: bootstrap credentials, generated signing keys,
service-internal tokens, or private keys consumed by that service.

When adding or refactoring an external provider module:

1. Place new encrypted files under `data/secrets/<stack>/ext/<provider>/`.
2. Add exact recipient policy in `data/secrets/default.nix`.
3. Materialize the secret with `age.secrets`.
4. Pass only `config.age.secrets.<name>.path` or the matching runtime path to
   the consuming service.
