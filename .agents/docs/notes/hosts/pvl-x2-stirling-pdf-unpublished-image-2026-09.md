# PVL-X2 Stirling-PDF Unpublished Image Pin (2026-09)

## Incident

The 2026-09-29 `fleet deploy --dirty` failed at phase 3 (acquire deployment
artifacts) for `pvl-x2`. The `prefetch-podman-image` helper exhausted its
retries pulling `docker.stirlingpdf.com/stirlingtools/stirling-pdf:3.0.1`, and
every attempt returned:

```text
manifest unknown
```

Commit `c1ded27d` (`chore(pvl-x2): refresh service pins`) changed the
Stirling-PDF pin from `2.14.3` to `3.0.1` and labelled it a major bump. The
upstream GitHub release `v3.0.1` exists, but its container image tag was never
published: the registry's newest comparable tag is `3.0.0`, which `latest` also
points at.

## Root cause

`scripts/support/podman-image-updater.py` resolves repository images that track
GitHub releases through `RELEASE_TAG_REPOSITORIES`. `latest_known_tag` returned
`latest_release_tag` directly, so a GitHub release with no corresponding
registry image was proposed as an update and then written into the Nix pin.

A second latent defect blocked the registry-side guard that would have caught
this: `request_json` sent urllib's default `Python-urllib/3.13` User-Agent, and
the Cloudflare front-end on `docker.stirlingpdf.com` answers that UA with HTTP
403 before the registry can issue its Bearer challenge. Registry tag lookups for
that host could not succeed at all.

## Decision

- Pin Stirling-PDF to the newest published image tag, `3.0.0`.
- Only trust a GitHub release tag when the registry actually carries the
  matching image tag; otherwise fall back to the registry's published tags.
- Send an explicit `HTTP_USER_AGENT` from `request_json` so Cloudflare-fronted
  registries return their normal auth challenge instead of HTTP 403.

## Validation

- `scripts/support/tests/test_podman_image_updater.py` passes (53 tests),
  including a new regression case where GitHub release `v3.0.1` is not yet
  published and the resolver stays on `3.0.0`.
- Live resolution returns `stirling-pdf 2.14.3 -> 3.0.0` (never `3.0.1`) while
  still reporting GitHub `releases/latest` as `3.0.1`.
- The updater's `--report` evaluated the flake and reported
  `stirling-pdf: 3.0.0 [latest]` with no bogus update.
- The remaining operator step is a re-run of the fleet deploy to confirm the
  acquire phase pulls the corrected image.
