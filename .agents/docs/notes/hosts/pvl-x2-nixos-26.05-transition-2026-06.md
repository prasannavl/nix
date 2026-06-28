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
  systemd's stop timeout, and was killed along with a `fusermount3` child. Live
  inspection after rollback still showed `/run/user/1000/doc` mounted as
  `fuse.portal`, so the failure source was document-portal FUSE teardown during
  logout rather than a unit that should be hidden from health checks.
- `dotfiles-sync.service` failed during boot because the generated script used
  `${pkgs.glibc.bin}/bin/getent`, which pointed at a store path no longer
  present on the live 26.05 system. The script then reported a misleading DNS
  timeout for `github.com` because every retry failed before the DNS lookup.
- `dotfiles-sync.timer` remained healthy and had a real next firing time, so the
  prior timer wedge was not reproduced.
- Activation warnings like
  `not applying UID change of user 'gdm-greeter-2' (60580 -> 60579)` come from
  the upstream GDM module's 26.05 greeter-user renumbering. In 25.11, GDM
  declared `gdm-greeter`, then `gdm-greeter-1` through `gdm-greeter-4` with UIDs
  `60578` through `60582`. In 26.05, it declares `gdm-greeter`, then
  `gdm-greeter-2` through `gdm-greeter-5` with the same UID range. Existing
  `/etc/passwd` entries for `gdm-greeter-2` through `gdm-greeter-4` therefore
  sit one UID higher than the new declaration. NixOS activation refuses to
  rewrite existing UIDs in place, so the warnings preserve the old UIDs instead
  of applying the shifted declarations.
- On June 28, 2026, another pvl-x2 deploy hit the same stale account state. Live
  readback showed `gdm-greeter-2`, `gdm-greeter-3`, and `gdm-greeter-4` still
  had their pre-26.05 shifted UIDs, while `gdm-greeter-4` and `gdm-greeter-5`
  both mapped to UID `60582`.
- The one-time account migration removed the stale users and eliminated the UID
  warnings, but deploy still failed because `switch-to-configuration-ng` reloads
  every active logind user. The active GDM greeter user then failed to restart
  GNOME login-session user targets and made the switch return exit code `4`.

## Follow-up

Use `pkgs.getent` for the sync script's DNS probe. It resolves to the standalone
`getent-glibc` output used by the current system profile instead of the broader
glibc output path.

Use the shared WM `portalCleanup` owner to cleanly exit document portal on
logout by including `xdg-document-portal.service` in the existing portal stop
set.

For the GDM greeter UID warnings, treat the messages as stale local account
state after the upstream suffix change, not as agenix, nixbot, or secret
deployment failures. The deploy-time migration experiment showed that stopping
`display-manager.service` before account reconciliation avoids the active GDM
greeter user-manager reload failure, but no durable repo-side GDM migration is
kept after the live account state converged.
