# Cloudflare Tunnel Host Wiring 2026-03

Configured hosts directly with native `services.cloudflared.tunnels` entries
instead of a repo-local wrapper module.

Behavior:

- Each host declares `age.secrets` for its tunnel credentials JSON and then
  defines one or more `services.cloudflared.tunnels."<uuid>"` entries.
- This uses the stock NixOS module directly, so multi-tunnel support comes from
  upstream behavior rather than custom glue.

Example shape:

```nix
age.secrets.cloudflare-tunnel-main-credentials = {
  file = ../../data/secrets/cloudflare/tunnels/<host>-main.credentials.json.age;
  owner = "root";
  group = "root";
  mode = "0400";
};

services.cloudflared = {
  enable = true;

  tunnels."00000000-0000-0000-0000-000000000000" = {
    credentialsFile = config.age.secrets.cloudflare-tunnel-main-credentials.path;
    ingress = {
      "app.example.com" = "http://127.0.0.1:3000";
      "api.example.com" = {
        service = "http://127.0.0.1:8080";
        path = "/api/*";
      };
    };
  };
};
```

Current placeholder wiring:

- Placeholder tunnel UUIDs and example routes are used only to show the shape.
- Real UUIDs, hostnames, and credential filenames belong in config and secrets,
  not in docs.

Operational note:

- Tunnel credentials stay in agenix under
  `data/secrets/cloudflare/tunnels/*.credentials.json.age`.
- Ingress hostnames live in tracked host Nix config.
