# Abird Last-35 Port Audit (2026-07)

Source: `abird/master` at `38416cbd` after fetching on 2026-07-05. Local base
before the port session: `82af9555`.

Scope: audit the newest 35 Abird commits, port reusable shared units into this
repo, and preserve repo-local topology and package-family divergence.

## Ported Logical Units

- Kanidm shared helper: `lib/services/kanidm/helper.sh` now recreates OAuth apps
  when the live public/confidential type drifts from the declaration.
- `systemd-user-manager`: helper and regression tests are byte-identical with
  Abird for managed-user stop mode, explicit failed-start detection, and queued
  start tracking.
- `podman-compose`: helper, module defaults, and tests are byte-identical with
  Abird for anonymous-volume cleanup, rootless DNS/aardvark repair, timed-out
  helper cleanup, pull-error fast failure, restart-loop suppression, and
  file-secret mount defaults for opaque YAML sources.
- Nginx shared services: ingress-composer upstream security-header opt-outs and
  compose forwarded-port defaults are byte-identical with Abird.
- Nixbot: activation-progress heartbeat reporting matches Abird semantically.
  Tests are byte-identical; the shell script carries local shellcheck
  suppressions and one shfmt indentation fix so this repo's changed-file lint
  gate passes.
- Kanidm UI package overlay: app-link refresh/fallback behavior, no-store app
  password requests, and icon surface styling are byte-identical with Abird.
- Service helpers: `lib/services/forgejo/**` and `lib/services/zerobyte/**` were
  copied byte-for-byte from Abird as reusable app reconciliation helpers.
- Local host adaptation: PVL Ollama model-puller user units were changed from
  `Type = "simple"` to `Type = "oneshot"`, mirroring the Abird fix for the same
  service shape.

## Commit Ledger

| Commit                                                      | Classification              | Notes                                                                                                                                                                                               |
| ----------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `f4eb809a fix(stalwart): avoid empty quota roots`           | Already present             | `pkgs/ext/stalwart-server/default.nix` and `imap-quota-empty-root-compat.patch` already matched. Abird mail note skipped.                                                                           |
| `eea638e5 style(docs): format mail note`                    | Skipped                     | Abird host investigation note only.                                                                                                                                                                 |
| `a61b7aa8 feat(robin): enable automatic compaction`         | Skipped                     | Abird Zulip Robin service and host note only.                                                                                                                                                       |
| `c7ebfc48 feat(ai): centralize model storage`               | Skipped                     | Abird AI host storage policy only. No shared helper changed.                                                                                                                                        |
| `232e5572 fix(kanidm): recreate OAuth type drift`           | Ported                      | Shared `lib/services/kanidm/helper.sh` copied for byte parity.                                                                                                                                      |
| `f55eb96f fix(systemd-user): stop as active user`           | Ported                      | Shared `lib/systemd-user-manager/helper.sh` copied for byte parity; local note updated.                                                                                                             |
| `37333256 fix(kanidm-ui): refresh app metadata`             | Ported                      | Shared `pkgs/ext/kanidm-server/app-links.js` and `app-passwords.js` copied for byte parity.                                                                                                         |
| `2a0bb054 feat(corp): add LibreChat and Gatus`              | Skipped                     | Abird corp services, Kanidm app catalog/icons, DNS, registry, and encrypted secret payloads.                                                                                                        |
| `44d905df fix(kanidm): add Gatus launcher icon`             | Skipped                     | Abird Kanidm launcher catalog only.                                                                                                                                                                 |
| `4988f29d fix(podman-compose): clean anon volumes`          | Ported                      | Shared helper/tests copied for byte parity; incident note not byte-copied because it is Abird-host-specific.                                                                                        |
| `c519c81a style(docs): wrap podman note`                    | Adopted as docs context     | No code; durable rule folded into local Podman design-pattern update.                                                                                                                               |
| `afb6ad46 fix(podman-compose): repair rootless DNS`         | Ported                      | Shared helper copied for byte parity.                                                                                                                                                               |
| `08b64440 fix(podman-compose): recover aardvark races`      | Ported                      | Shared helper copied for byte parity.                                                                                                                                                               |
| `96452634 fix(podman-compose): kill stale aardvark daemons` | Ported                      | Shared helper copied for byte parity.                                                                                                                                                               |
| `7649f8d9 fix(corp): repair LibreChat blank secrets`        | Skipped                     | Abird LibreChat service fix only.                                                                                                                                                                   |
| `22b6c0dc fix(podman-compose): identify aardvark daemons`   | Ported                      | Shared helper copied for byte parity.                                                                                                                                                               |
| `1d195d81 fix(podman-compose): kill timed-out helpers`      | Ported                      | Shared module/test changes copied for byte parity.                                                                                                                                                  |
| `619e353a feat(nginx): expose referrer opt-out`             | Ported                      | Shared `lib/services/nginx/ingress-composer.nix` copied for byte parity.                                                                                                                            |
| `c8743f66 fix(proxy): preserve app referrer policy`         | Skipped                     | Abird proxy vhost/app policy only.                                                                                                                                                                  |
| `66470ee9 fix(systemd-user): catch start failures`          | Ported                      | Shared helper/tests copied for byte parity.                                                                                                                                                         |
| `0da1c242 fix(podman-compose): repair stale DNS state`      | Ported                      | Shared helper/module/tests copied for byte parity.                                                                                                                                                  |
| `231ae24a feat(nixbot): report activation progress`         | Ported with lint adaptation | Shared `pkgs/tools/nixbot/nixbot.sh` and tests copied; local shellcheck suppressions and shfmt indentation keep this repo lint-clean.                                                               |
| `6deb460a feat(jitsi): add native Kanidm SSO`               | Skipped                     | Abird Jitsi app, edge forwarding, Kanidm app catalog, DNS, and secret payloads.                                                                                                                     |
| `8d23477d style(docs): format podman DNS note`              | Adopted as docs context     | No code; durable rule folded into local Podman design-pattern update.                                                                                                                               |
| `aa227d85 style(edge): group Jitsi forwarding attrs`        | Skipped                     | Abird edge forwarding style only.                                                                                                                                                                   |
| `62766d56 style(shell): satisfy pre-push lint`              | Ported                      | Shared helper lint cleanup included in byte-parity helper copies.                                                                                                                                   |
| `758b1eed fix(podman-compose): fail fast on pull errors`    | Ported                      | Shared helper/tests copied for byte parity.                                                                                                                                                         |
| `6ef7d6ce fix(ollama): mark model puller oneshot`           | Locally adapted             | Abird host file skipped; analogous PVL Ollama model-puller units changed to `Type = "oneshot"`.                                                                                                     |
| `6f307b25 fix(systemd-user): track queued starts`           | Ported                      | Shared helper/tests copied for byte parity; local note updated.                                                                                                                                     |
| `4d1c1379 fix(podman): stop compose restart loops`          | Ported                      | Shared Podman helper/module/tests copied for byte parity; local design pattern updated.                                                                                                             |
| `67b29ebe fix(jitsi): use published stable images`          | Skipped                     | Abird Jitsi service only.                                                                                                                                                                           |
| `3360dfb8 fix(podman-compose): keep file secret mounts`     | Ported                      | Shared module/test change copied for byte parity; local design pattern updated.                                                                                                                     |
| `1c4473fa fix(jitsi): accept Kanidm token callbacks`        | Skipped                     | Abird Jitsi service only.                                                                                                                                                                           |
| `5253e5a3 feat(abird-corp): add workspace suite`            | Partially ported            | Ported shared Forgejo/ZeroByte helpers, nginx compose mapping, and Kanidm UI styling. Skipped Abird corp services, app catalog/icons, proxy, stack registry, DNS, nest bridge, and secret payloads. |
| `38416cbd fix(auth): use alias app launchers`               | Skipped                     | Abird launcher URLs and Forgejo service restart wiring only.                                                                                                                                        |

## Byte-Parity Targets

These files should remain byte-for-byte identical to `abird/master` after the
port:

- `lib/podman-compose/default.nix`
- `lib/podman-compose/helper.sh`
- `lib/podman-compose/tests/fake_podman.py`
- `lib/podman-compose/tests/module.nix`
- `lib/podman-compose/tests/test_helper.py`
- `lib/services/forgejo/default.nix`
- `lib/services/forgejo/helper.sh`
- `lib/services/kanidm/helper.sh`
- `lib/services/nginx/compose/nginx.conf`
- `lib/services/nginx/ingress-composer.nix`
- `lib/services/zerobyte/default.nix`
- `lib/services/zerobyte/helper.sh`
- `lib/systemd-user-manager/helper.sh`
- `lib/systemd-user-manager/tests/test_helper.py`
- `pkgs/ext/kanidm-server/app-links.js`
- `pkgs/ext/kanidm-server/app-passwords.js`
- `pkgs/ext/kanidm-server/override.css`
- `pkgs/ext/stalwart-server/default.nix`
- `pkgs/ext/stalwart-server/imap-quota-empty-root-compat.patch`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

## Preserved Divergence

- `pkgs/tools/nixbot/nixbot.sh` differs from Abird only by shellcheck
  suppressions for false-positive `SC2016`/`SC2034` lines and the matching shfmt
  indentation change around the activation heartbeat helper.
- Abird hosts, stack registries, proxy vhosts, Terraform DNS, Kanidm launcher
  catalog/icons, and encrypted secret payloads remain Abird-owned.
- Abird app package families under `pkgs/bots`, `pkgs/srv`, `pkgs/labs`,
  `pkgs/web`, and `pkgs/ext/gcp-cloud-run` remain intentionally out of scope.
- Service incident notes that name Abird hosts were not byte-copied. Durable
  shared rules were folded into local design and service notes instead.
