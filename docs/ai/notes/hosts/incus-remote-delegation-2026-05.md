# Incus Remote Delegation 2026-05

`services.incusMachines.global.remote` lets a NixOS host run the repo Incus
lifecycle helpers against a remote Incus HTTPS API instead of a local daemon.

The remote mode is intended for delegated control from an Incus guest back to a
parent daemon:

- the parent host owns Incus preseed, networks, profiles, storage, and trusted
  certificate reconciliation
- the delegated guest gets only an Incus client certificate and private key
- helper commands build an ephemeral Incus client config under `/run`
- lifecycle, image, reconcile, and settlement commands target the configured
  remote through normal Incus CLI remote references
- instance operations are project-aware through
  `services.incusMachines.<project>.instances.<name>.project`
- remote-mode GC is enabled for delegated controllers, but scoped to configured
  remote projects and to instances whose structured `user.nixos-meta` owner
  matches the controller
- generic `services.incusMachines.global.preseedMigrations` remains available
  for explicit future parent fabric transitions before `incus-preseed.service`;
  throwaway one-shot defaults should be removed after rollout
- local Incus daemon enablement defaults off in remote mode

Parent-side certificate delegation is modeled separately from remote mode:

- parent hosts declare `services.incusMachines.global.certificateDelegations`
- guests mount a delegation with `incusLib.mkCertDelegation "<name>"`
- delegated guests declare
  `services.incusMachines.global.remote.projects.<project>` to publish
  project-scoped certificate state back through mounted delegation directories
- the parent reconciler validates, prefixes, restricts, and garbage-collects
  delegated trusted certificates

`incusLib.mkIncusProxy` remains the helper for forwarding the parent Incus HTTPS
API into a delegated guest. `incusLib.mkCertDelegation` creates the matching
disk device for the delegated certificate state directory. The parent lifecycle
maps guest root through each guest's idmap, then applies host-side ownership to
these handoff files. This lets root-owned guest services update the delegation
state while keeping the mount compatible with restricted project source-path
checks.

Source of truth files:

- `lib/incus/default.nix`
- `lib/incus/helper.sh`
- `lib/incus/lib.nix`

## Abird Nest on pvl-x2

`abird-nest` is a NixOS LXC guest declared by the pvl-x2 parent Incus config in
`/home/pvl/src/nix`. The parent places it in the `abird` project at
`10.10.100.10`, forwards the parent Incus HTTPS API to `127.0.0.1:8443` inside
the guest, and mounts the parent-owned `abird`, `abird-stage`, and `abird-dev`
certificate delegation directories.

This repo owns the guest configuration. `hosts/abird-nest/incus.nix` uses
`services.incusMachines.global.remote` against the forwarded pvl-x2 API with the
`abird` project as the default remote project. Project-scoped settings live
under `services.incusMachines.global.remote.projects`:

- `abird`: allowed subnet `10.10.100.0/24`; auto-publishes the `abird-nest`
  client certificate and additionally publishes `pvl`
- `abird-stage`: allowed subnet `10.10.200.0/24`; auto-publishes the
  `abird-nest` client certificate and additionally publishes `pvl`
- `abird-dev`: allowed subnet `10.10.220.0/24`; auto-publishes the `abird-nest`
  client certificate and additionally publishes `pvl` and `peter`

The shared Incus module writes the delegated `certs.json` files through
`incus-remote-project-delegated-certificates.service`; host-local writer units
are not needed. For each remote project that includes the controller
certificate, the writer waits until the parent API authorizes that certificate
for the specific project before machine units start.

The delegated directory is parent-owned. The guest-side writer must not change
ownership or permissions on `/var/lib/incus-delegation/<project>`; it writes the
already provisioned `certs.json` file and only uses same-directory atomic rename
when the mount permits creating temporary files there.

Parent tmpfiles must not reset delegation directory or file ownership on every
activation. The Incus instance lifecycle helper creates the handoff file when
missing, maps guest root through the instance idmap, and owns the handoff path to
that host UID/GID so guest root can update it.

Remote delegated cleanup uses the same `incus-machines-gc.service` as local
management. In remote mode it does not use `--all-projects`; it lists only the
projects configured under `services.incusMachines.global.remote.projects` and
only deletes instances whose structured `user.nixos-meta` marks them as owned by
the current controller. The controller ID defaults to the NixOS host name and can
be overridden with `services.incusMachines.controllerId`.

The pvl-x2 parent still owns the final Incus trust entries and project
restriction. The tenant JSON only supplies local certificate names and public
PEM material.

Incus trust entries are globally unique by certificate fingerprint, not by
project. If the same tenant certificate is published through multiple project
delegations, the parent reconciler converges one trust entry whose `projects`
list contains all delegated projects instead of deleting and recreating the same
fingerprint for each project-specific service.

Incus images are also globally keyed by image fingerprint. If an import sees the
same fingerprint before the repo metadata properties are present, the image
reconciler treats the existing fingerprint as the desired image and attaches the
declared alias instead of failing the deploy. For split local NixOS images, do
not derive this from `sha256(metadata.tar.xz)`; reconcile by the metadata
properties Incus stores on the image and serialize aliases that share the same
declared image identity.

Public delegated client certificates live under `data/incus/*.crt`. User private
keys are not stored in plaintext in the repo. Operators generate
browser-importable Incus client identities from the `mkUserCertWithKeys`
declarations next to the remote-project cert wiring in `hosts/*/incus.nix`. That
declaration returns direct `.cert`, `.key`, and `.pfx` paths and can attach one
user certificate to multiple remote projects. The caller supplies the exact
output paths; Abird uses `data/incus/<user>.crt` and stack-scoped encrypted
outputs such as `data/secrets/abird/incus/<user>.key.age` /
`data/secrets/abird/incus/<user>.pfx.age`. The Incus helper `certs` subcommand
materializes those declared artifacts through `lib/incus/helper-certs.py`. Keep
the access source project-centric:
`services.incusMachines.global.remote.projects.<project>.userCerts` determines
both the remote project's generated certs and each user's restricted project
list. Raw `certs` remain available and are merged with the generated user certs
through `global.remote.userCertificates`. Chrome / NSS can import RSA and ECDSA
client keys from PKCS#12 here, but not Ed25519 or Ed448 keys, so the generator
uses ECDSA P-256 by default instead of trying to reuse the user's SSH private
key as the Incus TLS client key. The user's SSH keys from userdata are only the
age recipients for unlocking the generated private artifacts.

For `znest.abird.ai`, `abird-nest` also runs an OAuth-aware Incus bridge that
selects one of those generated user client certificates from the authenticated
oauth2-proxy username. The encrypted user `.key.age` files include `abird-nest`
as an extra host recipient for this server-side bridge; `.pfx.age` files remain
encrypted only to the owning user. If no generated certificate exists for the
OAuth user, the bridge proxies without a client certificate so Incus falls back
to its native TLS-client-certificate login screen.

`abird-nest` owns delegated replicas of the `abird-*` guests that originally ran
on `gap3-gondor`. The `abird` project uses the same role last octets under
`10.10.100.0/24`; `abird-stage` is the moved previous `abird-dev` environment
under `10.10.200.0/24`; the fresh `abird-dev` project uses the same role last
octets under `10.10.220.0/24`. Incus instance names stay the same inside each
project, so `abird-proxy` exists as `abird/abird-proxy`,
`abird-stage/abird-proxy`, and `abird-dev/abird-proxy`, while the NixOS/systemd
declaration keys remain unique.
