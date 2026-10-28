# dotlink MCP bridge on pvl-a1, pvl-l5 and pvl-x2

On 2026-10-11 the Pvl hosts `pvl-a1` and `pvl-l5` gained a managed `dotlink`
service. dotlink is a permission-scoped local MCP bridge that opens an outbound
OpenAI Secure MCP Tunnel so ChatGPT (and other remote MCP clients) can work on
selected local projects without an inbound port or a third-party relay.

On 2026-10-13 the service was updated to `dotlink v0.8.0` and the NixOS module's
host-integration and developer-cache grants were enabled on both hosts (see
[Host access and developer caches](#host-access-and-developer-caches)). v0.8.1
followed the same day to fix a startup abort when a requested cache directory
was absent (see
[dotlink missing Go-module cache broke pvl-a1 activation](dotlink-missing-go-mod-cache-activation-failure-2026-10.md)).

On 2026-10-14 the service was updated to `dotlink v0.9.0`, which adds opt-in KVM
and AMD/NVIDIA GPU device access. Both hosts now enable `hostAccess.kvm` and
`hostAccess.gpu = [ "amd" "nvidia" ]`.

On 2026-10-27 the service was updated to `dotlink v0.10.0` and gained a third
instance on `pvl-x2` (see [pvl-x2](#pvl-x2)). The module itself is unchanged by
v0.10.0 (no diff under `nix/`, `flake.nix` or `flake.lock` upstream between the
v0.9.0 bump and `08ca60d`); the release is a source and tool-surface bump
(`grep`/`edit`/`patch`/`ls`, OAuth and HTTP hardening).

On 2026-10-27 the input was bumped again to `dotlink v0.11.0` (`aa8d817`)
without any host configuration change. This release does change the module:
supervision moved from `Restart=on-failure`/`RestartSec=5s` to `Restart=always`
with `RestartSec=2s` doubling through `RestartSteps=8` to `RestartMaxDelaySec`
10 min, `RestartPreventExitStatus="2 CONFIG"` leaves usage and configuration
exits stopped for the operator, `startLimitIntervalSec=0` drops the start fuse,
`KillMode=control-group` reaches sandboxed descendants, `NotifyAccess=main`
feeds `RESTART_RESET=1`, and the unit now runs with
`DOTLINK_SUPERVISOR=systemd`. The module asserts systemd 255 or newer; the hosts
run 260.5, and 258 or newer is required for the uptime-based restart-backoff
reset. Tunnel polls also hold for 30 s instead of 15 s, and protected-path
handling was tightened.

On 2026-10-27 the input was bumped once more to `dotlink v0.12.0` (`c1633b2`)
after a fleet deploy failed on `pvl-x2` alone. That host enabled the service but
had never run `dotlink --setup`, so there was no `~/.config/abird/dotlink` at
all; dotlink exited 78/`CONFIG`, and because v0.11.0 stops 78 permanently the
unit settled in `failed`, `switch-to-configuration` returned 4, and the manager
rolled the host back to its Oct 18 generation. The first deploy to carry the
service to x2 was therefore the one that broke. v0.11.0 had only converted a
silent restart loop into a visible failure; the underlying defect is that the
host depended on out-of-band interactive state.

v0.12.0 removes that failure mode: with no saved profile and non-interactive
stdin, dotlink now exits `NOTCONFIGURED` (systemd code 6) with a notice instead
of an error, and the module declares `SuccessExitStatus=NOTCONFIGURED` plus
`RestartPreventExitStatus="2 CONFIG NOTCONFIGURED"`. An unconfigured host leaves
the unit inactive, so its activation succeeds and the fleet converges. Invalid
profiles, policies and credentials still exit 78 and still fail loudly. x2 is
still unconfigured after this bump: the service simply stays inactive there
until `dotlink --setup` runs, or until the instance gains declarative `settings`
with `credentials.runtimeApiKeyFile` from agenix. The latter is the durable fix,
because it removes the per-host manual step the fleet cannot reproduce.

On 2026-10-28 the input was bumped to `dotlink v0.13.0` (`28bcd5a`) and then to
`v0.13.1` (`bb8a917`). Neither release touches `nix/`: the module, its options
and the rendered unit are unchanged, so no host configuration moved. Both
releases are tool-surface and performance work — native macOS/Windows fixes in
v0.13.0, and in v0.13.1 one shared mutation engine for `edit`/`patch`/`bedit`
with borrowed buffers, a 64 MiB aggregate retained-buffer budget, and operation
ceilings made explicit (`edit` 512 ops / 64 files, `patch` 32 files / 64 hunks,
`bedit` 32 ranges). Sandbox policy also tightened: `--allow-rw=/` combined with
`--allow-shell` is now an explicit private-path isolation opt-out, and shell
grants that overlap a denied or protected path are rejected instead of silently
narrowed. This repository grants no root-rw and no overlapping denies, so those
rules do not change the fleet's flags.

One behavioural change matters operationally: since v0.13.0
`logging.verbosity = "tools"` records each complete shell command in the journal
as one escaped `c="..."` record, while other payloads stay size-only. All three
hosts run `tools` verbosity (it was chosen for tool-activity visibility), so
journald now retains full command history — including any inline credentials a
caller types. That is the intended audit mode; journal access and retention are
the mitigations, not a configuration change.

## Flake input

`abird-ai/dotlink` is consumed as a root flake input because it ships both the
package and the `services.dotlink` NixOS module:

```nix
dotlink = {
  url = "github:abird-ai/dotlink";
  inputs = {
    nixpkgs.follows = "nixpkgs";
    crane.follows = "crane";
  };
};
```

dotlink's `nixpkgs` follows the repository's default `nixpkgs` (`nixos-26.05`);
its `crane` follows the root `crane` (`v0.24.0`). Its `rust-overlay` input
follows dotlink's `nixpkgs`, i.e. `26.05`. dotlink upstream targets
`nixos-unstable`, so this repository intentionally pins an older channel through
its own `nixpkgs`. Adding the input was purely additive — no existing input was
bumped.

The 2026-10-13 bump advanced only the `dotlink` node in `flake.lock` from
`3335af57` (2026-10-11) to `5e46cbf1` (2026-10-13); no other input moved. The
v0.8.1 fix advanced the same node to `5f46990` (2026-10-13); again no other
input moved. The v0.9.0 bump advanced the same node to `dcea9b1` (2026-10-14),
again with no other input moved. The v0.10.0 bump moved it to `08ca60d`
(2026-10-27) through `nix flake update dotlink`; the diff touches only those
three lock lines. The same command moved it to `28bcd5a` (v0.13.0) and then to
`bb8a917` (v0.13.1) at 2026-10-28, again changing only the `dotlink` node.

## Host services

`hosts/pvl-a1/services/dotlink.nix` and `hosts/pvl-l5/services/dotlink.nix` are
identical and are imported from each host's `services/default.nix`:

```nix
imports = [inputs.dotlink.nixosModules.default];

services.dotlink = {
  enable = true;
  user = "pvl";
  workingDirectory = "/home/pvl/spaces/abird/";
  logging.verbosity = "tools";

  hostAccess = {
    nixDaemon = true;
    nixConfig = true;
    gitConfig = true;
    sshAgent = true;
    kvm = true;
    gpu = [ "amd" "nvidia" ];
  };
  cacheAccess = {
    "cargo-registry" = "rw";
    "cargo-git" = "rw";
    "ccache" = "rw";
    "go-mod" = "rw";
    "go-build" = "rw";
    "gradle" = "rw";
    "maven" = "rw";
    "npm" = "rw";
    "pip" = "rw";
    "pnpm" = "rw";
    "sccache" = "rw";
    "uv" = "rw";
    "yarn" = "rw";
  };
};
```

The main `services.dotlink` instance becomes the `dotlink` systemd unit:

- `User = pvl`, `SetLoginEnvironment = true`, and
  `WorkingDirectory = /home/pvl/spaces/abird/` — the launch directory is the
  access root for relative grants and the default read permission.
- `ExecStart = <dotlink> --no-stdio --color=never --allow-shell
  --allow-nix-daemon --allow-nix-config --allow-ssh-agent --allow-git-config
  --allow-cache-<kind>=rw -v`.
  The `profile` option is left unset: the module maps both an unset selector and
  the literal `"default"` to the user's default dotlink profile, so the omitted
  value reuses that profile's runtime key and OAuth state.
  `logging.verbosity = "tools"` adds `-v` for tool activity (`"requests"` would
  add `-vv`). No secrets are placed in the Nix store.

`inputs` reaches host modules through `lib/flake/root.nix`'s `specialArgs`
(`selectedInputs = inputSet.inputs` already contains every top-level flake
input), so no `inputSetInputNames` entry is required.

The module only creates its `dotlink` system user when an instance uses
`user = "dotlink"`; the `pvl` instances do not, so no service user is added.

## Host access and developer caches

The 2026-10-13 change uses the module's own `hostAccess`/`cacheAccess` options
rather than declarative `settings`, so each host keeps reusing its saved profile
(including its per-host `tunnel_id` and OpenAI runtime key) while the repo stays
the source of truth for the host grants. The options map to `--allow-*` flags:

- `hostAccess.nixDaemon`/`nixConfig` →
  `--allow-nix-daemon`/`--allow-nix-config`, giving Bubblewrap shell tools the
  host Nix daemon and the user's XDG `nix.conf`, so `nix build`/`nix develop`
  work. No `~/.config/nix/nix.conf` exists on either host, so only the daemon
  socket is actually mounted today.
- `hostAccess.gitConfig` → `--allow-git-config`; mounts `~/.gitconfig` and
  `~/.config/git/config` read-only (`~/.gitconfig` exists on `pvl-l5` only).
- `hostAccess.sshAgent` → `--allow-ssh-agent`; the GCR socket at
  `/run/user/1000/gcr/ssh` is auto-discovered on both hosts (no `sshAgentSocket`
  override). The agent must already be running as `pvl` at service start.
- `hostAccess.kvm` → `--allow-kvm`; `hostAccess.gpu` → one
  `--allow-gpu=<vendor>` per vendor. Since v0.9.0 the module also sets
  `SupplementaryGroups = [ "kvm" "render" "video" ]` on the unit when KVM or GPU
  access is enabled; the groups are unit-scoped and do not change the user's
  global groups.
- `cacheAccess` → `--allow-cache-<kind>=rw` for all thirteen module-supported
  kinds (Cargo registry/git, ccache, Go mod/build, Gradle, Maven, npm, pip,
  pnpm, sccache, uv, Yarn), each `rw`, on every dotlink host. Since v0.8.1 a
  cache whose directory is absent is skipped with a warning instead of aborting
  startup, so a configured-but-uncreated cache (for example `go-mod` on a host
  that never ran Go builds) no longer kills the unit and later caches need no
  module edit. Only the caches actually present are mounted today.

## pvl-x2

`hosts/pvl-x2/services/dotlink.nix` is imported from that host's
`services/default.nix` and differs from the a1/l5 module in four ways:

- `workingDirectory = "/home/pvl/src/"` — the host's source checkout root. It
  does not exist yet, so the module adds
  `systemd.tmpfiles.rules = [ "d /home/pvl/src 0755 pvl pvl -" ]`; activation
  owns the directory instead of relying on a manual `mkdir` before first start.
- `hostAccess.gpu = [ "amd" ]` only: `pvl-x2` is the AMD Strix Halo host with no
  NVIDIA device, so only the AMD character devices and driver resources are
  granted. `hostAccess.kvm` is on (`kvm-amd` is loaded and `/dev/kvm` exists).
- `cacheAccess` is the same thirteen-kind `rw` set as a1/l5. Only `~/.cache/pip`
  exists today; the absent kinds are skipped with the v0.8.1 warning.
- The remaining host grants (`nixDaemon`, `nixConfig`, `gitConfig`, `sshAgent`)
  match a1/l5. `~/.config/git/config` and the GCR socket at
  `/run/user/1000/gcr/ssh` exist; there is no `~/.config/nix/nix.conf`.

`pvl-x2` has no saved dotlink profile yet, so the unit stays down until one
manual `dotlink --setup` as `pvl` creates one (the same first-run gate as the
other hosts).

## Invalid working directory

`workingDirectory` is not validated beyond the module assertion that it is a
non-null absolute path (`lib.hasPrefix "/"`); nothing checks existence, and the
module passes it to systemd without the `-` prefix. Consequences:

- A relative, null or otherwise non-absolute value fails Nix evaluation through
  the assertion.
- A missing, non-directory or unreadable path fails the unit before exec:
  systemd cannot `chdir` and reports `status=200/CHDIR` with
  `Failed at step CHDIR spawning …: No such file or directory`. Since v0.11.0
  that is a supervised restart with 2 s doubling backoff (to 10 min) rather than
  a five-second loop; configuration and usage exits stay stopped instead.
- Started by hand from a deleted directory, dotlink fails at startup itself:
  `std::env::current_dir()` errors, printing
  `Error: No such file or directory (os error 2)`.
- The launch directory is captured once at startup and never re-validated, so
  deleting it while the unit runs does not stop the unit; shell tool calls that
  mount that path fail instead. Relative grants and the default `"."` read
  permission keep resolving against the captured path.

The module adds `--allow-shell` automatically whenever a host integration or
cache is requested. Shell **network** access is not a module option; it stays
enabled through each host's saved profile (`permissions.allow_network = true`,
along with `allow_shell = true` and the seven caches it was set up with).

## Build

The flake's default package compiles dotlink from source with `crane`. The
package is not exposed through `pkgs/manifest.nix`; it is referenced only by the
host service modules through the flake input, and the `dotlink` CLI is not added
to the hosts' `systemPackages`. A first run therefore requires one manual
`dotlink --setup` (and `--allow-*`) as user `pvl` on each host before the unit
can connect; the packaged binary is reachable at
`systemctl show -p ExecStart dotlink` if needed.

The v0.8.0 bump needed only seven derivations (Rust 1.98.1 toolchain plus
`dotlink-deps`/`dotlink`); the rest was substituted from the `pvl-x2` binary
cache. `dotlink v0.8.0` raises the profile schema to v10, which both hosts
already use or migrate to in memory. The v0.8.1 bump rebuilt `dotlink-0.8.1`
from source (about 1m25s) because the fixed binary was not yet in the cache. The
v0.9.0 bump likewise rebuilt `dotlink-deps`/`dotlink` from source. The v0.10.0
bump again rebuilt `dotlink-deps-0.10.0` and `dotlink-0.10.0` from source; it is
not shared across hosts beyond the local store/cache.

## KVM and GPU access

The v0.9.0 update adds opt-in `hostAccess.kvm` (boolean) and `hostAccess.gpu`
(list of `amd`/`nvidia`) options. Both hosts enable both, since each runs AMD
(ROCm) and NVIDIA llama.cpp/Ollama backends and boots the `kvm-amd` module. The
flags expose `/dev/kvm` and the vendor-matched GPU character devices plus
read-only driver resources to the Bubblewrap shell sandbox; they do not affect
ordinary filesystem grants or shell networking. A request for absent hardware
fails loudly, so the grant must match the host's real devices. Profile schema
v10 stores the additive `permissions.allow_kvm` and `permissions.allow_gpu`
fields, so the hosts' saved profiles remain compatible.

## Validation

- `nix eval --raw .#nixosConfigurations.pvl-a1.config.system.build.toplevel.drvPath`
  and the same for `pvl-l5` and `pvl-x2` evaluate.
- `nix eval` confirms `services.dotlink.user = "pvl"`, `workingDirectory`
  (`/home/pvl/spaces/abird/` on a1/l5, `/home/pvl/src/` on x2), an unset
  `profile`, and the unit's
  `User`/`WorkingDirectory`/`SetLoginEnvironment`/`ExecStart`.
- `nix build .#nixosConfigurations.<host>.config.services.dotlink.package`
  succeeds and `dotlink --version` reports `dotlink v0.13.1`.
- a1/l5 evaluate to the same generated `ExecStart` with `--allow-shell`,
  `--allow-nix-daemon`, `--allow-nix-config`, `--allow-ssh-agent`,
  `--allow-git-config`, `--allow-kvm`, `--allow-gpu=amd`, `--allow-gpu=nvidia`,
  and the thirteen `--allow-cache-<kind>=rw` grants, plus
  `SupplementaryGroups = [ "kvm" "render" "video" ]`, and no `DOTLINK_CONFIG`
  (profile reuse).
- `pvl-x2` renders the same flags except `--allow-gpu=amd` only, with
  `WorkingDirectory = /home/pvl/src/`.
