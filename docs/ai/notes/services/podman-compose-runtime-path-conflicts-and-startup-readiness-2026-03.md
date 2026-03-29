# Podman Compose Runtime Path Conflicts And Startup Readiness

- Generated `lib/podman.nix` staging now treats manifest-managed runtime paths
  as replaceable objects, not only files.
- Before restaging a managed runtime path, the generated helper removes any
  existing file, directory, or symlink at both the destination and its `.tmp`
  path.
- Cleanup now uses `rm -rf` for manifest-managed paths so stale file-versus-
  directory conflicts do not survive across reloads or restarts.
- This fixes a real `pvl-x2` nginx failure where
  `/var/lib/pvl/compose/nginx/nginx.conf` had become a directory containing
  `nginx.conf.tmp`, which made the container bind mount fail with
  `Not a directory`.
- Generated compose services now use `Type=notify` and call
  `systemd-notify --ready` only after `podman compose up -d` and the compose
  state verification both succeed.
- This closes the misleading deploy-time green case where
  `systemd-user-manager` logged a compose unit restart as completed even though
  the stack failed moments later during startup verification.
- Runtime supervision no longer relies on `podman compose wait`.
- On `pvl-x2`, Podman's external `podman-compose` provider returned
  `status=3/NOTIMPLEMENTED` for `wait`, which put every running compose unit
  into a pointless auto-restart loop while their containers stayed up.
- The generated unit now `exec`s a provider-agnostic monitor loop that polls
  `podman compose ps --format json`, exits nonzero on bad states, and exits zero
  only once the whole stack has stopped cleanly.
