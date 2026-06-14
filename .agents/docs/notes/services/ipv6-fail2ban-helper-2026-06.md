# IPv6 Fail2ban Helper

## Summary

The personal Nix repo owns a generic `services.fail2ban-helper` module for
host-local fail2ban bans. It starts with exact source-address bans, then
escalates repeated IPv6 exact-address bans from one canonical `/64` into an
nftables prefix ban.

The controls are provider-agnostic. Cloudflare Tunnel or other upstream
filtering can reduce load, but host-local nginx and SSH controls must stand on
their own.

## Host Scope

- `pvl-x2`: enables fail2ban, the fail2ban helper, and the nginx `limit_req`
  jail. This is the public nginx ingress host.
- `pvl-a1`: enables fail2ban for SSH only.
- `pvl-l5`: enables fail2ban for SSH only.
- Other personal hosts and generated Incus/LXC/VM profiles do not enable
  fail2ban by default. Keep them opt-in unless they become public ingress.

## Defaults

- Exact-address base ban: 10 minutes.
- Exact-address repeat ban growth: 10 minutes, 20 minutes, then capped at 1 hour
  through fail2ban's native `bantime-increment`.
- IPv6 prefix escalation: 3 exact IPv6 bans from the same `/64` inside 10
  minutes adds a `/64` nftables ban.
- IPv6 prefix ban time: 10 minutes.
- Nginx prefix guardrail: 5x the exact-IP request and burst thresholds.

## Pipeline

```text
nginx rate-limit event or sshd auth failure
  |
  v
fail2ban jail crosses maxretry/findtime
  |
  v
fail2ban-helper-nftables action
  |
  +--> IPv4: exact nftables timeout entry
  |
  +--> IPv6: exact nftables timeout entry
            record canonical /64 hit
            after threshold: add /64 nftables timeout entry
```

The helper is reactive. It is not a daemon and does not poll. Fail2ban watches
the configured jail backends and executes the helper only when a jail decides to
ban or unban an address.

## Validation

For future changes, validate at least:

```bash
alejandra lib/services/fail2ban-helper/default.nix lib/services/nginx/default.nix lib/services/exposed-ports/default.nix
python3 -m py_compile lib/services/fail2ban-helper/fail2ban-helper.py
nix eval --json .#nixosConfigurations.pvl-x2.config.services.fail2ban.jails
nix eval --json .#nixosConfigurations.pvl-x2.config.services.fail2ban.bantime
nix eval .#nixosConfigurations.pvl-x2.config.system.build.toplevel.drvPath
```
