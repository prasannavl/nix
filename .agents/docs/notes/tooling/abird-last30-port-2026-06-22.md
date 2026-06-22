# Abird Last-30 Port Audit (2026-06-22)

## Scope

Reviewed the last 30 commits on `abird/master` as of 2026-06-22 and ported the
remaining relevant shared implementation into `/home/pvl/src/nix`.

Secret-bearing commits were inspected through Git metadata and path names only.
No `data/secrets/**/*.key` contents were read.

The session started from local `master` at
`9b72f191 fix(podman-compose): fail hard hooks`, with local `master` already
four commits ahead of `origin/master`. The source `abird/master` was
`fdd92457 style: format nixbot docs`.

## Port Session Commits

| Commit     | Subject                            | Result                                                                                                                                                       |
| ---------- | ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `1db4712f` | `feat(kanidm): sync admin helpers` | Ported the remaining shared Kanidm helper/admin wrapper, auto-apply system-state support, and byte-parity formatting for the shared Kanidm UI package files. |

## Commit Ledger

| Abird commit | Subject                                            | Result                                                                                                                                                   |
| ------------ | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `fdd92457`   | `style: format nixbot docs`                        | Adopted/folded. README formatting was already folded into the local nixbot port; Abird-only consolidated nixbot note was skipped.                        |
| `fcb0597e`   | `fix(podman-compose): fail hard hooks`             | Cleanly ported as `9b72f191`. `lib/podman-compose` files are byte-identical.                                                                             |
| `36244bfd`   | `test(systemd-user-manager): cover reconciliation` | Cleanly ported as `01edaa41`. `lib/systemd-user-manager/tests` files are byte-identical.                                                                 |
| `de88459d`   | `test(incus): cover lifecycle policies`            | Cleanly ported as `b324c04a`. `lib/incus/tests` files are byte-identical.                                                                                |
| `8d61b380`   | `feat(nixbot): parallelize rollbacks`              | Adapted as `9f9f91db`. Shared `pkgs/tools/nixbot` code/tests are byte-identical; docs use the local nixbot note path.                                    |
| `0c4f8773`   | `refactor(oauth2-proxy): own kanidm secret`        | Skipped. Abird oauth2-proxy host wiring, Abird secret registry moves, and host docs only.                                                                |
| `133346ab`   | `feat(kanidm): add unified admin wrapper`          | Adopted in `1db4712f` for shared `lib/services/kanidm`; skipped Abird host, secret, and docs payload.                                                    |
| `a6a6f30d`   | `fix(kanidm): enable system admin auto reconcile`  | Skipped. Abird encrypted secret-file path changes only.                                                                                                  |
| `244a92ac`   | `fix(kanidm): export auto-apply env`               | Adopted in `1db4712f` for shared `lib/services/kanidm/default.nix`.                                                                                      |
| `879b56bd`   | `feat(kanidm): auto-apply system state`            | Adopted in `1db4712f` for shared Kanidm auto-apply support; skipped Abird host, secret, and docs payload.                                                |
| `a05e8b0f`   | `style(kanidm): simplify metadata fallback`        | Skipped. Abird `hosts/abird-id` Kanidm config only.                                                                                                      |
| `ddd72dd2`   | `style(docs): format auth notes`                   | Skipped. Abird host docs only.                                                                                                                           |
| `39745eea`   | `docs(auth): record logout behavior`               | Skipped. Abird host/auth docs only.                                                                                                                      |
| `b38c2f07`   | `fix(nginx): refine auth redirect matching`        | Cleanly ported as `6902ca28`. Shared nginx config is byte-identical.                                                                                     |
| `90ad5fe2`   | `feat(nginx): add logout chain routes`             | Cleanly ported as `0e5e2d85` for shared `lib/flake` and `lib/services/nginx`; skipped Abird proxy host route.                                            |
| `00ccb1ad`   | `feat(bulwarkmail): add logout endpoint`           | Cleanly ported as `35647015`. Shared Bulwarkmail package files are byte-identical.                                                                       |
| `516c7f08`   | `feat(kanidm): group app UI`                       | Adopted. Shared package feature existed in `ab0fadea`; `1db4712f` restored byte parity for shared Kanidm UI files. Abird host app catalog/icons skipped. |
| `1d187c43`   | `feat(abird-id): order Kanidm app links`           | Skipped/adopted conceptually. Abird host app catalog/icons skipped; shared ordered OAuth app support already exists as `dc241999`.                       |
| `33beff88`   | `feat(kanidm): add app link metadata`              | Adopted. Feature existed in `ab0fadea`; `1db4712f` restored byte parity for shared Kanidm UI/helper files. Abird host metadata skipped.                  |
| `4e7907b4`   | `fix(auth): quote clear-site-data directive`       | Skipped. Abird proxy host config and docs only.                                                                                                          |
| `4856c425`   | `fix(auth): clear cookies on kanidm logout`        | Adopted as target nginx support in `7c851c63`; skipped Abird proxy/oauth host config and docs.                                                           |
| `6c6b3bb5`   | `fix(nginx): reduce auth header buffers`           | Cleanly ported as `6b059dd3`. Shared nginx compose config is byte-identical.                                                                             |
| `0b3c4a94`   | `fix(nginx): limit auth redirects to documents`    | Adopted as `f5bb5e05` with target-local docs. Shared nginx files are byte-identical.                                                                     |
| `35306236`   | `fix(nginx): allow shared auth cookies`            | Adopted through target nginx commits. Shared nginx compose config is byte-identical; Abird host docs skipped.                                            |
| `74be9fe5`   | `refactor(kanidm): flatten app list`               | Skipped. Abird `hosts/abird-id` app declaration and host docs only.                                                                                      |
| `5a17df55`   | `refactor(kanidm): order app links`                | Adopted as `dc241999` for shared `lib/services/kanidm/default.nix`; skipped Abird app list/docs.                                                         |
| `029b1de8`   | `fix(auth): delegate z-suite auth to edge`         | Skipped. Abird z-suite host auth, secrets, and docs topology only.                                                                                       |
| `4bfbb723`   | `style(docs): format migration notes`              | Already aligned where shared. Migration-manager note has byte parity; README remains repo-specific.                                                      |
| `046b0b0f`   | `docs(abird): record zchat auth loop`              | Skipped. Abird Open WebUI host note only.                                                                                                                |
| `dbb5e606`   | `test(lib): add shared lib checks`                 | Adopted as `9eff2907` with local README adaptation. Shared `lib/flake` and `lib/tests` files are byte-identical.                                         |

## Parity Audit

Byte-for-byte parity with `abird/master` after the port:

- `lib/flake/default.nix`
- `lib/flake/stack/lib.nix`
- `lib/flake/tests/default.nix`
- `lib/incus/tests/fake_incus.py`
- `lib/incus/tests/test_helper.py`
- `lib/podman-compose/helper.sh`
- `lib/podman-compose/tests/module.nix`
- `lib/podman-compose/tests/test_helper.py`
- `lib/services/kanidm/default.nix`
- `lib/services/kanidm/helper.sh`
- `lib/services/nginx/compose/nginx.conf`
- `lib/services/nginx/default.nix`
- `lib/services/nginx/ingress-composer.nix`
- `lib/systemd-user-manager/tests/module.nix`
- `lib/systemd-user-manager/tests/test_helper.py`
- `lib/tests/default.nix`
- `lib/tests/profiles-incus-lxc.nix`
- `pkgs/ext/bulwarkmail/default.nix`
- `pkgs/ext/bulwarkmail/server-logout-route.patch`
- `pkgs/ext/kanidm-server/app-links.js`
- `pkgs/ext/kanidm-server/app-passwords.js`
- `pkgs/ext/kanidm-server/default.nix`
- `pkgs/ext/kanidm-server/forms.js`
- `pkgs/ext/kanidm-server/override.css`
- `pkgs/ext/kanidm-server/style.js`
- `pkgs/tools/nixbot/nixbot.sh`
- `pkgs/tools/nixbot/tests/test_nixbot.py`

Intentional remaining divergences:

- `README.md` and `.agents/docs/README.md` are repo-specific indexes.
- Abird host, stack, OAuth, Kanidm app catalog/icon, z-suite, and proxy files
  under `hosts/abird-*` are topology-specific and were skipped.
- Abird `data/secrets/abird/**` registry and encrypted file moves were skipped.
- Abird-only host/auth/nixbot docs were skipped unless the same durable note
  exists in this repo.

## Validation

- `alejandra --check lib/services/kanidm/default.nix`
- `bash -n lib/services/kanidm/helper.sh`
- `node --check pkgs/ext/kanidm-server/{app-links.js,app-passwords.js,forms.js,style.js}`
- `cmp -s` parity checks for the six newly ported Kanidm files
