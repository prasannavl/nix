# Verification

Integrated series on `master` after `7723150f5`:

```text
e1bf92a6f refactor(lint): restore native full checks
03bccfc2f chore(lint): reject literal store-path pins
86093ab34 refactor(ai): simplify consumer bindings
25ef20eb8 fix(age): select identity secrets by name
0cd03cf02 fix(stalwart): build from upstream opentelemetry source
0a393d311 fix(cloudflare): reject invalid stable keys
12244f6d1 docs(ext): record management-style roots
```

Code series tree before this receipt:
`8e3c8295da3eaddc6083cbffc08964043189d98b`. The receipt is the commit that
carries this file, so its own tree hash is not recorded here. All commits
signed.

## Byte equality

`sha256sum` equality with Abird `HEAD` for the seven files adopted verbatim:

- `lib/flake/service-module.nix`
- `lib/services/ai/consumer.nix`
- `lib/services/ai/tests/consumer.nix`
- `pkgs/ext/stalwart-server/default.nix`
- `pkgs/ext/stalwart-server/sources.nix`
- `pkgs/ext/stalwart-server/opentelemetry-git-source.patch`
- `scripts/lint.sh` (also mode `755`)

Interim split verified: `scripts/lint.sh` at Abird `994cf7705` reproduces the
first lint commit exactly, and the follow-up adds only `check_store_path_pins`.

Adapted files: `lib/tests/default.nix` (registration only),
`tf/tests/test_variables.py` (destination interfaces), `pkgs/README.md` and
`external-source-units.md` (shared paragraphs only).

## Executed

- `nix run .#lint` (diff scope): alejandra, deno fmt, shfmt, statix, deadnix,
  shellcheck, self-reference-fetcher, store-path-pins, actionlint, markdownlint,
  tflint, targeted root-flake check including all seven host `drvPath`
  evaluations. Exit 0.
- `nix build .#checks.x86_64-linux.lib-cloudflare-validation` → realized
  `/nix/store/5jb0ln166ip5rgr63s5h0axim2m98h0b-cloudflare-variable-validation`.
- `nix build .#checks.x86_64-linux.lib-ai-consumer-selection` → realized, all
  consumer-contract assertions forced.
- `python3 tf/tests/test_variables.py -v` → 1 test, OK (provider-free, synthetic
  inputs only).
- `nix eval .#packages.x86_64-linux.stalwart-server.drvPath` → resolves; the
  unit was not built.
- `bash -n`, `shellcheck`, `shfmt -d`, `tofu fmt -check -recursive tf`,
  `alejandra --check`, `deno fmt --check` on the changed files.
- Store-path-pin check run in isolation over the full tracked `*.nix`/`*.sh`
  set: 640 files, no offenders, and a throwaway positive control is flagged.

## Limits

- No push, deployment, live probe, credential or guest operation.
- `--full` lint scope, whole-system builds, the Stalwart image build and VM
  checks were not run. Byte equality and focused realizations are not runtime
  acceptance.
- `tf/` was validated by format checks and synthetic variable contracts only; no
  `plan`/`apply` and no state access.
