# NVIDIA Production Branch Source

The NVIDIA extension updater resolves its automatic version from the Linux
`x86_64/AMD64/EM64T` "Latest Production Branch Version" entry on NVIDIA's Unix
driver archive.

Do not use `download.nvidia.com/XFree86/Linux-x86_64/latest.txt` as the update
source. On August 24, 2026, that file reported `595.84` while NVIDIA's Unix
driver archive identified `595.91.07` as the latest production branch release.
Blindly consuming `latest.txt` therefore downgraded the repository pin.

Explicit `--version` requests remain authoritative. Automatic and report-only
runs use the tracked branch entry for Linux x86_64 (production by default) and
fail without changing the target when that entry cannot be resolved.

## Markdown source extraction on 2026-09-23

NVIDIA's Unix driver archive HTML no longer contains the release data. The page
now ships empty `p.PB`/`p.NFB` placeholders that client-side JavaScript fills
from the `gfwsl.geforce.com/services_toolkit` Ajax driver service, so the
previous `<strong>`-delimited HTML scrape stopped matching and every automatic
run failed with `Could not parse the latest Linux x86_64 production branch`.

AEM also publishes the same page as `text/markdown` at
`https://www.nvidia.com/en-us/drivers/unix.md`. The updater consumed that
representation, scoped to the `Linux x86_64` section header (tolerating the
`x86\_64` escaping), and extracted the version from the
`Latest Production Branch Version: [VERSION](...)` link.

## Manual rollback on 2026-09-07

The repository pin was deliberately moved from `595.99.02` back to `595.91.07`
at the user's request. The updater's production-branch discovery behavior
remains unchanged, so a later automatic update may propose a newer production
release.

## Ajax lookup and branch selection on 2026-11-17

The `unix.md` mirror is abandoned: on November 17 it still reported `595.91.07`
with `last-modified: Wed, 12 Aug 2026` while the live page reported `620.70.06`
(PB), `615.78.08` (NFB) and `595.45.04` (beta). Query strings and other locales
do not help (`en-gb`/`de-de` are equally stale, `zh-cn` reports `570.153.02`),
so the pin silently looked up to date for three months.

Automatic resolution now queries the same Ajax lookup the archive page uses
(`osID=12&pfid=985`, `numberOfResults=25`, newest first) and classifies exactly
like the page JavaScript, taking the first match per branch:

| `branch`      | predicate                                                            |
| ------------- | -------------------------------------------------------------------- |
| `production`  | `IsRecommended == "1"`                                               |
| `new-feature` | `IsRecommended != "1" and IsFeaturePreview == "1"`                   |
| `beta`        | `IsRecommended != "1" and IsFeaturePreview != "1" and IsBeta == "1"` |

`IsRecommended` outranks the other two flags because the page checks it first.
`numberOfResults=6` (the page's own value) excludes beta releases; 25 covers all
three branches without changing order.

The tracked branch is the `branch` key in `lib/ext/nvidia/sources.nix` (`kind`
was dropped, it had no consumer). `--branch production|new-feature|beta`
(`prod`, `nfb` accepted) overrides it and is written back on update, so
switching branches is a normal updater run. Report lines name the branch when it
is not production (`- nvidia/new-feature: 595.91.07 -> 615.78.08`).

Explicit `--version` requests skip the lookup.

## Artifact availability

Check the runfile at `us.download.nvidia.com` and all three exact-version source
archives with redirect-following HEAD requests before prefetching or announcing
a discovered update. On HTTP 404/410, list every missing artifact. Automatic
discovery keeps the current pin and lets the suite continue; explicit updates
(`--version`, `--branch`, `--force`) fail instead. `--report --version` prints
the caller's comparison without checking availability. Transport errors and
unexpected statuses are fatal. Never substitute older utilities or silently
select another driver release.

Validation:

- `lib/ext/nvidia/update.sh --report --color=never [--branch ...]`
- `bash -n lib/ext/nvidia/update.sh`
- `shellcheck --external-sources --shell=bash lib/ext/nvidia/update.sh`
