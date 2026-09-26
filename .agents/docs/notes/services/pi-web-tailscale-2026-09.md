# Pi Web UI over Tailscale

On 2026-09-26, `pvl-l5` gained a declarative Pi Web service reachable from the
whole tailnet. Previously `pi-web` was a manually started loopback process
(`127.0.0.1:30141`), and the `pvl-l5` firewall dropped port 30141 from every
other host, so `http://pvl-l5:30141/` timed out from `pvl-a1`.

## Module

`lib/services/pi-web/default.nix` defines `services.pi-web`:

- runs the repo `pi-web` package (`pkgs.callPackage ../../ext/pi/pi-web {}`)
  under `services.pi-web.user` (default `pvl`, so it keeps that user's Pi agent
  state) as a systemd service;
- `port` (default 30141), `bindAddress` (default loopback, or `0.0.0.0` when
  `tailnetAccess` is on), `allowedHosts` (rendered into `PI_WEB_ALLOWED_HOSTS`),
  and an optional `environmentFile` for `PI_WEB_PASSWORD` and other `PI_WEB_*`
  secrets;
- `tailnetAccess` adds a single `iifname "tailscale0" tcp dport <port> accept`
  firewall rule. No other interface is opened.

`hosts/pvl-l5/services/pi-web.nix` enables it with `tailnetAccess = true` and
`allowedHosts = [hostName, "${hostName}.tailcaaad.ts.net"]`.

## Why bind plus a scoped firewall rule

`pi-web` (Next.js) answers `403` for unknown `Host` headers while accepting raw
IPs and `localhost`, so the MagicDNS names need `PI_WEB_ALLOWED_HOSTS`. Binding
`0.0.0.0` and allowing the port only on `tailscale0` keeps the fully
declarative, plain-NixOS shape the repo already uses for tailnet access (see
`lib/tests/swap-auto-remote-vm.nix`), and Tailscale already encrypts the
transport. A `tailscale serve` front (HTTPS at
`https://pvl-l5.tailcaaad.ts.net/` with `pi-web` left on loopback) was
considered; NixOS has no native serve option, so it would need a stateful
serve-config oneshot and is less declarative here.

## Access and operations

- From any tailnet node: `http://pvl-l5:30141/`,
  `http://pvl-l5.tailcaaad.ts.net:30141/`, or `http://100.100.10.2:30141/`.
- Stop any manually started `pi-web` before activating, or the service cannot
  bind the port.
- `pi-web` can drive the Pi agent (tools, file edits). Exposure is limited to
  the tailnet; set `PI_WEB_PASSWORD` through `services.pi-web.environmentFile`
  (for example from agenix) when a second factor is wanted.
- `pvl-a1` runs no `pi-web` service; it consumes the `pvl-l5` endpoint.

## Validation

```console
nix eval .#nixosConfigurations.pvl-l5.config.systemd.services.pi-web.serviceConfig.ExecStart --raw
nix eval .#nixosConfigurations.pvl-l5.config.networking.firewall.extraInputRules --raw
nix eval .#nixosConfigurations.pvl-l5.config.system.build.toplevel.drvPath --raw
nix eval .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath --raw
```

The evaluated `ExecStart` binds `0.0.0.0:30141`, the environment carries
`PI_WEB_ALLOWED_HOSTS=pvl-l5,pvl-l5.tailcaaad.ts.net`, and the firewall input
rules contain the `tailscale0` accept in addition to the existing `wlan0`
private-range rule.
