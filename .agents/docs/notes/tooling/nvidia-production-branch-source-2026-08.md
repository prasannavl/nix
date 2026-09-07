# NVIDIA Production Branch Source

The NVIDIA extension updater resolves its automatic version from the Linux
`x86_64/AMD64/EM64T` "Latest Production Branch Version" entry on NVIDIA's Unix
driver archive.

Do not use `download.nvidia.com/XFree86/Linux-x86_64/latest.txt` as the update
source. On August 24, 2026, that file reported `595.84` while NVIDIA's Unix
driver archive identified `595.91.07` as the latest production branch release.
Blindly consuming `latest.txt` therefore downgraded the repository pin.

Explicit `--version` requests remain authoritative. Automatic and report-only
runs use the production branch entry for Linux x86_64 and fail without changing
the target when that entry cannot be parsed.

## Manual rollback on 2026-09-07

The repository pin was deliberately moved from `595.99.02` back to `595.91.07`
at the user's request. The updater's production-branch discovery behavior
remains unchanged, so a later automatic update may propose a newer production
release.

Validation:

- `lib/ext/nvidia/update.sh --report --color=never`
- `bash -n lib/ext/nvidia/update.sh`
- `shellcheck --external-sources --shell=bash lib/ext/nvidia/update.sh`
