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

## Automatic client identity

If a client module enables its `age.secrets` declarations when a package is
installed, compare **names**, not derivations. Compare `name` (falling back to
`pname`) on both the requested and installed packages. A same-name override
still selects the identity; an absent client does not. Derivation equality can
force an unrelated generated script whose text reads
`config.age.secrets.<name>.path`, recursing into the very option being computed.

This selection is distinct from binding: the package publishes only neutral
intent such as `{ name = build.pname; }`; `stack.identity.bind` accepts that
intent, not a derivation. Deployment still owns the identity policy and runtime
paths. Test all three selection cases with an unrelated generated script that
reads a synthetic `age.secrets` path, so the check catches evaluation cycles
without needing any credentials.
