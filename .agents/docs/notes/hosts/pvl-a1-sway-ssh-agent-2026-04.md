# pvl-a1 Sway SSH Agent

## Context

`pvl-a1` imports both GNOME and Sway desktop modules. GNOME enables
`services.gnome.gcr-ssh-agent` and disables
`programs.gnupg.agent.enableSSHSupport`.

That makes Sway inherit GNOME's SSH agent choice unless Sway sets its own
session environment.

## Decision

The NixOS Sway wrapper exports `SSH_AUTH_SOCK` to `$XDG_RUNTIME_DIR/gcr/ssh`
before the compositor starts. Home Manager's Sway systemd/DBus activation hook
imports the live Sway process environment with `--all`, so the value reaches the
user systemd and D-Bus activation environments.

This uses the same GCR SSH agent service enabled by GNOME instead of enabling
GPG agent SSH support for Sway.
