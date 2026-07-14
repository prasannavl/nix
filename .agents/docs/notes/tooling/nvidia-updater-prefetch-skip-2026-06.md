# Updater Prefetch Skip

`scripts/update.sh` should keep no-op extension updates cheap. An updater may
perform lightweight release metadata checks to discover the latest version, but
it should exit before artifact prefetches or fake-hash builds when the pinned
version is already current and the target file already contains hashes.

This prevents normal maintenance runs from re-downloading large payloads such as
the NVIDIA runfile, VS Code archives, Stalwart CLI archives, GNOME extension
zips, or Tailscale source/vendor inputs every time the version is unchanged.

Use each updater's `--force` flag when intentionally recomputing hashes for the
same pinned version.
