# pvl-x2 NixOS 26.05 Transition 2026-06

## Incident

After the `pvl-x2` NixOS 26.05 switch on June 15, 2026, nixbot's pre-switch
user-unit reset listed stale failures for `dotfiles-sync.service`,
`lxqt-policykit.service`, `noctalia-shell.service`,
`xdg-desktop-portal-gnome.service`, and `xdg-desktop-portal-gtk.service`.

Live validation showed the system manager had transitioned cleanly:
`systemctl is-system-running` reported `running`, `home-manager-pvl.service`
completed successfully, and `systemd-user-manager-dispatcher-pvl.service`
completed user-service reconciliation.

## Findings

- `lxqt-policykit.service`, `noctalia-shell.service`,
  `xdg-desktop-portal-gnome.service`, and `xdg-desktop-portal-gtk.service`
  exited when the graphical session/compositor was torn down at
  `2026-06-15 12:57:11 +08`. The logs show broken Wayland connections, not an
  independent NixOS 26.05 service failure.
- `xdg-document-portal.service` remained the only failed user unit after the
  switch. It was stopping during the same session teardown, did not exit before
  systemd's stop timeout, and was killed along with a `fusermount3` child.
- `dotfiles-sync.service` failed during boot because the generated script used
  `${pkgs.glibc.bin}/bin/getent`, which pointed at a store path no longer
  present on the live 26.05 system. The script then reported a misleading DNS
  timeout for `github.com` because every retry failed before the DNS lookup.
- `dotfiles-sync.timer` remained healthy and had a real next firing time, so the
  prior timer wedge was not reproduced.

## Follow-up

Use `pkgs.getent` for the sync script's DNS probe. It resolves to the standalone
`getent-glibc` output used by the current system profile instead of the broader
glibc output path.
