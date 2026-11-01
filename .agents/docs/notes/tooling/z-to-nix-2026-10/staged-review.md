# Staged reverse review

- User correction: show each batch as a staged diff, not committed changes on
  its review branch. Pause remains in effect; no additional commit approval.
- Batch 01: `worktrees/z-to-nix-01`, branch `review/z-to-nix-01`, HEAD equals
  nix master `e74e990c`. Review with `git diff --cached` in that worktree.
- Original eight signed commits remain reachable through `agent/z-to-nix-01` at
  `18239f4d`, solely as recovery/history. The initial restored index exactly
  matched checkpoint tree `1c862c17`; subsequent changes only document this
  corrected workflow. Implementation/test bytes and modes remain identical to
  that validated checkpoint.
- Historical batch report, source/path ledgers and events 0001–0002 remain
  unchanged. Read them as the original checkpoint's evidence, not the current
  review branch/commit instructions.
- Batch 02 has no new changes. After batch 01 lands, re-anchor it onto actual
  master before its review. A staged diff compares index to its own HEAD; moving
  master elsewhere does not automatically update that baseline.
- For later prepared candidates, preserve the incremental predecessor tree and
  patch. After its approved predecessor lands, apply only the remaining delta
  onto actual master; preserve intervening user changes. Do not replace main
  with an old cumulative snapshot or create commits merely to hide staging.
- Neither master changes during review. No integration, push, deployment or
  final global compatibility pass is authorized by this format correction.
