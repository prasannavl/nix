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

## Markdown source extraction on 2026-09-23

NVIDIA's Unix driver archive HTML no longer contains the release data. The page
now ships empty `p.PB`/`p.NFB` placeholders that client-side JavaScript fills
from the `gfwsl.geforce.com/services_toolkit` Ajax driver service, so the
previous `<strong>`-delimited HTML scrape stopped matching and every automatic
run failed with `Could not parse the latest Linux x86_64 production branch`.

AEM also publishes the same page as `text/markdown` at
`https://www.nvidia.com/en-us/drivers/unix.md`. The updater consumes that
representation, scopes to the `Linux x86_64` section header (tolerating the
`x86\_64` escaping), and extracts the version from the
`Latest Production Branch Version: [VERSION](...)` link. This keeps the
production-branch semantics while dropping the JavaScript/HTML dependency. The
parser deliberately consumes all input instead of exiting early so `curl` never
sees a `SIGPIPE` under `set -o pipefail`.

## Manual rollback on 2026-09-07

The repository pin was deliberately moved from `595.99.02` back to `595.91.07`
at the user's request. The updater's production-branch discovery behavior
remains unchanged, so a later automatic update may propose a newer production
release.

Validation:

- `lib/ext/nvidia/update.sh --report --color=never`
- `bash -n lib/ext/nvidia/update.sh`
- `shellcheck --external-sources --shell=bash lib/ext/nvidia/update.sh`
