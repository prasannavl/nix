# Kanidm Declarative Provisioning

## Scope

- Files:
  - `lib/services/kanidm/default.nix`
  - `lib/services/kanidm/helper.sh`

## Decision

Kanidm server runtime settings stay in generated `server.toml`, while mutable
identity state is declared in Nix and applied through a generated operator
command. The Nix library serializes the desired state into JSON, and
`lib/services/kanidm/helper.sh` contains the Bash implementation used by the
generated command.

`mkServerConfig` also accepts `ldapBindAddress` so host modules can enable
Kanidm's LDAPS listener without hand-editing the generated server config.

The helper supports declaring:

- domain display name
- people
- service accounts
- groups and exact group membership
- SSH public keys
- POSIX account settings
- OAuthApps, redirect URLs, PKCE policy, and group-to-scope maps

For OAuthApps, do not trust the Kanidm 1.9 CLI exit status from
`system oauth2 get <name>` as the existence check. Against the current 1.10
server, a missing client can return success with `No matching entries`. The
helper must parse JSON and confirm `.attrs.name` contains the requested client
name before deciding to update instead of create.

OAuthApp type is not a mutable display-field update. When a declared app changes
between public and confidential shape, the helper should detect the live
`oauth2_resource_server_public` class, delete the existing OAuth app if the
class no longer matches, recreate it with the right Kanidm create command, and
then reapply landing URL, redirect URLs, PKCE, and scope maps.

Passwords are not declared in Nix. Kanidm credential enrollment should use reset
tokens for people and generated/displayed secrets for service accounts and
OAuthApps.

## Runtime

`mkApplyScript` installs a host-local apply command named by its caller. The
host-specific declared identity state is serialized into generated metadata and
consumed by that command at runtime.

Expected operator flow:

```sh
<kanidm-apply> login-idm-admin
<kanidm-apply> login-system-admin
<kanidm-apply> recover-idm-admin
<kanidm-apply> recover-system-admin
<kanidm-apply> apply
<kanidm-apply> apply-system
<kanidm-apply> apply-idm
<kanidm-apply> verify-idm
<kanidm-apply> reset <person>
<kanidm-apply> service-password <service-account>
<kanidm-apply> oauth-secret <oauth-app>
<kanidm-apply> cli person get <person>
KANIDM_NAME=admin <kanidm-apply> cli system domain show
<kanidm-apply> admin --help
<kanidm-apply> exec kanidmd --help
```

The command defaults come from the generated metadata: `url`, `adminName`, and
`systemAdminName`. The separation matches upstream Kanidm: `admin` manages
system/domain settings, while `idm_admin` manages people, groups, and OAuthApps.
Override `KANIDM_URL`, `KANIDM_NAME`, or `KANIDM_SYSTEM_NAME` when operating
against another server or admin account.

Keep the Kanidm server image version aligned with the host-side `kanidm` CLI
package used by deploy-time reconciliation. The custom server image only ships
`kanidmd`; auto-apply uses the host CLI. A newer server image than the available
CLI can reject freshly recovered credentials as `incorrect password`.

The recovery helpers run `kanidmd recover-account` inside the configured
podman-compose container, defaulting to `kanidm_kanidm_1`. Override
`KANIDM_CONTAINER` if a host uses a different container name. Recovery connects
to the live admin socket from inside the container and passes
`KANIDM_CONFIG_PATH`, defaulting to `/data/server.toml`, so it targets the same
server config as the running service. Bare `kanidmd recover-account <account>`
without a config path can target the wrong default socket/config and generate
credentials that do not authenticate to the live service. Use `cli` for
host-side Kanidm client calls, `admin` for container-side `kanidmd` commands,
and `exec` for arbitrary commands inside the Kanidm container. The daemon logs
`new_password` as a quoted Rust debug string. When capturing it for an age
secret, extract the text after `new_password:` and unquote it with `jq -r .`.

`apply-idm` runs `verify-idm` after reconciliation. Verification reads the live
Kanidm objects back and fails if declared people or service accounts are missing
their declared primary mail, groups are missing declared members, or OAuthApps
are missing declared group-to-scope maps. This keeps Cloudflare Access and app
OIDC failures visible at apply time instead of surfacing later as a missing
`email` claim or missing group scope.

Kanidm's OIDC `email` scope depends on the account mail value. With the current
CLI JSON output, the helper verifies `.attrs.mail[0]` against the first declared
`mail` entry for people.

When deriving Boolean defaults from JSON, preserve explicit `false` values. In
jq, `.pkce // true` treats `false` as absent and re-enables PKCE for clients
that declare `pkce = false`; use an explicit `has("pkce")` check instead.

## Automatic IdM Apply

`mkPasswordAutoApplyScript` wraps a generated apply command for deploy-time
reconciliation by setting auto-apply environment defaults and execing the
generated command's `auto-apply-idm` subcommand. The shell behavior lives in
`lib/services/kanidm/helper.sh`: it waits for `/status`, logs in with a password
read from a runtime secret file, stores the Kanidm CLI token cache in a
temporary directory, and runs the configured auto-apply command. Supported
auto-apply commands are `apply-system` for system/domain settings and
`apply-idm` for people, service accounts, groups, ScimApps, and OAuthApps. The
helper must capture the Kanidm login command status directly; capturing `$?`
after an `if` statement masks failed logins as success and can leave declared
OAuth apps unapplied while the hosting unit reports active.

Auto-apply stamps must be semantic. Do not hash raw store paths for generated
OAuth app icons into the desired stamp: Nix rebuilds can move identical icon
content to new store paths and force a deploy-time `idm_admin` login even when
the declared Kanidm state has not changed. The helper hashes OAuth icon content
beside the canonical JSON state and uses only domain state for `apply-system`.
When changing stamp payloads, keep a one-time legacy stamp migration path so
hosts with already-applied state do not need protected-account password logins
only to refresh local stamp format.

For user and group removals, set `pruneUsers = true` and `pruneGroups = true` in
the declared state. The helper records declared people and groups after each
successful apply. On later applies, it deletes only entries that were present in
that recorded managed set and are no longer declared. This avoids deleting
unrelated/manual accounts when pruning is first enabled.

For declarative service-account and ScimApp removals, set
`pruneServiceAccounts = true` and `pruneScimApps = true`. These flags reconcile
the live category when enabled: undeclared service accounts are deleted except
Kanidm's protected `admin` and `idm_admin` accounts, and undeclared ScimApps are
deleted from `/scim/v1/Application`.

OAuthApps are a separate Kanidm resource from ScimApps. Set
`pruneOauthApps = true` only after the declared `oauthApps` map is known to be
the complete source of truth for that Kanidm instance.

`groupMembers` declares managed memberships on existing groups without taking
over the group's full member set. Pair it with `pruneGroupMembers = true` to
remove members previously added by this declarative state when they disappear
from `groupMembers`. Use `groups.<name>.members` only when the whole group
membership is declarative.

`pruneSshPublicKeys = true` removes previously managed SSH key tags from people
and service accounts when those tags disappear from the declared
`sshPublicKeys`. `pruneOauthRedirectUrls = true` removes undeclared OAuth2
redirect URLs from declared OAuthApps, and `pruneOauthScopeMaps = true` removes
undeclared OAuth2 group-to-scope maps from declared OAuthApps.

This is intentionally scoped to people, service accounts, ScimApps, groups, and
OAuthApps. Domain/system changes still require the explicit operator path
because those use Kanidm's separate `admin` account and are rare enough to
review manually.

When using a local loopback URL for deploy-time apply, set `domain` to the
public Kanidm domain. The helper's verification code uses `KANIDM_DOMAIN` for
SPN checks so group and OAuthApps scope-map verification still expects members
like `person@auth.example.com` instead of `person@127.0.0.1`.
