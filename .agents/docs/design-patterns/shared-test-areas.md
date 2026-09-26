# Shared Test Areas

Shared `lib/`, `pkgs/`, and `scripts/` test areas stay byte-identical across
repositories. Test content is therefore split by ownership instead of by area
alone: generic contract checks stay with their area and stay byte-identical,
while every repository's own test content consolidates in repository-owned
identity homes. Like `external-source-units.md`, this document itself is
byte-tracked across repositories.

## Layout

- `<area>/tests/default.nix` (Python areas: `<area>/tests/test_<tool>.py`) holds
  only generic, host-neutral checks. It may not import repository hosts, stacks,
  configuration composition, or product packages, and it is registered by shared
  wiring such as `lib/tests/default.nix`. Every repository holding the area must
  carry the exact same bytes. Shared test trees may carry repo-only identity
  files beside the shared files (per-stack service files, prefixed sibling
  modules), but shared files never reference or import them, so the shared bytes
  and their registration stay identical everywhere.
- `lib/flake/tests/` holds the flake-lib-level areas only (service moves, phase
  projections, fabric contracts, service-client endpoints, stack folds,
  repository configuration, isolated flake wiring). Its generic files are
  shared; the repository's own flake-level identity content lives in a
  per-topology identity directory `lib/flake/tests/<topology>/` (`abird/` in
  Abird, `pvl/` in Pvl - one directory per named topology, so Gap3 flake-level
  content would live in `gap3/`). The directory's `default.nix` is a pure
  aggregator importing each area file; area files are named after their generic
  counterparts (`phase-projection.nix` beside the shared
  `../phase-projection.nix`), and real-topology fixtures, named-host variants,
  product wiring assertions, and their check registrations live there.
- Service-level identity checks localize with their service: a repo-only
  per-stack file `<service>/tests/<stack>.nix` sits beside the service's shared
  synthetic contracts (for example `lib/services/kanidm/tests/gap3.nix` for the
  real Gap3 OAuth-client fixture), one file per stack, registered through the
  same repository composition as the topology directories. The service's shared
  files stay byte-identical and never reference the per-stack files.
- Identity checks carry the repository prefix (for example `abird-...`), so
  check output shows ownership; generic checks keep the area's shared name.
  Repo-only sibling files in shared Python trees carry the repository prefix in
  their file name (`test_nixbot_pvl.py`); area files inside a topology identity
  directory are named by their area and per-stack service files by their stack,
  because the directory already carries the ownership.

Keeping each identity home where a reader would look - flake-level checks in the
topology's directory under `lib/flake/tests/`, service-level checks with the
service - scales without scattering: the shared trees keep a fixed,
byte-portable file list, identity content sits beside the generic coverage it
instantiates, and a new stack or topology adds one repo-owned file instead of
touching any shared file. It also matches reality: identity checks are
repo-scale integration facts (they import real hosts and stacks), not synthetic
properties of a single area.

## Registration

Identity homes are imported exactly once each, by the repository's check
composition file (`lib/flake/repo-checks.nix`: the topology directories, the
per-stack service files, plus promoted product checks), and reach `checks`
through injection rather than a bridge: the repository manifest (`flake.nix`)
passes that composition as a `repoChecksFn` argument to the shared flake
assembly (`lib/flake/root.nix`, `lib/flake/default.nix`), which merges it into
`checks` after the generic library and flake tests. Every injected argument is
defaulted (empty function, empty list, null), so the shared assembly stays
repository-blind and evaluates without any repository composition: no shared
file references repository identity content, and a repository without identity
content simply passes nothing. The same injection carries the rest of the
repository's composition facts (data-file paths, the input-set input-name table,
extra common NixOS modules, the default machine profile, and the composed
repository configuration `repositoryConfig` read from the repository's
`config/`). The shared flake tests register the generic repository-config
contract check (`lib/flake/tests/repository-config.nix`) only when that
composition is supplied, and a repository's own topology assertions for it live
in its identity directory (`lib/flake/tests/<topology>/config-stacks.nix`).

Shared registration files (`lib/tests/default.nix`, `<area>/tests/default.nix`)
never reference identity content; generic test files register checks as a
function of the library alone. Instantiating flake-library wiring inside an
identity file is expected and cheap: it passes the repository's own
`repoChecksFn` so its assertions cover the same merge the manifest produces, and
its assertions force only that instance's attributes, so no shared file's
evaluation depends on identity content. The instantiation creates an import
cycle (repo-checks.nix -> identity directory -> flake-isolated area file ->
repo-checks.nix) that terminates only by laziness: identity asserts may force
products, promotions, and non-identity checks of the injected instance, never
the instance's identity checks themselves, which would recurse infinitely.

Repository composition lives in repository-owned territory for a hard reason:
byte-identical files cannot name per-repository identity paths. A shared test
file that imported its own repository's identity content would need a different
import line per repository, permanently diverging and requiring hand adaptation
at every port - the exact churn this split removes. (Fixed structural paths that
every repository provides by policy - the `hosts/` tree and the `config/`
composition root the manifest injects - remain byte-nameable precisely because
both repositories carry them; identity content is the part that cannot be
named.) A fixed neutral name referenced from a shared file would keep the bytes
equal but is a service locator Nix does not have: it silently couples shared
evaluation to repository-provided content, places a per-repository divergent
file inside the shared tree, and fails when the file is absent. Indirection can
only move such divergence around, never reduce it. Manifest injection instead
conserves divergence and gives it its cheapest home: `flake.nix` is already
per-repository by nature (its inputs), so declaring repository facts there as
data costs zero new divergence and keeps the invariant absolute - shared
`lib/flake` files are byte-portable, and repository facts flow down as defaulted
arguments. This is also what makes localized per-stack service files safe: since
registration never flows through the service's shared files, a repo-only file
can sit beside them without forcing any shared byte or shared evaluation to
change.

## Documentation rule

Shared test READMEs stay byte-identical: generic contract descriptions only.
Repository-specific acceptance instructions, internal note references, and
product proof commands move into the owning identity file's header comments (the
topology area file, or the per-stack service file) or the repository's own
documentation, never into a shared README or a shared test file.

## Porting rule

When porting test changes between repositories:

1. Adopt generic test files byte-for-byte.
2. Adapt only the repository-owned identity homes (the topology identity
   directory and the per-stack service files), replacing fixtures with the
   destination repository's own topology, and keep them reachable through the
   destination's `repo-checks.nix` and manifest wiring.
3. If a fixture has no destination equivalent, keep the shared synthetic
   coverage instead of leaving a generic file divergent.
4. Never move repository-specific content back into a generic file, a shared
   README, or a shared registration file.

## Worked examples

These are the initial Abird instances of the split; the Pvl analogues follow the
same rules.

- `lib/flake/tests/service-client-endpoints.nix` (generic endpoint and
  firewall-source math, shared bytes) versus
  `lib/flake/tests/abird/service-client-endpoints.nix`'s
  `abird-service-client-endpoints` (real stack SMTP routing and bounded firewall
  integration cases).
- `lib/flake/tests/default.nix` (generic isolated-flake assertions) versus
  `lib/flake/tests/abird/flake-isolated.nix`'s `abird-flake-isolated` (product
  package, module, and standalone-module wiring assertions).
- `lib/flake/tests/phase-projection.nix` and `lib/flake/tests/service-moves.nix`
  (synthetic generic fixtures, shared bytes) versus
  `lib/flake/tests/abird/phase-projection.nix`'s `abird-phase-projection-zulip`
  and `lib/flake/tests/abird/service-moves.nix`'s `abird-service-moves-zulip`
  (real stack, placement, and zulip move contracts against the repository's
  actual hosts and stacks).
- `lib/services/kanidm/tests/default.nix` (synthetic normalization contracts,
  shared bytes) versus `lib/services/kanidm/tests/gap3.nix`'s
  `abird-kanidm-gap3-normalization` (real Gap3 host OAuth-client fixture) and
  its acceptance-proof documentation: the identity check is service-level, so it
  localizes with the kanidm service's own tests as a per-stack file, beside -
  never inside - the shared synthetic contracts.
- `pkgs/tools/nixbot/tests/test_nixbot.py`: synthetic control-plane ordering
  coverage is generic and byte-shared; named-topology ordering variants belong
  in the owning repository's identity home or a repo-only sibling module. Shared
  test mechanics live on the non-collected `NixbotScriptMixin` base, so a
  sibling subclass inherits the helpers without re-running the shared tests.

The Pvl instances: `lib/flake/tests/pvl/flake-isolated.nix`'s
`pvl-flake-isolated` (the `cr` app program assertion for Pvl's codex-wrapper
product, moved out of the shared `tests/default.nix`), the repo-only sibling
`test_nixbot_pvl.py` (named Pvl topology control-plane ordering, moved out of
the shared `test_nixbot.py`; the shared unittest discovery picks it up
automatically), and the kanidm upstream acceptance-proof pointer (moved out of
the shared kanidm README into the identity directory's header documentation).
Pvl carries no service-level identity checks yet; if it gains one, it becomes a
per-stack file under that service's `tests/`.
