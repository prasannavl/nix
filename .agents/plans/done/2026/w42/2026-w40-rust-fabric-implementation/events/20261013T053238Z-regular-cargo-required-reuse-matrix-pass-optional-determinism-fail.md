---
type: validation
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-foundation-main
recorded_at: 2026-10-13T05:32:38Z
---

# Regular Cargo required reuse PASS; optional byte determinism FAIL

All six real manager cases passed on original Cargo/rustc/Crane with exact
original baseline recipe identity and nine tested-output absence checks per
independently seeded guest. Nix existing-cache hit compiled nothing; actual
member-build/package binary-cache export/delete/restore preserved the NARs
exactly with max-jobs=0 and remote builders empty. The local unsigned test-cache
signature exception applies only inside the disposable guest.

Unchanged ordinary warm recompilation and changed warm each compiled the agent
and manager only: two workspace, zero external. The edited manager-source probe
returned its expected output in both warm and independent fresh builds. Every
case passed original installed version. The independent fresh cases compiled 226
external messages / 236 total each. No compiler flags, contexts, full
lock/vendor, constructors, product doCheck or wrappers changed.

Both unchanged-recompile and changed-warm/fresh NAR comparisons differ. Under
the explicit human policy they are recorded optional byte-determinism failures,
not required reuse failures. No metadata cause or universal runtime-byte
equality is inferred from this new result. The optional strict mode is retained
and its smoke passed. Full foundation remains incomplete: real
mirror/Abird/platform/ 24-member cost/payback and independent
integration/adoption gates retain their own scopes. No metadata investigation or
archive-reader work is selected.

V1's 300-second cold deadline result remains CLOSED FAILED. V2 selected an
explicit 450-second case limit and unchanged 1800-second global timeout; it ran
after other native checks completed. V2 cold baseline completed in 171.84s. That
difference does not prove a host-contention root cause or original cost. The
actual VM has 7 cores/8GiB per guest; timings are scoped observations only.

Current Source/real-constructor/locality/invalidation checks passed 1,004
assertions with 30 edit-target construction controls. Mirror generator tests
passed 52, fixture tests 28 and native four-variant invalidation passed. The
Abird workspace-policy difference is intentionally preserved. Source-only tests
and a small native fixture do not certify all products or platforms.

## Actual result

```json
{
  "schema": "rust-foundation-required-reuse-acceptance-v1",
  "status": "PASS",
  "fullFoundationComplete": false,
  "regularCargo": {
    "cargoDrv": "/nix/store/05vdg0qyjpk27rf0ijylpz3x5hr0gp2r-cargo-1.95.0.drv",
    "patched": false,
    "productionDefaultChanged": false,
    "upstreamCommit": null
  },
  "managerResult": "/nix/store/9d5az70yxh5zsck5lqxi79kypwg8d033-vm-test-run-rust-foundation-manager-required-reuse-v2-vm",
  "evidence": "/nix/store/fw630dd7hpva1zgwsw3fhd7c0yzhxw6n-rust-foundation-required-reuse-validation-evidence",
  "cases": {
    "baseline": {
      "status": "PASS",
      "mode": "build",
      "elapsedSeconds": 171.84089746698737,
      "workspace": [
        "abird-host-agent",
        "abird-host-manager"
      ],
      "externalCount": 226,
      "totalCount": 236,
      "runtimeChecks": []
    },
    "changed-fresh": {
      "status": "PASS",
      "mode": "build",
      "elapsedSeconds": 147.72424851893447,
      "workspace": [
        "abird-host-agent",
        "abird-host-manager"
      ],
      "externalCount": 226,
      "totalCount": 236,
      "runtimeChecks": [
        {
          "arguments": [
            "--rust-foundation-qualification-probe"
          ],
          "stdout": "rust-foundation-source-edit-20261013\n"
        }
      ]
    },
    "changed-warm": {
      "status": "PASS",
      "mode": "build",
      "elapsedSeconds": 81.64586550497916,
      "workspace": [
        "abird-host-agent",
        "abird-host-manager"
      ],
      "externalCount": 0,
      "totalCount": 2,
      "runtimeChecks": [
        {
          "arguments": [
            "--rust-foundation-qualification-probe"
          ],
          "stdout": "rust-foundation-source-edit-20261013\n"
        }
      ]
    },
    "nix-cache-restored": {
      "status": "PASS",
      "mode": "cache-restore",
      "elapsedSeconds": 3.8465032239910215,
      "workspace": [],
      "externalCount": 0,
      "totalCount": 0,
      "runtimeChecks": []
    },
    "unchanged-cached": {
      "status": "PASS",
      "mode": "cached",
      "elapsedSeconds": 0.29579297499731183,
      "workspace": [],
      "externalCount": 0,
      "totalCount": 0,
      "runtimeChecks": []
    },
    "unchanged-warm": {
      "status": "PASS",
      "mode": "warm-recompile",
      "elapsedSeconds": 84.86205459805205,
      "workspace": [
        "abird-host-agent",
        "abird-host-manager"
      ],
      "externalCount": 0,
      "totalCount": 2,
      "runtimeChecks": []
    }
  },
  "nixCacheReuseValidated": true,
  "byteDeterminism": {
    "required": false,
    "status": "FAIL"
  },
  "unchangedWarmNarEqual": false,
  "changedWarmFreshNarEqual": false,
  "sourceAssertionCount": 1004,
  "pythonTests": {
    "mirror": 52,
    "fixture": 28
  },
  "nativeInvalidationOutput": "/nix/store/9n48wwb3izp334k0aj1xip01w3jcykra-rust-g4-member-invalidation-acceptance",
  "productionDefaultChanged": false
}
```

## Retention

Five dated roots in the existing R work capsule retain the registered manager
result, public validation evidence, native edit result and both smoke results.
They are named
`20261013T053238Z-{manager-result,validation-evidence,
native-invalidation,required-smoke,optional-smoke}`.
Temporary execution files can now be removed; V1 diagnostics remain retained in
the evidence bundle and normal Nix log. No historical private archive or receipt
is retained/reopened by this new selection.
