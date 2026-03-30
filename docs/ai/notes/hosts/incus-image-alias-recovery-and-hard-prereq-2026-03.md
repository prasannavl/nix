# Incus Image Alias Recovery And Hard Prerequisite

**Date**: 2026-03-30

## Summary

Fix the Incus image refresh path so it can recover a missing managed alias from
an existing local image object, and make guest lifecycle units require
`incus-images.service` instead of only wanting it.

## Context

After removing `RemainAfterExit = true` from `incus-images.service`, parent-host
deploys correctly started the image refresh helper on each run. A later deploy
still failed to recreate `pvl-vkamino` from `local:nixos-incus-base`, which
meant the image helper either failed or completed without restoring the alias.

The helper's local-image recovery path was trying to detect an already-imported
image by hashing the metadata and rootfs tarballs itself and then querying Incus
for an image with that fingerprint. That is not the right source of truth for
alias recovery. The module already stores a stable `user.base-image-id` property
on the imported image object itself.

## Decision

- Recover missing aliases by searching `incus image list --format=json` for an
  existing image whose `properties["user.base-image-id"]` matches the declared
  image identity.
- Recreate the missing alias from that image fingerprint when found.
- Fall back to `incus image import ... --alias <alias>` only when no matching
  existing image object is present.
- Make `incus-<guest>.service` `Requires=incus-images.service` so guest create
  does not proceed when image refresh failed.

## Operational Effect

- If a managed alias is deleted out of band while the underlying local image
  object still exists, the next deploy restores the alias instead of trying to
  infer Incus's fingerprint from tarball hashes.
- Guest lifecycle failures now surface image-refresh failures on
  `incus-images.service` directly instead of cascading into a later
  `Image "<alias>" not found` guest error.

## Source of Truth

- `lib/incus/helper.sh`
- `lib/incus/default.nix`
