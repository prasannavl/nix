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

Validation:

- `lib/ext/nvidia/update.sh --report --color=never`
- `bash -n lib/ext/nvidia/update.sh`
- `shellcheck --external-sources --shell=bash lib/ext/nvidia/update.sh`
