# Age Secrets Recipient Eval 2026-06

## Context

`scripts/age-secrets.sh -c` failed while loading the managed recipient map with
`nix eval --json --file data/secrets/default.nix`.

The failure surfaced on global secrets that included a machine recipient list,
for example:

```nix
${globals.key "cloudflare/api-token"}.publicKeys = admins ++ pvl-x2;
```

## Root Cause

`lib/flake/secrets.nix` built machine recipient lists as:

```nix
recipients = [readRecipient publicKey];
```

In Nix, list syntax does not imply function application for adjacent elements.
That expression is a two-element list containing the `readRecipient` function
and the `publicKey` path. JSON export then failed because functions cannot be
serialized.

## Decision

Bind the evaluated recipient before constructing the list:

```nix
recipient = readRecipient publicKey;
recipients = [recipient];
```

This keeps `machineIdentities.recipients.<host>` as a list of recipient strings
and avoids precedence ambiguity in the secret helper.
