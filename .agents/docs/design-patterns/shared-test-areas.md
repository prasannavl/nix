# Shared Test Areas

## Generic first

Keep generic checks and fixtures with their reusable component, package or
script. Shared areas carry byte-identical generic checks and registration;
repository acceptance is injected, not an import from a portable owner.

- Generalize reusable behavior before assigning repository ownership. Host names
  in a synthetic inventory do not make an ordering test repository-specific.
- Use neutral fixtures and explicit parameters for behavior, failure paths,
  configuration overrides and package contracts. A generic repository-contract
  check may verify each repository's wrappers against its own declared inputs;
  it must not bake in one repository's revisions or package counts.
- Keep actual host/stack declarations, approved pin snapshots, package
  membership, local default policy and private acceptance ledgers
  repository-owned. Move only those assertions, not an entire mixed suite.
- Preserve every assertion or record its generic replacement. Renaming or moving
  a suite must not make discovery silently skip it or duplicate inherited tests.
- This convention does not require transplanting private product test trees into
  a repository that does not own the product.

## Layout

```text
<area>/tests/
  default.nix                 generic registration
  test_<area>.py              generic Python checks
  fixtures/                   generic fixtures
  abird/                      z-owned assertions and fixtures
    <area>.nix
    test_<area>.py
    __init__.py               when needed for unittest discovery
  pvl/                        nix-owned assertions and fixtures
    <area>.nix
    test_<area>.py
    __init__.py
```

The repository prefix belongs in a subdirectory, not merely a sibling filename.
Do not create an identity directory when its contents can be generic.

- Never import a real repository declaration from an extractable `ab/**` test.
  For example, `ab/services/kanidm/tests/` is portable. Cross-component
  integration stays under `lib/tests/`; real PVL package/topology assertions
  live under `lib/tests/repository/pvl/`.
- Keep language fixtures with the implementation (for example
  `ab/core/packaging/rust/tests/`). See
  [language packaging](language-packaging.md).
- Exercise GC mechanics in `ab/system/nix/tests/`; assert the actual PVL builder
  defaults in `lib/tests/pvl/nix-builder-gc-coordination.nix`. Do not equalize
  production host policy to equalize tests.
- Test upstream-following source recipes with their `lib/ext/<unit>/` owner;
  test repository update commands under `scripts/update/tests/` and operational
  helpers with their `scripts/ops/` owner.
- Shared Nixbot ordering and packaging tests use neutral fixtures/contracts.
  Only the private migration-ledger assertion and its ledger belong under
  `pkgs/tools/nixbot/tests/abird/`.
- Reusable Rust/Bash route data belongs inside the Rust package source boundary,
  with an explicit copy into the Bash sandbox. Generic tests never parse a
  private migration ledger as their fixture source.

## Registration and discovery

- Shared registration stays byte-identical and never names repository identity
  paths. Nix identity checks enter through the repository-owned
  `lib/repo-checks.nix`, injected by `flake.nix` into shared assembly. Default
  injection is empty; identity sources must have disjoint check names.
- Repository composition may register service, library and script identity
  checks directly or through owned aggregators. Keep each check reachable
  exactly once.
- Generic Python discovery may traverse importable repository-prefix packages
  without naming a repository. Add `__init__.py` where required and verify both
  discovery and the actual Nix sandbox. Shared non-collected mixins provide
  helpers without rerunning the generic test class in each identity suite.
- Check names identify ownership (`abird-...`, `pvl-...`) when assertions are
  repository-specific; shared checks retain their generic area names.
- No cross-checkout path, second repository input or credentials are required by
  a shared test. Cross-repository byte comparison is an external validation
  gate, not a runtime dependency of either test suite.

Repository-owned flake identity assertions may instantiate the shared assembly
with their own injected composition. Force products, promotions and generic
checks only, never that instance's identity checks: doing so would recurse
through `repo-checks.nix` into the same identity suite.

## Documentation and maintenance

- Shared test READMEs describe generic contracts only and stay byte-identical.
  Real-host acceptance instructions and private proof references belong in the
  owning prefix subtree or repository documentation.
- Update active imports, fixture paths and discovery when moving tests.
  Historical audit/event content is not rewritten to pretend the new layout
  existed before.
- Use the [cross-sync playbook](../playbooks/nix-z-cross-sync.md) for
  convergence checks. Compare paths, bytes, kinds, modes and symlink targets.
  Reuse native results only when implementation, test and build inputs match.
  Exercise extraction and each repository's own integration and policy; a dated
  receipt cannot qualify a different tree. Different identity coverage is
  legitimate; missing shared coverage is not.
