# PVL-X2 Media and Document Services (2026-08)

## Service boundary

- Jellyfin serves movies and videos at `jellyfin.p7log.com`. Kodi Wayland and
  Stremio Linux Shell are native `pvl-x2` desktop clients, not server-side web
  services.
- Navidrome serves music at `navidrome.p7log.com`. Feishin is the locked music
  web client at `music.p7log.com` and connects to that public Navidrome URL from
  the browser.
- Audiobookshelf serves audiobooks and podcasts at `audiobooks.p7log.com`.
- Kavita serves books and reference PDFs at `books.p7log.com`.
- Stirling PDF provides PDF manipulation at `pdf.p7log.com`.
- Paperless-ngx manages ingested documents at `paperless.p7log.com`.

All hosted services use the `pvl` rootless Podman compose stack. Public nginx
and Cloudflare tunnel routes are derived from the Pvl service registry rather
than embedded independently in each proxy configuration.

## Storage boundary

- `/var/lib/pvl/media` is the host-owned shared library root. Its declared
  subdirectories are `audiobooks`, `books`, `documents`, `movies`, `music`,
  `podcasts`, `shows`, and `videos`.
- System tmpfiles owns the complete library layout. Each compose instance also
  stages the exact host bind source it requires before Podman starts. This is an
  ordering requirement: during a NixOS switch, managed user services can start
  before the new `systemd-tmpfiles-resetup.service` has created new paths.
- Jellyfin mounts the entire shared root read-only as `/media`; configure only
  the movie, show, and video subdirectories as Jellyfin libraries.
- Navidrome mounts `music` read-only. Audiobookshelf mounts `audiobooks` and
  `podcasts` read-only. Kavita mounts `books` and `documents` read-only.
- Service configuration, metadata, caches, databases, and generated files stay
  in their service-specific compose working directories.
- Paperless-ngx owns its `data`, `media`, `export`, and `consume` directories.
  Its managed originals are deliberately separate from Kavita's read-only
  reference-document library; importing or exporting between them remains an
  explicit operator action.

Adding library content and importing existing data remain operator actions. No
media or document files are copied by this repository change.

## Runtime and identity boundary

- Jellyfin receives `/dev/dri` for AMD VA-API transcoding. Rootless Podman uses
  `group_add: keep-groups` so the `pvl` user's existing `video` and `render`
  access reaches the container.
- Paperless-ngx uses its supported SQLite layout plus a private Valkey broker.
- Stirling PDF login is enabled. Its initial administrator password and the
  mandatory Paperless secret key are encrypted for administrators and `pvl-x2`
  under `data/secrets/pvl/services/`; plaintext is never repository data.
- Jellyfin, Navidrome, Audiobookshelf, Kavita, and Paperless-ngx retain their
  native first-run administrator flows. This change does not create accounts,
  import content, install third-party SSO plugins, or configure an identity
  provider.
- The Stirling PDF encrypted password is an initial-login bootstrap value. A
  later password change is application state and must be managed through the
  application rather than by editing plaintext configuration.
- Stirling hashes the initial password with bcrypt, so the generated bootstrap
  value must remain at or below bcrypt's 72-byte input limit.

## Initial deployment finding

The first deployment on 2026-08-26 pulled all images and activated the NixOS
generation, but four media services returned Podman status 125. Their compose
bind sources were absent at 17:11 and the new tmpfiles paths appeared at 17:13;
failed-start cleanup then removed the staged compose files. Feishin stayed down
because it correctly depends on Navidrome. Declaring the required bind sources
in each instance's stage metadata closes that ordering gap without a live
runtime workaround.

Stirling PDF independently exited during initial administrator creation because
the original generated password exceeded 72 bytes. The encrypted bootstrap value
was replaced with a 64-byte printable value. No application data cleanup was
performed; the next start retains the generated configuration and retries
initial security setup with the corrected value.
