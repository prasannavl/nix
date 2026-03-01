# pvl-x2 Beszel Podman Compose

## Date
- 2026-02-26

## Request
- Add Beszel + Beszel Agent on `pvl-x2` using the `services.podmanCompose` pattern used on `llmug-rivendell`.

## Changes
- Added `hosts/pvl-x2/services.nix` with:
  - `systemd.tmpfiles` directories under `/var/lib/pvl/compose/beszel`
  - `services.podmanCompose.pvl-x2` stack running as user `pvl`
  - `beszel` compose service including both containers:
    - `henrygd/beszel:latest` on `8090:8090`
    - `henrygd/beszel-agent:latest` with `network_mode: host`
    - volumes/environment matching the requested compose spec
- Updated `hosts/pvl-x2/default.nix` imports:
  - Added `../../lib/podman.nix`
  - Added `./services.nix`
- Updated `hosts/pvl-x2/firewall.nix`:
  - Changed Beszel port from `9080` to `8090`.
- Added Dockge service in the same stack:
  - compose service name `dockge` with image `louislam/dockge:1`
  - port `5001:5001`
  - volumes:
    - `/var/run/user/1000/podman/podman.sock:/var/run/docker.sock`
    - `./data:/app/data`
    - `/home/pvl/srv:/home/pvl/srv`
  - environment:
    - `DOCKGE_STACKS_DIR=/home/pvl/srv`
  - tmpfiles directories:
    - `/var/lib/pvl/compose/dockge`
    - `/var/lib/pvl/compose/dockge/data`
  - firewall TCP allowlist includes `5001`.
- Added Docmost compose service (`docmost`) with internal `db` and `redis`:
  - `docmost` image `docker.io/docmost/docmost:latest`, `user: 0:0`, `restart: always`, `3000:3000`
  - env:
    - `APP_URL=https://docs.p7log.com`
    - `APP_SECRET=01230123012301230123012301230123`
    - `DATABASE_URL=postgresql://docmost:STRONG_DB_PASSWORD@db:5432/docmost?schema=public`
    - `REDIS_URL=redis://redis:6379`
  - `db` image `docker.io/postgres:16-alpine`, with `POSTGRES_*` env and persistent `./db-data`
  - `redis` image `docker.io/redis:7.2-alpine`, `user: 0:0`, persistent `./cache`
  - tmpfiles directories:
    - `/var/lib/pvl/compose/docmost`
    - `/var/lib/pvl/compose/docmost/data`
    - `/var/lib/pvl/compose/docmost/db-data`
    - `/var/lib/pvl/compose/docmost/cache`
- Simplified `lib/podman.nix` service API to source/files inputs:
  - `source`: main compose file (string or attrset; attrsets render to YAML)
  - `files`: additional named files (string or attrset; attrsets render to YAML)
  - `entryFile`: compose entry filename (defaults to `compose.yml`)
  - removed service-level `compose`, `composeFiles`, `extraFiles`, `composeFile`, `sourceFile`, and `sourceDir`
- Runtime behavior now uses one codepath:
  - managed files are materialized to source paths (Nix store for text/yaml; direct path for `path` inputs)
  - runtime files in `workingDir` are symlinks to those source paths (no copies)
- Immich now uses:
  - `source` for main compose definition
  - `files` for `hwaccel.ml.yml`, `hwaccel.transcoding.yml`, and `.env`
  - ML backend remains ROCm via `extends` service `rocm` and image suffix `-rocm`

## Notes
- The compose references `/var/run/user/1000/podman/podman.sock` exactly as requested.
- Prefix directories were adjusted to:
  - working/compose root: `/var/lib/pvl/compose`
  - etc source root: `/etc/pvl/compose`
