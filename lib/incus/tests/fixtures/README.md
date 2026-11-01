# Pre-hotplug compatibility fixtures

- `pre-live-proxies-helper.sh.raw`: unmodified historical helper; source only
  against fake Incus. SHA-256:
  `dd4bd7deb754e3d17907c4147002e76f16b03a381f6795d2ee550ebbe659e157`.
- `pre-live-proxies-state.json`: actual historical module output for the initial
  synthetic `web` declaration in `../module.nix`, evaluated with the pinned
  Nixpkgs. Includes Unicode/quote/newline hash inputs and a create-only proxy.
- Historical source revisions `a0458d4e` and `b714b723` have identical Incus
  helper/module/library bytes. Module Git blob:
  `83fcb924416aa437fe3cfa46db5cc49e8d8ea0ec`; library Git blob:
  `af624a44ad98eaed79c7d4303f65098bcd05aa64`.

The helper fixture stays byte-frozen, not a second maintained implementation.
Ordinary JSON formatting is permitted; never regenerate the historical state
from the new implementation. Re-evaluate the archived module with the same
synthetic declaration when deliberately revising the scenario.

Tests check the historical wire/hash contract, execute the old helper across
upgrade/downgrade/re-upgrade, and retain ordinary immutable-drift semantics.
These fixtures contain no production instance state or credentials.
