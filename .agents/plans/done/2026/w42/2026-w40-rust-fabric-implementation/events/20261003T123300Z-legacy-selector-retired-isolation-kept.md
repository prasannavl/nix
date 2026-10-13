---
id: 20261003T123300Z-legacy-selector-retired-isolation-kept
at: 2026-10-03T12:33:00Z
actor: agent:rust-fabric-main
type: decision.recorded
subject: api:legacy-selector-and-qualification-routes
tags:
  - area:rust
  - authority:explicit-human
  - direction:forward-only
  - compatibility:isolated-builds-retained
---

Human clarifies: "yes, let's just remove the legacy mode and routes, but we
should be able to have isolated build support, so keep all of those". This
resolves `20261003T120000Z-forward-only-direction-and-legacy-scope.md`.

Retire production `baseMode="legacy"` selector/alias and active legacy
qualification consumer/build/test/parity routes. Do NOT remove
`useWorkspaceDeps=false`, per-package artifact construction,
standalone/no-workspace/no-Crane/supplied-build behavior, explicit admitted-base
precedence or package-owned isolation. No rename alias substitute. Unknown
retired selector must reject even through lazy/explicit-base branches.
Omitted/null/union/member modes and valid defaults remain unchanged. Historical
logs, reports and append-only events remain historical, not rewritten.

MAIN coordinates documentation/cached validation/review. Implementor
`01a101c2-0e3c-74c4-80f2-1dc04fa1376a` owns production selector plus scoped
composition/source-scope integration tests and narrow helper error/comments.
Implementor `01a101c2-9395-74c4-80f2-1dc3bb37b325` owns qualification modules,
removing active legacy routes and updating constructor controls. No overlapping
ownership. New forward member-only invalidation target remains next phase.

Code-only: no native build/fetch/capture/new compiler/flags/profile or adoption.
No index/stage/commit/integration/publication; 190 staged paths preserved, HEAD
`5ae0baf0`. Existing preparation fixtures remain under owned repo tmp for cached
offline/no-IFD module checks. Successful staging cleaned after closeout.
