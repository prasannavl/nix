# Pi browser tooling comparison

On 2026-09-30 we compared the browser-control options for Pi against the MCP
server the Pvl profiles already run. This note records the capability ladder,
the per-candidate findings that are hard to rediscover, and the decision inputs.
It is a comparison record, not an install record: nothing here is merged into
the profiles yet.

## Premise correction

The profiles do **not** run `chrome-devtools-mcp`. `users/pvl/pi/default.nix`
declares exactly one server, the nixpkgs `playwright-mcp` 0.0.69 with
`--headless --isolated`, written through the shared `~/.config/mcp/mcp.json`.
`chrome-devtools-mcp` is absent from the pinned `nixos-26.05` nixpkgs and from
the Nix store, so adding it means packaging it in this repository.

`--headless --isolated` makes the current setup the **most confined**
configuration in the whole comparison: bundled Playwright Chromium 147,
throwaway profile, no logins, no extensions. Every candidate below reaches
further into the real Chrome environment.

## The Chrome-environment ladder

The question "how constrained, how maximal Chrome" reduces to which rung a tool
can reach. Ranked from least to most real:

- **L0 own ephemeral browser** — bundled Chromium, throwaway profile.
- **L1 own persistent agent profile** — dedicated profile dir that survives, no
  human logins.
- **L2 own profile with human login handoff** — agent profile plus a supported
  "open a real window, sign in, resume" flow.
- **L3 attach to a running debuggable Chrome** — real profile, real logins, real
  extensions, but only when a CDP endpoint exists (`--remote-debugging-port`, or
  Chrome >=144's `chrome://inspect/#remote-debugging` Allow flow).
- **L4 the live Chrome you are using right now** — no flags, no relaunch, the
  normal Chrome process, driven through an extension bridge or the Allow flow.

DevTools _depth_ (tracing, Lighthouse, heap, emulation, raw CDP) is a separate
axis from ladder rung. A tool can sit at L4 with a thin tool surface, or L1 with
the deepest protocol access.

Host context that makes L3/L4 reachable: pvl-l5 and the other graphical hosts
run system Google Chrome 154.0.8037.57 with a populated signed-in profile at
`~/.config/google-chrome/Default`.

## Candidate matrix

| Candidate                             | Kind                                 | Chrome rung                                        | Tools                 | Tool-schema tokens                              | Local transport trust                            |
| ------------------------------------- | ------------------------------------ | -------------------------------------------------- | --------------------- | ----------------------------------------------- | ------------------------------------------------ |
| `playwright-mcp` 0.0.69 (current)     | MCP stdio/HTTP                       | L0                                                 | 21                    | ~3.1k (measured)                                | n/a (own browser); "not a security boundary"     |
| `chrome-devtools-mcp` 1.10.1          | MCP stdio only                       | L1–L3                                              | 29 default / 59 total | ~5.2k default, ~9.7k all, 3 tools with `--slim` | n/a; telemetry **on** by default                 |
| `donsetch` 4.4.1                      | native ext that spawns its own MCP   | L1 only, own ghost profile, `--disable-extensions` | 4                     | ~2.4k                                           | strong SSRF layering; 0600 cookie vault          |
| `pi-browser-use` 0.11.10              | native ext + MCP server              | L2, L3 via bundled extension                       | 33                    | ~6–7k (25,204 B measured)                       | tab bridge `127.0.0.1:31973` **unauthenticated** |
| `@amaster.ai/pi-browser-use` 0.1.22   | native ext + MCP CLI                 | L2, L3 via autoConnect                             | 15 core / 27 default  | ~3.3k core / ~5.9k / ~10k                       | redaction on by default; env inherited           |
| `pi-chrome` 0.15.57                   | native ext + Chrome extension bridge | **L4, no flags**                                   | 23 + raw `chrome_cdp` | ~8k incl. primer                                | HTTP `127.0.0.1:17318` **unauthenticated**       |
| `@narumitw/pi-chrome-devtools` 0.53.4 | native ext, raw CDP                  | L3 attach, L0 isolated launch                      | 8                     | 436 B lazy / 2.4k / 4.3k                        | good: per-call confirm, path confinement         |
| `pi-browser-harness` 0.11.0           | native ext, raw CDP + unix daemon    | L4 via Allow flow / L3                             | 40                    | ~6–8k (10.8k desc chars)                        | unix socket in `/tmp` **unauthenticated**        |

## Findings worth keeping

### Security

- `pi-chrome`: `isLocalProcessRequest` accepts any request lacking `Origin` and
  `Sec-Fetch-Site`, so a plain local `curl` reaches `/command` and can drive the
  browser, including the raw `chrome_cdp` pass-through. The 15-minute
  `/chrome authorize` gate lives in the Pi extension process
  (`requireChromeControlAuthorized`), not in the bridge, so a local non-browser
  caller bypasses the gate entirely. `SECURITY.md` acknowledges the gap. Browser
  origins are correctly rejected.
- `pi-browser-harness`: the daemon listens on `/tmp/pi-browser-daemon.sock` with
  no `chmod`/`umask` and no peer-credential check, so same-host users can
  register as clients and drive Chrome. `browser_run_script` is arbitrary host
  code execution (`AsyncFunction` plus `require`), bounded only by path and
  timeout.
- `pi-browser-use`: the bundled extension's tab bridge on `127.0.0.1:31973` has
  no auth, no `Origin` check, and no CSRF token; persistent mode also launches
  Chrome with `--remote-allow-origins=*` on an ephemeral loopback CDP port that
  is advertised in a sidecar file.
- `chrome-devtools-mcp`: telemetry is **on by default** to Google Clearcut
  (`https://play.googleapis.com/log`), and `--redactNetworkHeaders` defaults to
  **false**, so `get_network_request` exposes `Cookie`/`Set-Cookie`. Both are
  fixable with flags, but the defaults are the wrong way round for this repo.
- `@narumitw/pi-chrome-devtools` is the only candidate with a genuinely careful
  local trust story: page-provided WebMCP descriptors never enter
  provider-visible tool definitions, every WebMCP call is revalidated and
  confirmed, project settings may only replace `extensionPaths`, and screenshot
  paths are confined to cwd or temp.

### Reproducibility under Nix

- `donsetch`: `postinstall` downloads a prebuilt Rust binary from GitHub
  Releases with a co-located SHA-256 (no signature, no pin), and the extension
  spawns it at session start. That cannot work in a Nix build sandbox; it needs
  a fixed-output derivation or a vendored asset. License is AGPL-3.0-only.
- `pi-browser-harness`: the published npm `0.11.0` is stale (2026-08-02). It
  ships `.ts` sources and spawns its own daemon through `node_modules/.bin/tsx`,
  falling back to `npx tsx`; `tsx` is only a `devDependency` there. Repo `main`
  (0.11.1) moves `tsx` into `dependencies`, which is the version to package.
- `@amaster.ai/pi-browser-use` depends on `chrome-devtools-mcp: ^1.6.0`, a
  floating range that resolves to 1.10.1. `pi-browser-use` pins
  `chrome-devtools-mcp` to exactly `1.8.0`, which is the better shape for a
  locked set. Package size is ~1.9 MB unpacked, of which roughly 93% is
  `preview.png`.
- `@narumitw/pi-chrome-devtools` ships a prebuilt `dist/` in the tarball that is
  directly loadable; a source derivation would have to reproduce the monorepo
  `runtime-builder.mjs` + esbuild step.
- `pi-chrome` has zero runtime dependencies and a small closure, making it the
  easiest candidate to package, but it also needs a manual "Load unpacked"
  companion extension inside the real browser profile.

### Behavioural defects confirmed in released versions

- `donsetch` 4.4.1: the extension identifies as `pi-donsetch`, which activates
  the binary's `[meta]` result fold, and then strips that block — losing
  `structuredContent`, so citable URLs, `next_offset`, and resume tokens never
  reach the model. Fixed only in repo `[Unreleased]`.
- `pi-browser-use` 0.11.10: `configToArgs` emits
  `--experimental-page-id-routing`, a flag unknown to the pinned
  `chrome-devtools-mcp` 1.8.0, so page-id routing cannot actually be disabled.
- `@amaster.ai/pi-browser-use` 0.1.22: the bare `{"isolated": true}` setting
  emits `--isolated` together with a default `--user-data-dir`, and upstream
  exits 1. The CLI also excludes 11 tools despite a README claim of "Excluded
  Tools: None".
- `pi-browser-harness` 0.11.0 additionally has stale prompt examples
  (`browser_get_network_log`) and returns screenshots as file paths rather than
  model-visible images. The `@mariozechner/*` peerDependencies are stale
  metadata; modern Pi aliases that scope to `@earendil-works/*`, so they are not
  a load failure.

### Capability gaps

- `@narumitw/pi-chrome-devtools` has only 8 tools: list/select page, navigate,
  evaluate, screenshot, a deferred loader, and two WebMCP gateways. There is no
  click, fill, type, network, or console tool, so it cannot drive a real
  workflow.
- `donsetch` is a web-research tool (fetch, search, crawl, screenshot), not
  browser control. It deliberately uses its own ghost profile with extensions
  disabled and cannot reach the user's live Chrome.
- `chrome-devtools-mcp` is the depth reference: performance traces, Lighthouse,
  heap snapshots, emulation, screencast, network inspection.

## Decision inputs

1. **Cheapest large win: reconfigure the server already installed.** Attaching
   `playwright-mcp` to the real browser (`--cdp-endpoint`, `--extension`, or
   `--user-data-dir` plus `--storage-state`) moves L0 to L2/L3 with a Home
   Manager config edit and no new package. This should be evaluated before
   adding anything.
2. **For a genuine L4 desktop workflow, `pi-chrome` is the best fit.** It is the
   only candidate that reaches the live signed-in Chrome with no restart and no
   debug flag, has zero dependencies, is MIT, and offers raw `chrome_cdp`.
   Costs: manual unpacked-extension onboarding, hard requirement on a visible
   headed window, focus-gated actions, and an unauthenticated loopback port that
   must be treated as a same-user trust boundary.
3. **For headless-capable breadth on the real profile, `pi-browser-harness` is
   second**, but package repo `main` (0.11.1) rather than npm `0.11.0`, and
   treat `browser_run_script` as host RCE when deciding who may run Pi.
4. **Two of the listed packages only wrap `chrome-devtools-mcp`.** If DevTools
   depth is the actual requirement, packaging `chrome-devtools-mcp` in-repo (a
   fixed-output npm tarball with no npm dependencies, plus system Chrome 154)
   and driving it from the existing MCP adapter removes the wrapper risk and two
   moving parts. Pass `--no-usage-statistics` and enable header redaction.
5. **Skip `donsetch`** for this purpose: different category, AGPL, Nix-hostile
   install, and a released citation bug. **Skip `@narumitw/pi-chrome-devtools`**
   on capability grounds unless only read-only inspection is wanted.
6. **Keep `playwright-mcp`** as the deterministic runner. It is the only
   candidate backed by a real test framework, and its isolation is a feature for
   CI-style checks rather than a limitation.

Any browser server remains gated the same way as today: the graphical hosts get
it, the headless Incus containers do not.

## Source material

Full per-candidate reports from the 2026-09-30 review session are under
`tmp/pkgcmp/reports/` (`baseline-mcp-servers.md`, `donsetch.md`,
`pi-browser-use.md`, `amaster-pi-browser-use.md`, `pi-chrome.md`,
`narumitw-pi-chrome-devtools.md`, `pi-browser-harness.md`). Extracted npm
tarballs and shallow clones are under `tmp/pkgcmp/{x,tgz,repos}/`. These are
working artifacts, not durable repo content.

## Validation used

- Package metadata and tarballs pulled from the npm registry, then unpacked
  locally.
- Tool counts and token estimates taken from package sources, from the existing
  `~/.pi/agent/mcp-cache.json` for Playwright, and from measured schema sizes
  where a candidate registers tools eagerly.
- Security findings confirmed by reading the released sources directly
  (`pi-chrome` `index.ts` `isLocalProcessRequest` / `authorizedBridgeSend`;
  `pi-browser-harness` `src/daemon/server.ts` and `src/daemon/protocol.ts`;
  `pi-browser-use` `extension/background.js` and `src/chrome-launcher.ts`).
- Host reality checked with `google-chrome --version`, `~/.config/mcp/mcp.json`,
  and a nixpkgs attribute search that returned no `chrome-devtools-mcp`.
