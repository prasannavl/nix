# pvl-a1 Sway SSH Agent

## Context

`pvl-a1` imports both GNOME and Sway desktop modules. GNOME enables
`services.gnome.gcr-ssh-agent` and disables
`programs.gnupg.agent.enableSSHSupport`.

That makes Sway inherit GNOME's SSH agent choice unless Sway sets its own
session environment.

## Decision

Sway exports `SSH_AUTH_SOCK` to `$XDG_RUNTIME_DIR/gcr/ssh` and imports that
value into the user systemd environment at Sway startup.

This uses the same GCR SSH agent service enabled by GNOME instead of enabling
GPG agent SSH support for Sway.
