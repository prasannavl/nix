# Forward port of the Abird tail integrated

- User requested a new forward port of everything Abird produced after the
  frozen `070011e2` source: analyze commit by commit, group into logical units,
  port shared surface byte-for-byte where the destination had not diverged, then
  audit parity.
- Source window `070011e2..c735a7247`: 64 commits (20 first-parent plus a
  44-commit side branch merged at `df8941601`). Abird's own reverse port of nix
  `7723150f` (`3f52a57eb`, `Audit-Source: 7723150f…`) makes six source commits
  `already-adopted`; 50 are skipped as Abird product, plan state, or secrets.
- Eight source commits were adopted: lint native full checks and store-path
  pins, AI consumer bindings, age identity selection, Stalwart opentelemetry
  source, Cloudflare validation tests, and the external-unit root rule. Four are
  partial (Abird host wiring, benchmark notes, Abird variable interfaces
  skipped).
- Seven signed logical commits on `master` after `7723150f5`: `e1bf92a6f`,
  `03bccfc2f`, `86093ab34`, `25ef20eb8`, `0cd03cf02`, `0a393d311`, `12244f6d1`;
  code tree `8e3c8295`; this receipt commit carries the record.
- Gates: canonical `nix run .#lint` diff scope exit 0 including seven host
  `drvPath` evaluations and the new store-path-pin step; Cloudflare and AI
  consumer checks realized; Stalwart `drvPath` evaluated; targeted format checks
  clean. No `--full` lint, whole-system build, image build or VM run.
- Shared parity after the port: `lib/` 548/563, `pkgs/` 488/505 byte/type/mode
  equal. Remaining differences are local policy, infrastructure state, or
  Abird-only product; none is an unclassified transfer gap.
- Preserved: identity/MIT, host/user policy, Dotlink and local inputs, Cargo
  workspace policy, child-flake workspace injections, encrypted channels, tf
  topology, Pvl overlays and plan ownership. No push, deployment, secret access
  or history rewrite. Receipt:
  `.agents/docs/notes/tooling/abird-port-2026-11-followup/`.
