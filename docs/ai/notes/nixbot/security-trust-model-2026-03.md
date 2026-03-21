# Nixbot security trust model - 2026-03

- Bastion `nixbot` ingress key holders are trusted deploy operators, not merely
  reviewers or low-trust CI callers.
- That trust includes the ability to run arbitrary reachable repo SHAs through
  `--bastion-trigger`, including private branch commits pushed to origin.
- The installed bastion wrapper and default no-reexec behavior reduce exposure
  to arbitrary uploaded shell, but they do not make bastion-trigger operators
  low trust.
- Worktree isolation solves concurrency and shared-checkout safety; it is not a
  restriction on which reviewed/unreviewed Git commits trusted operators may
  execute.
- If the desired policy changes later, the right control is SHA/ref admission
  enforcement, such as restricting bastion-triggered `--sha` to commits
  reachable from `origin/master`.
