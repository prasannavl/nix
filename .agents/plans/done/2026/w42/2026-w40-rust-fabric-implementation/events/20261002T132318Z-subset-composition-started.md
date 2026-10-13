---
id: 20261002T132318Z-subset-composition-started
at: 2026-10-02T13:23:18Z
actor: agent:rust-fabric-main
type: workstream.claimed
subject: milestone:subset-chaining-and-opt-in-composition
tags:
  - area:rust
  - skill:nix
  - collaboration:parallel
---

# Next code-only phase authorized

Human requested continuation to the next phase. Continue in the retained
worktree, not either master; preserve existing changes and cache defaults.

- `agent:01a0fcc9-487f-74c4-80f2-1c0804ee4d58` owns helper/base tests for
  guarded strict-subset chaining. Existing v1/null paths must stay unchanged.
  Recursive reconstruction validates actual parent outputs; source recipes are
  not certificates. Equal closures, peers, opaque parents and cycles must
  reject.
- `agent:01a0fcc9-8e70-74c4-80f2-1c0a5a1505ff` designs a minimal opt-in
  composition seam read-only. No author inventory, package routing adapter or
  root default flip. Coordinator owns new composition/registration/docs files
  and integrates only after the design result.
- Initial native/default-context restrictions remain. Do not silently broaden
  compiler/native/profile/hook contracts or infer Cargo feature resolution.
- Validate pure mocks and cached real-Crane no-IFD construction, then
  independent review. Additional compilation/capture/fetch/full-root/runtime
  gates remain unapproved. No staging, commits, pushes or new master publication
  in this phase.
