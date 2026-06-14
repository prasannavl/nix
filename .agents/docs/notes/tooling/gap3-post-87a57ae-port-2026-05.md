# gap3 Post-87a57ae Port Ledger, 2026-05

## Scope

Selective port of `87a57ae..gap3/master` into this repo.

Current range inventory after the 2026-05-18 refetch from
`git log --reverse --pretty='%h %s'
87a57ae..gap3/master` has 116 commits. Do
not cherry-pick blindly. For each commit, decide whether the change is
applicable here, already represented by a local equivalent, or project-specific
to `gap3`/`abird` and therefore skipped.

Do not read `.key` files under `data/secrets`. Listing paths is allowed when
needed to classify commits.

Closeout validation on 2026-05-18 rechecked the upstream range against this
ledger: all 116 upstream commits are represented, with no missing hashes from
`87a57ae..gap3/master`.

## Review Units

1. Shared nginx proxy features.
2. Podman Compose lifecycle and network hardening.
3. Service module NATS dependency knob.
4. Nixbot parity pass.
5. LXC and Incus parity pass.
6. GCP VM ad hoc tooling.

## Usage Port Notes

- `pvl-x2` nginx should render both derived root proxy vhosts and derived
  `nginxRoutes`, matching the `gap3-rivendell` pattern. Without this, route
  metadata declared on exposed ports is ignored.
- Local upload-capable root vhosts should use the new `clientMaxBodySize` knob
  rather than ad hoc nginx snippets:
  - `docmost`: `250m`, analogous to the upstream docs/attachment route size.
  - `memos`: `100m`, for resource uploads.
  - `vaultwarden`: `100m`, for attachment/import uploads.
- No local pvl-x2/pvl-a1 compose source currently declares
  `networks.default.ipam.config`, so upstream per-stack `subnet` values remain
  skipped as project-specific usage.
- Do not port upstream `authRequest`, Kanidm logout redirect, abird CA TLS, or
  oauth2-proxy route usages unless the matching local service stack exists.
- The `7c2a1403` nixbot state-lock port fixed the observed `primary-ready.nodes`
  rewrite race. A follow-up local health-check hardening now runs post-switch
  health commands through the same prepared transport retry wrapper as
  deploy-time remote commands, because `pvl-vlab-1` can deploy via cached
  bootstrap transport while a one-shot health SSH command still fails.

## Commit Ledger

### Port

| Commit     | Subject                                                    | Unit           | Notes                                                                          |
| ---------- | ---------------------------------------------------------- | -------------- | ------------------------------------------------------------------------------ |
| `f9a6a496` | nginx: fix proxy redirect extra /                          | nginx          | Ported shared nginx route behavior.                                            |
| `da56660f` | nginx: add proxy-buffer size support                       | nginx          | Ported shared nginx and podman-compose option plumbing.                        |
| `4939464b` | nginx: add proxyRedirects, proxyCookiePath                 | nginx          | Ported shared nginx route behavior.                                            |
| `38976888` | nginx: add authRequest support                             | nginx          | Ported shared nginx auth subrequest support.                                   |
| `54863cab` | nginx: add resolver, proxy scheme support                  | nginx          | Ported shared dynamic upstream support.                                        |
| `6c627f7d` | oauth2-proxy: fix internal reachability                    | nginx          | Port only generic route resolver support; skip abird oauth2 service wiring.    |
| `d2197265` | nginx: use abird ca tls                                    | nginx          | Port only generic renderServers listener/preamble hooks; skip abird CA wiring. |
| `87a7b2c3` | nginx, podman-compose: add clientMaxBodySize               | nginx          | Ported shared upload size option.                                              |
| `070a4b79` | nginx: add clientMaxBodySize                               | nginx          | Covered by the local shared `clientMaxBodySize` port.                          |
| `8fc2652c` | podman-compose: add rootless user suid-gid auto migration  | podman-compose | Ported rootless Podman hardening.                                              |
| `fe443bd1` | podman-compose: clash resistant subnet support             | podman-compose | Ported duplicate-subnet guard.                                                 |
| `3474015d` | podman-compose: refine network online ordering             | podman-compose | Ported unit-ordering refinement.                                               |
| `49e4c884` | podman-compose: add ensure semantics to dirBootstrapScript | podman-compose | Ported helper API refinement.                                                  |
| `d205ad5a` | systemd-user-manager: stable state timeout var             | systemd        | Ported configurable stable-state timeout with default `120`s behavior.         |
| `dfb01b70` | service-module: add requireLocalNats                       | service-module | Ported locally as an opt-in hard dependency on `defaultNatsAfter`.             |
| `7c2a1403` | nixbot: refine parallel state locks                        | nixbot         | Ported after deploy exposed a parallel `primary-ready.nodes` rewrite race.     |
| `c492a5f7` | gcp-vms: nixify, add, delete                               | gcp-vms        | Ported as standalone tooling under `pkgs/ext/gcp-vms`.                         |
| `cc05de94` | gcp-vms: cleanup                                           | gcp-vms        | Included in the final local script shape.                                      |
| `5bfaec70` | gcp-vms: free tier guards                                  | gcp-vms        | Included with `--free-tier-max` defaults and validation guards.                |
| `7584cd5f` | nixify-vm: add build-on local, and subt control            | gcp-vms        | Ported nixos-anywhere substitution controls and free-tier generic defaults.    |

### Already Or Equivalent

| Commit     | Subject                                                         | Local State                                                                                                          |
| ---------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `91c3b4cd` | rule: disallow nix path: and prefer git+file for ai evals       | Already represented by local `c38c4c2b`, with repo-specific wording.                                                 |
| `56079a69` | nixbot: post deploy health check refinements                    | Verified present in local nixbot health-check flow.                                                                  |
| `11373c44` | nixbot: add parallel verify jobs                                | Verified present in local nixbot parallel verify support.                                                            |
| `311a252c` | nixbot: refine parallel eval behavior                           | Verified present in local nixbot parallel build/eval flow.                                                           |
| `5e70052d` | nixbot: remove consevative parallel deploy guards               | Verified represented by the local parallel deploy flow.                                                              |
| `832bd018` | nixbot: capture restore tty state, use tty for non-nixbot users | Verified present in local nixbot TTY capture/restore and locking flow.                                               |
| `a1268a66` | nixbot: add dev-build                                           | Verified present in local nixbot `dev-build` action.                                                                 |
| `340f99d6` | nixbot: add proxy cmd support                                   | Verified present in local nixbot `proxyCommand` support.                                                             |
| `2efb177c` | nixbot: better graceful cancellation                            | Verified present in local nixbot cancellation traps and remote activation cancel flow.                               |
| `ab1e6878` | nixbot: health check fixes                                      | Verified present in local nixbot health-check filters and container health checks.                                   |
| `b1f33479` | nixbot: add glob support                                        | Verified present in local nixbot host glob support.                                                                  |
| `343728c4` | conv: systemd-container to lxc                                  | Already represented by local `fd9a2d66`.                                                                             |
| `530c6272` | incus: add cert reconciler                                      | Verified present in local `services.incus-manager.certificates` and helper reconciliation flow.                      |
| `797891b5` | lxc: add intercept mounts                                       | Verified present in local `hosts/pvl-x2/incus.nix` `interceptMounts` support.                                        |
| `0b503a88` | incus: remote delegation                                        | Verified present in local Incus remote mode, certificate delegation, and project-aware query flow.                   |
| `7e3c9193` | lxc: rootless base adaptations                                  | Already represented in `lib/profiles/lxc.nix`: unprivileged mount disables, first-boot link, and activation service. |
| `e6e4ee74` | Fix lints                                                       | Podman-compose formatting already present locally; Abird-specific doc hunk is skipped.                               |
| `2b716d22` | Fix lints                                                       | Covered by current local lint pass after equivalent LXC/Incus handling.                                              |
| `6024f598` | tailscale: add upstream stable pkg                              | Already represented by local Tailscale upstream package/update script work.                                          |
| `7e0102df` | scripts: add update all script                                  | Already represented by local `scripts/update.sh`.                                                                    |
| `50adb47c` | ai: prioritize nix eval disallow path rule                      | Already effectively represented in current `AGENTS.md` and Nix lang pattern.                                         |

### Skip: Refetched Abird Service Work

| Commit     | Subject                        | Reason                                                                  |
| ---------- | ------------------------------ | ----------------------------------------------------------------------- |
| `3d1205e6` | add: mirofish, graphiti, neo4j | New Abird-specific services, DNS, app auth, host docs, and age secrets. |

### Skip: gap3-rivendell Service Configuration

| Commit     | Subject                                     | Reason                                                                            |
| ---------- | ------------------------------------------- | --------------------------------------------------------------------------------- |
| `ff6cd0d7` | outline: enable google sso                  | Host/app-specific gap3-rivendell service and secret wiring.                       |
| `b1bd8e2f` | zulip-parrot: Fix upstream url              | Host-specific service instance.                                                   |
| `b8b246b5` | Enable tg parrot                            | Host-specific service instance and secret.                                        |
| `33df416d` | Fix outline rate limits                     | Host-specific service setting.                                                    |
| `d3b08220` | openwebui: add sso                          | Host-specific app SSO wiring.                                                     |
| `0025e4c2` | Fix mcp integration                         | Host and Cloudflare Access specific wiring.                                       |
| `39896721` | Add kanidm                                  | Host-specific Kanidm service introduction.                                        |
| `7c1fa4b6` | Add: kanidm helpers, stalwart               | Mixed host service introduction; shared libs reviewed separately if needed later. |
| `71af6cdd` | Wire cloudflare access to kanidm            | Project-specific Cloudflare Access state.                                         |
| `0951988a` | kanidm: add domain name                     | Host-specific Kanidm config.                                                      |
| `18f19cb9` | auth: add proxy buffer size                 | Specific Kanidm service use of nginx option; shared option is ported separately.  |
| `b7fdeb99` | Upgrade stalwart, kanidm                    | Host-specific container image/config.                                             |
| `bd91bb9a` | kanidm: fix apply, add verify-idm           | Specific to skipped Kanidm helper stack.                                          |
| `246fbb2e` | Add cloudflare otp in tf                    | Project-specific Cloudflare Access policy.                                        |
| `bf012559` | stalwart: fix port mappings                 | Host-specific service.                                                            |
| `5bfbeede` | Fix stalwart provisioning                   | Host-specific service.                                                            |
| `259691ec` | Extract grafana migration helper, add zulip | Host-specific service migration.                                                  |
| `2bf4db7d` | Switch all services to kanidm auth          | Host-specific app auth migration and secrets.                                     |
| `5f981121` | Fix lints                                   | Only applies to skipped host docs/scripts.                                        |
| `00df3a6a` | Fix lints                                   | Only applies to skipped host services.                                            |
| `a0c03873` | grafana: add reproducable dashboards        | Host-specific Grafana state.                                                      |
| `45bf888c` | openwebui: pin public models                | Host-specific Open WebUI config.                                                  |
| `28174af4` | zulip: fix oidc login                       | Host-specific Zulip service config.                                               |
| `acb26414` | outline: fix oidc logout                    | Host-specific Outline service config.                                             |
| `a28d174a` | nats-streams: fix ordering                  | Package/service not present locally.                                              |
| `69b84f7d` | nats-streams: use requireLocalNats          | Depends on skipped `nats-streams` package; shared knob is ported.                 |
| `7c0eed08` | zulip: fix gap3 subnet                      | Host-specific service config.                                                     |
| `1723db90` | outline: fix data permissions               | Host-specific service config.                                                     |
| `9e9405be` | zulip: fix subnet                           | Host-specific service config.                                                     |
| `a084c4f8` | zulip: remove redundant unshare             | Host-specific service config.                                                     |

### Skip: abird Stack

| Commit     | Subject                                            | Reason                                                                                       |
| ---------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `9f9d9dc6` | abird: setup lxc machines                          | New project-specific hosts and secrets.                                                      |
| `804f56f6` | abird-proxy: init                                  | New project-specific proxy host.                                                             |
| `fcb9b821` | add: abird-ci, wire dns for abird                  | New project-specific host, DNS, tunnel, secrets.                                             |
| `9befe148` | abird.ai: move to abird-apps                       | New project-specific host layout.                                                            |
| `e65a9457` | Add: abird-dev, abird-srv                          | New project-specific hosts.                                                                  |
| `1cfb5c09` | Add kanidm                                         | Project-specific abird Kanidm service.                                                       |
| `b7339eec` | abird: add zulip, outline                          | Project-specific services and secrets.                                                       |
| `e0cc8ebc` | abird nginx: split into multiple units             | Project-specific proxy layout.                                                               |
| `34826bca` | Enable zulip, outline                              | Project-specific services and secrets.                                                       |
| `85aec66c` | kanidm: abstract and automate user config          | Project-specific abird Kanidm layout.                                                        |
| `8b74ae81` | kanidm: auth to zauth.abird.ai                     | Project-specific auth endpoint.                                                              |
| `83f44d3f` | kanidm: auto reconciler                            | Depends on skipped Kanidm stack.                                                             |
| `56a5f345` | Fix kanidm client secrets                          | Secret-only fix for skipped stack.                                                           |
| `15dcd430` | abird: add obs stack, stalwart                     | Project-specific observability/mail stack.                                                   |
| `c3e436ad` | abird-data: add nats, postgres                     | Project-specific data host.                                                                  |
| `3f6a6ffc` | grafana: add idm keys                              | Secret-only fix for skipped stack.                                                           |
| `71b61c9d` | ai: add kanidm playbook                            | Process doc for skipped Kanidm operational stack.                                            |
| `835db4e3` | oauth2-proxy: abird edge access                    | Project-specific auth proxy service.                                                         |
| `2a320dd7` | Fix lints                                          | Only applies to skipped abird docs.                                                          |
| `08670f93` | add: ollama and open web ui                        | Project-specific abird services.                                                             |
| `e06153e0` | Fix lints                                          | Only applies to skipped abird docs.                                                          |
| `7028a10a` | zulip: enable mobile push, expose endpoint         | Project-specific service config.                                                             |
| `623e87d2` | abird: use isolated subnets                        | Project-specific service instance values.                                                    |
| `fc2fecdd` | nginx: remove oauth2 dep, prevent deadlock         | Specific to skipped oauth2-proxy service wiring.                                             |
| `4dd198e3` | stalwart: add basic rules                          | Project-specific mail config.                                                                |
| `6c627f7d` | oauth2-proxy: fix internal reachability            | Skip project-specific oauth2-proxy service wiring; generic nginx resolver support is ported. |
| `d2197265` | nginx: use abird ca tls                            | Skip project-specific CA and internal-edge secret wiring; generic render hooks are ported.   |
| `77ad55fd` | abird: normalize stacks                            | Project-specific stack values.                                                               |
| `70db563e` | abird-corp: add nginx upload routes                | Project-specific route config; shared `clientMaxBodySize` port covers generic part.          |
| `4b012234` | abird-proxy: use clientMaxBodySize for authrequest | Project-specific route usage; shared option port covers generic part.                        |
| `e2e6f4c4` | Add mx routing plan                                | Project-specific planning doc.                                                               |
| `7d0fb48a` | mdlint spec, fix lints nix, kanidm                 | Mostly lint fallout in skipped abird/Kanidm files.                                           |

### Skip: Project, User, Terraform, Docs, And Package Work Not Applicable Now

| Commit     | Subject                                    | Reason                                                                                                          |
| ---------- | ------------------------------------------ | --------------------------------------------------------------------------------------------------------------- |
| `0ad6ffd1` | bots: isolate parrot-core                  | Adds gap3 bot packages not present locally; skip unless those bots are requested.                               |
| `85bbaf7a` | Update docs                                | Docs for upstream state not present here.                                                                       |
| `8bbb3567` | plan: service registry + dns rollouts      | Planning doc for upstream service-registry rollout.                                                             |
| `77218825` | remove user: doug                          | User topology differs; do not apply.                                                                            |
| `a3892efc` | cf access: switch to reusable policies     | Project-specific Terraform state.                                                                               |
| `4f9880c2` | cf-access: cleanup policies                | Project-specific Terraform state.                                                                               |
| `f6bb4e29` | Rename user to match idc                   | User topology differs; do not apply.                                                                            |
| `158040d7` | user add: arjit                            | User topology differs; do not apply.                                                                            |
| `381f810a` | ai: live state mutation rules              | Existing docs cover current repo process; revisit only if user wants this policy added.                         |
| `43cee8f7` | ai: durable rule: internal reachability    | Useful upstream process note, but tied to skipped abird/oauth2 work for this pass.                              |
| `376f6f92` | stack: abstract and split into gap3, abird | Project stack architecture not present locally.                                                                 |
| `e003b3b2` | Fix lints                                  | Only applies to skipped docs/stack changes.                                                                     |
| `242db9a8` | ai: add upstream pkg guidance              | Existing local Tailscale note covers the active upstream package case.                                          |
| `d14eec32` | refactor: bastion to ci hosts              | Ported locally as the nixbot CI-host terminology/secret-path migration, retaining local host and repo defaults. |
