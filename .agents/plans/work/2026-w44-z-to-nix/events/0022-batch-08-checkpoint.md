# Batch 08 checkpoint

- Reviewed 25 commits / 168 first-parent events, including one merge; 200/227
  reverse commits complete. Sixteen owned paths remain staged in review 08.
- Signed logical units: `eec24e79` Stalwart recovery, `12f9aa8e` event
  formatting, `9df47137` review evidence. Final tree
  `9ce141a123c6568a081aa215563c8db50724a9cd` exactly matches the review index.
  Both implementation commits have their own test registrations; the shared
  aggregate's intermediate blob and all three unit trees were verified.
- Canonical format/lint, eight focused checks and all-system no-build/no-IFD
  evaluation passed: 90 x86 Linux checks, 89 ARM Linux, zero Darwin. Existing
  registrations and 70 package derivations preserved; six maintenance wrappers
  intentionally change. No cross-architecture execution claim.
- Evidence includes 36 helper tests, three old-helper controls, fresh disposable
  rootless VM execution (87.68 s), nine formatter-policy cases and actual Deno
  order-sensitive failure controls. Event 0021 records the filtering correction.
- Temporary checkpoint worktree removed normally; checkpoint branch retained.
  Review 08 HEAD, staged delta, file bytes/modes and both masters preserved.
- Review 09 starts from `9df471370a4f4695c2e7a3dbcf1abcb6cc774984`. Main remains
  `9aecdcdc`; batch 08 code is not approved or integrated. Future all-`.agents/`
  batches may integrate only their own delta, never held code.
- No push, deployment or live acceptance. Incus downgrade and Tailscale holds
  remain; final convergence follows the complete frozen queue.
