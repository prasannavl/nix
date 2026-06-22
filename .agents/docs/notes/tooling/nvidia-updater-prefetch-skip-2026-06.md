# NVIDIA updater prefetch skip

`lib/ext/nvidia/update.sh` checks NVIDIA `latest.txt` first, compares that
version with `lib/ext/nvidia/default.nix`, and exits before URL validation or
`nix store prefetch-file` when the pinned version is already current.

This keeps the normal `scripts/update.sh` flow from re-downloading the large
`NVIDIA-Linux-x86_64-<version>.run` payload on every run. Use
`lib/ext/nvidia/update.sh --force` when intentionally recomputing hashes for
the same pinned version.
