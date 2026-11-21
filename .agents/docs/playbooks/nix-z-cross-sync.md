# Nix ↔ z cross-sync

`nix` (`~/src/nix`, MIT) and `z` (`~/spaces/abird/src/z`, private
infrastructure) share implementation, not repository identity. Neither lineage
is universally canonical. Local cross-remotes are `abird` in nix and `pvl` in z.

## Ownership boundaries

- Shared libraries, package mechanics and generic tests converge byte-for-byte,
  including executable modes and symlink targets.
- Keep host/user policy, topology tests, manifests, overlays, product
  membership, flake input choices and historical evidence under their
  repository's authority. Adapt mixed changes at their existing injection
  boundaries.
- Preserve licensing: nix keeps MIT and open-contribution framing; z keeps its
  private-access/all-rights-reserved framing and no MIT license file.
- Keep shared `AGENTS.md` marker blocks and the `.gitignore` header identical.
  Repository-specific additions belong after their boundary markers.
- Never copy private products, keys, credentials or state into the other lineage
  merely to achieve a tree-wide match.

## Component-tree convergence

- Shared surface: the complete `ab/` tree (`core`, `repo`, `runtime`,
  `services`, `stack`, `system`, generic tests). Compare paths, bytes, file
  kinds, modes and symlink targets; a rename count or successful evaluation is
  not parity.
- Repository composition stays in `nix/`; retain inputs, manifests, host/user
  profiles, cache order, build concurrency and optional qualification policy.
- Exercise exported APIs from separately copied component sources. Metadata and
  `attrNames` checks do not prove extraction.
- Check root/child package parity and explicit dependency overrides. Tests of
  opt-in workspace layering must enable it independently of repository defaults.
- Compare selected destination-host feature/policy values with the committed
  baseline. Do not substitute a fleet build for focused contract checks.

## Review-gated procedure

1. Inspect both statuses, indexes, worktrees and previous port ledgers. Freeze
   explicit source ranges, including merges. Checkpoint only when authorized.
2. Work in isolated target worktrees. Preserve staged work with explicit
   snapshots; do not use repository-global stashes or overwrite unrelated work.
3. Review 25 source commits per batch unless the user changes the boundary.
   Account for every commit and each partial disposition: ported, already
   adopted, adapted or skipped, with reasons and source references.
4. Port coherent implementation/test/caller units. Retain newer destination
   fixes, intentional policy and supported functionality. Do not merge an entire
   divergent repository, replay obsolete layouts or assume chronological newness
   makes one implementation authoritative.
5. Run canonical formatting/lint, affected tests and exact byte/type/mode
   comparisons. Record exclusions, test limits and remaining differences.
6. Stage explicit owned paths, present the diff and ledger, then stop for user
   approval. A request to combine batches is not permission to commit them.
7. Commit only approved units with signing enabled. Reverse-port approved shared
   adaptations as needed; finish with the exhaustive shared-surface audit.
8. Integrate into main only with approval and a clean, verified target. Preserve
   both repositories' history; do not reset, force-push or delete unrelated
   work.

No push, publication, live probe or deployment is implicit in a port or commit
request. Follow the active task's narrower restrictions and approval gates.
