---
type: integration
plan: 2026-w40-rust-fabric-implementation
actor: agent:rust-foundation-main
recorded_at: 2026-10-13T15:29:13Z
---

# Main integration and current-input runtime acceptance

The human explicitly approved integration in both main worktrees. Source was
projected selectively with reviewed three-way policy joins, preserving newer
main inputs, product sources, rsync check tools and unrelated concurrent work.
Three signed local commits per repo contain core/tests, mirrors and optional
qualification. Both fresh current-input six-case matrices passed. Actual mirrors
from committed refs match all four routes and current VM identities. Default
routes are unchanged and their existing installed versions passed. Optional byte
determinism remains FAIL; no broad adoption or push was selected.

The canonical plan is closed at
`.agents/plans/archive/2026/2026-w40-rust-fabric-implementation.md`. The done
capsule is `.agents/plans/done/2026/w42/2026-w40-rust-fabric-implementation`.
Pvl's done capsule retains the public historical event stream; Abird retains its
local coordination record and current integration events. Raw private execution
artifacts and unmerged historical staging remain in the original R/A custody
worktrees; no historical worker/read/archive unit was reopened. Those trees are
retained to avoid deleting unmerged local state. Active implementation and all
new work now belong in the two main worktrees.

Publication/push and broad adoption remain separate. No additional qualification
build or compiler metadata investigation is selected for this integrated scope.

```json
{
  "pvl": {
    "revision": "d82fa09bed7678484638a3de2cb3f84b5aed2c04",
    "runtime": "/nix/store/ffia0nfcdpzigd3h2srpsrb2wf4rgxh3-vm-test-run-rust-foundation-pvl-main-integration-16cpu",
    "cases": {
      "baseline": {
        "status": "PASS",
        "seconds": 187.6,
        "external": 224,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "changed-fresh": {
        "status": "PASS",
        "seconds": 231.92,
        "external": 224,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "changed-warm": {
        "status": "PASS",
        "seconds": 127.66,
        "external": 0,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "nix-cache-restored": {
        "status": "PASS",
        "seconds": 9.37,
        "external": 0,
        "workspace": []
      },
      "unchanged-cached": {
        "status": "PASS",
        "seconds": 0.4,
        "external": 0,
        "workspace": []
      },
      "unchanged-warm": {
        "status": "PASS",
        "seconds": 150.76,
        "external": 0,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      }
    },
    "byteDeterminism": {
      "required": false,
      "status": "FAIL"
    }
  },
  "abird": {
    "revision": "544e18818a3456a8858a04db5ff54bd57183e3c2",
    "runtime": "/nix/store/cjqj6ckhwla54xccz8v74az73ykj25j8-vm-test-run-rust-foundation-abird-main-integration-16cpu",
    "cases": {
      "baseline": {
        "status": "PASS",
        "seconds": 225.75,
        "external": 225,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "changed-fresh": {
        "status": "PASS",
        "seconds": 171.4,
        "external": 222,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "changed-warm": {
        "status": "PASS",
        "seconds": 155.19,
        "external": 0,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      },
      "nix-cache-restored": {
        "status": "PASS",
        "seconds": 9.42,
        "external": 0,
        "workspace": []
      },
      "unchanged-cached": {
        "status": "PASS",
        "seconds": 0.43,
        "external": 0,
        "workspace": []
      },
      "unchanged-warm": {
        "status": "PASS",
        "seconds": 141.19,
        "external": 0,
        "workspace": [
          "abird-host-agent",
          "abird-host-manager"
        ]
      }
    },
    "byteDeterminism": {
      "required": false,
      "status": "FAIL"
    }
  }
}
```

Independent final runtime review authenticated both registered outputs, all 12
case logs, exact cache/NAR transport, two-workspace/zero-external warm
frontiers, changed behavior and all four actual mirror-to-VM recipe identity
joins. Retained report:
abird/tmp/rust-foundation-integration-20261013/independent-final-main-runtime-review-v1.json
in the joint integration evidence bundle. No blocker remains in the selected
native-manager scope.
