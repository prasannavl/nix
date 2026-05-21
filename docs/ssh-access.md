# SSH Access

Use this document for operator SSH access and deploy SSH routing.

## What This Covers

- operator SSH access to CI host and downstream hosts
- CI host-mediated jump-host access
- per-host user wiring
- local SSH config examples
- deploy SSH routing through `proxyJump`

## Source Of Truth

- operator key metadata: `users/userdata.nix`
- operator user modules: `users/<user>/`
- per-host user imports: `hosts/<host>/users.nix`
- deploy SSH routing: `hosts/nixbot.nix`
- CI host tunnel exposure: `hosts/<ci-host>/cloudflare.nix`

## Access Model

- Operator SSH access is declarative.
- A user's public key lives in `users/userdata.nix`.
- A user module under `users/<user>/` creates the account and installs the key.
- Each host grants access by importing that user module in `users.nix`.
- If access goes through CI host, CI host must import the user too.

Current CI host pattern:

- one designated CI host handles operator ingress
- one CI hostname is exposed through Cloudflare Tunnel

## Grant Operator Access

### 1. Add key metadata

Add the user to `users/userdata.nix`:

```nix
<user> = {
  username = "<user>";
  uid = <uid>;
  name = "<Full Name>";
  email = "<user>@example.com";
  sshKey = "ssh-ed25519 AAAA...";
};
```

This is the source of truth for the user's authorized key.

### 2. Create the user module

Create `users/<user>/` following the existing in-repo user-module pattern.

That module is responsible for creating `users.users.<user>` and installing:

```nix
openssh.authorizedKeys.keys = [userdata.sshKey];
```

### 3. Import the user on target hosts

Add the user import to `hosts/<host>/users.nix` for every host they need to
reach.

Example:

```nix
{
  imports = [
    (import ../../users/<user>).lxc
  ];
}
```

If the user needs CI host-mediated access, import them on CI host too so the
jump-host flow works.

### 4. Deploy in the right order

- Deploy CI host first if CI host access changed.
- Deploy downstream hosts after CI host if the user also needs private-host
  access.

## Test Access

### CI host via Cloudflare Access

Here are the commands to test access, if these work, you can move to ssh config
below to simply connect with just `ssh <host>`.

- The explicit key versions are also provided below if you have multiple SSH
  agents running that may stomp on each other and to test them agnostic of
  agent.
- The disadvantage of explicit key usage is that you may lose convenience of
  automatic caching of passwords, etc that your ssh agents may provide if you
  use the explicit key versions, so prefer the non-explicit versions if possible
  by cleaning up your agents if you have issues with multiple agents.

```bash
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" <user>@<ci-host-hostname>
```

With explicit key:

```bash
ssh -i ~/.ssh/<your-key> -o ProxyCommand="cloudflared access ssh --hostname %h" <user>@<ci-host-hostname>
```

### Private host through CI host

Private hosts needs a proxy jump.

```bash
ssh \
-o 'ProxyCommand=ssh -o "ProxyCommand=cloudflared access ssh --hostname <ci-host-hostname>" <user>@<ci-host-hostname> -W %h:%p' \
<user>@<private-host-ip>
```

With explicit key:

```bash
ssh \
-o 'ProxyCommand=ssh -i ~/.ssh/<your-key> -o IdentitiesOnly=yes -o "ProxyCommand=cloudflared access ssh --hostname <ci-host-hostname>" <user>@<ci-host-hostname> -W %h:%p' \
-o IdentitiesOnly=yes \
-i ~/.ssh/<your-key> \
<user>@<private-host-ip>
```

Both of the above are the conceptual equivalent of:

```bash
ssh -J <ci-host-hostname> -o HostKeyAlias=<private-host-alias> <private-host-ip>
```

However, it needs ssh config for `<ci-host-hostname>` to work, see config below.

## SSH Config

### Minimal

```sshconfig
Host <ci-host-hostname>
  User <user>
  ProxyCommand cloudflared access ssh --hostname %h
```

### Full

Replace `<user>` with your actual username.

```sshconfig
Host <ci-host-hostname> <private-host-pattern>
  User <user>
  # Optional, uncomment if you have to use explicit keys
  # IdentityFile ~/.ssh/<your-key>
  # IdentitiesOnly yes

Host <ci-host-hostname>
  ProxyCommand cloudflared access ssh --hostname %h

Host <private-host-pattern>
  ProxyJump <ci-host-hostname>

Host <ci-host-alias>
  HostName <ci-host-hostname>

Host <private-host-1>
  HostName <private-host-ip-1>
  HostKeyAlias <private-host-1>

Host <private-host-2>
  HostName <private-host-ip-2>
  HostKeyAlias <private-host-2>
```

## Deploy SSH Routing

Use `proxyJump` in `hosts/nixbot.nix` to route deploy SSH through a CI host.

```nix
<host-name> = {
  target = "<host-or-ip>";
  proxyJump = "<ci-host>";
};
```

Use `after` only for deployment ordering. Do not add redundant `after` edges
just to express the network path.

## Operational Sessions

Most services in this repo run as systemd services, so `journalctl` is the
primary way to follow logs.

Typical patterns:

- system services: `sudo journalctl -u <unit> -f`
- recent system-service logs: `sudo journalctl -u <unit> -n 200`
- all logs for the current boot: `sudo journalctl -b`

Examples:

```bash
sudo journalctl -u nixbot-ci.service -f
sudo journalctl -u incus-machines-reconciler.service -n 200
sudo journalctl -u cloudflared.service -f
```

### User Services

Many Podman compose workloads on these VMs run as a dedicated service user under
`systemd --user`.

For tasks that need the user systemd bus, prefer:

```bash
sudo machinectl shell <service-user>@
```

Prefer that over:

```bash
sudo su - <service-user>
```

Reason:

- `machinectl shell <service-user>@` gives you a proper login session with the
  user manager and systemd bus available
- `sudo su - <service-user>` on an SSH session does not reliably initialize the
  user systemd bus
- commands such as `systemctl --user`, `journalctl --user`, and Podman user
  service inspection are more reliable from the `machinectl` session

Examples from the service-user session:

```bash
systemctl --user status <service-user>-web.service
journalctl --user -u <service-user>-web.service -f
systemctl --user status <service-user>-nginx.service
journalctl --user -u <service-user>-nginx.service -n 200
```

If you only need logs and know the exact user unit name, you can also query them
directly from root:

```bash
sudo journalctl --user -M <service-user>@ -u <service-user>-web.service -f
```

## FAQ

### How does deploy reach hosts behind NAT or firewalls?

Use `proxyJump` in `hosts/nixbot.nix` to route deploy SSH through a CI host.
Chain multiple hops with `after` for ordering.

## Related Docs

- [`docs/hosts.md`](./hosts.md)
- [`docs/deployment.md`](./deployment.md)
- [`docs/incus-readiness.md`](./incus-readiness.md)
