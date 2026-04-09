# SSH Access

Use this document for operator SSH access and deploy SSH routing.

## What This Covers

- operator SSH access to bastion and downstream hosts
- bastion-mediated jump-host access
- per-host user wiring
- local SSH config examples
- deploy SSH routing through `proxyJump`

## Source Of Truth

- operator key metadata: `users/userdata.nix`
- operator user modules: `users/<user>/`
- per-host user imports: `hosts/<host>/users.nix`
- deploy SSH routing: `hosts/nixbot.nix`
- bastion tunnel exposure: `hosts/<bastion>/cloudflare.nix`

## Access Model

- Operator SSH access is declarative.
- A user's public key lives in `users/userdata.nix`.
- A user module under `users/<user>/` creates the account and installs the key.
- Each host grants access by importing that user module in `users.nix`.
- If access goes through bastion, bastion must import the user too.

Current bastion pattern:

- `pvl-x2` is the bastion host
- `z.bastion.com` is exposed through Cloudflare Tunnel

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

Create `users/<user>/` following the existing pattern used by `users/pvl/` or
`users/bush/`.

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
    (import ../../users/<user>).systemd-container
  ];
}
```

If the user needs bastion-mediated access, import them on bastion too. In the
current repo, `pvl-x2` serves `z.bastion.com`, so bastion must include the user
before the jump-host flow works.

### 4. Deploy in the right order

- Deploy bastion first if bastion access changed.
- Deploy downstream hosts after bastion if the user also needs private-host
  access.

## Test Access

### Bastion via Cloudflare Access

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
ssh -o ProxyCommand="cloudflared access ssh --hostname %h" <user>@z.bastion.com
```

With explicit key:

```bash
ssh -i ~/.ssh/<your-key> -o ProxyCommand="cloudflared access ssh --hostname %h" <user>@z.bastion.com
```

### Private host through bastion

Private hosts needs a proxy jump.

```bash
ssh \
-o 'ProxyCommand=ssh -o "ProxyCommand=cloudflared access ssh --hostname z.bastion.com" <user>@z.bastion.com -W %h:%p' \
<user>@10.10.30.10
```

With explicit key:

```bash
ssh \
-o 'ProxyCommand=ssh -i ~/.ssh/<your-key> -o IdentitiesOnly=yes -o "ProxyCommand=cloudflared access ssh --hostname z.bastion.com" <user>@z.bastion.com -W %h:%p' \
-o IdentitiesOnly=yes \
-i ~/.ssh/<your-key> \
<user>@10.10.30.10
```

Both of the above are the conceptual equivalent of:

```bash
ssh -J z.bastion.com -o HostKeyAlias=gap3-rivendell 10.10.30.10
```

However, it needs ssh config for `z.bastion.com` to work, see config below.

## SSH Config

### Minimal

```sshconfig
Host z.bastion.com
  User <user>
  ProxyCommand cloudflared access ssh --hostname %h
```

### Full

Replace `<user>` with your actual username.

```sshconfig
Host z.bastion.com gap3-* llmug-* 
  User <user>
  # Optional, uncomment if you have to use explicit keys
  # IdentityFile ~/.ssh/<your-key>
  # IdentitiesOnly yes

Host z.bastion.com
  ProxyCommand cloudflared access ssh --hostname %h

Host gap3-* llmug-*
  ProxyJump z.bastion.com

Host pvl-x2
  HostName z.bastion.com

Host gap3-rivendell
  HostName 10.10.30.10
  HostKeyAlias gap3-rivendell

Host llmug-rivendell
  HostName 10.10.30.11
  HostKeyAlias llmug-rivendell
```

## Deploy SSH Routing

Use `proxyJump` in `hosts/nixbot.nix` to route deploy SSH through a bastion
host.

```nix
<host-name> = {
  target = "<host-or-ip>";
  proxyJump = "<bastion-host>";
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
sudo journalctl -u nixbot-bastion.service -f
sudo journalctl -u incus-machines-reconciler.service -n 200
sudo journalctl -u cloudflared.service -f
```

### `gap3` User Services

Many Podman compose workloads on these VMs run as the `gap3` user under
`systemd --user`.

For tasks that need the user systemd bus, prefer:

```bash
sudo machinectl shell gap3@
```

Prefer that over:

```bash
sudo su - gap3
```

Reason:

- `machinectl shell gap3@` gives you a proper login session with the `gap3` user
  manager and systemd bus available
- `sudo su - gap3` on an SSH session does not reliably initialize the user
  systemd bus
- commands such as `systemctl --user`, `journalctl --user`, and Podman user
  service inspection are more reliable from the `machinectl` session

Examples from the `gap3` session:

```bash
systemctl --user status gap3-open-webui.service
journalctl --user -u gap3-open-webui.service -f
systemctl --user status gap3-nginx.service
journalctl --user -u gap3-nginx.service -n 200
```

If you only need logs and know the exact user unit name, you can also query them
directly from root:

```bash
sudo journalctl --user -M gap3@ -u gap3-open-webui.service -f
```

## FAQ

### How does deploy reach hosts behind NAT or firewalls?

Use `proxyJump` in `hosts/nixbot.nix` to route deploy SSH through a bastion
host. Chain multiple hops with `after` for ordering.

## Related Docs

- [`docs/hosts.md`](./hosts.md)
- [`docs/deployment.md`](./deployment.md)
- [`docs/incus-readiness.md`](./incus-readiness.md)
