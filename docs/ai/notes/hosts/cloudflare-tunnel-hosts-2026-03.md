# Cloudflare Tunnel Host Wiring 2026-03

Configured `pvl-x2` and `llmug-rivendell` directly with native
`services.cloudflared.tunnels` entries instead of a repo-local wrapper module.

Behavior:

- Each host declares `age.secrets` for its tunnel credentials JSON and then
  defines one or more `services.cloudflared.tunnels."<uuid>"` entries.
- This uses the stock NixOS module directly, so multi-tunnel support comes from
  upstream behavior rather than custom glue.

Example shape:

```nix
age.secrets.cloudflare-tunnel-main-credentials = {
  file = ../../data/secrets/cloudflare/tunnels/pvl-x2-main.credentials.json.age;
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

- `pvl-x2` uses placeholder tunnel UUID
  `11111111-1111-1111-1111-111111111111` with example routes for
  `memos`, `docmost`, and `vaultwarden`.
- `llmug-rivendell` uses placeholder tunnel UUID
  `22222222-2222-2222-2222-222222222222` with an example route for
  `open-webui`.
- These values are intended to be replaced with real UUIDs, hostnames, and
  credentials filenames.

Operational note:

- Tunnel credentials stay in agenix under
  `data/secrets/cloudflare/tunnels/*.credentials.json.age`.
- Ingress hostnames live in tracked host Nix config.
