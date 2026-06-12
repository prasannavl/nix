# AGENTS.md

## Tasks management

- Use `.agents/docs/` to document tasks and related context.
- Use `.agents/docs/README.md` as the canonical top-level index of
  `.agents/docs/**`.
  - Keep it updated whenever files are added, removed, renamed, or moved under
    `.agents/docs`.
  - Agents should consult this index first to decide what to load into context.
- Use `.agents/docs/lang-patterns/` for language-specific coding rules and
  conventions.
  - When working in a language, agents should scan the matching
    `.agents/docs/lang-patterns/<language>.md` files before editing.
  - If a relevant language-pattern file does not exist yet and the user defines
    durable rules for that language, create it and update the index.
- Look at `.agents/docs/design-patterns/` for system design and architectural
  rules and conventions relevant to the task.
- Use `.agents/docs/playbooks` for user-defined, reusable processes.
  - When a user asks to "record a process" (or equivalent), create/update a
    playbook here.
  - Playbooks should be execution-oriented so an agent can run them step-by-step
    later.
  - If a user tweaks a process, update the same playbook (or create a clear
    versioned successor) so the latest procedure is explicit.
- Use `.agents/docs/notes` for task-specific memory and decision logs.
  - Record user interventions, changes in direction, constraints, and key
    decisions.
  - Keep notes scoped to a specific task (one task-focused file, not mixed notes
    across unrelated tasks).
  - Treat `.agents/docs` updates as a closeout gate, not optional follow-up, for
    non-trivial repository work.
  - Before a final response, decide whether the task created durable context:
    root cause, design decision, user correction, migration/deploy finding,
    reusable validation sequence, or a changed ownership boundary.
  - If yes, create or update the appropriate note under `.agents/docs/notes/**`
    and update `.agents/docs/README.md` in the same turn.
  - If no durable note is needed for non-trivial work, say that explicitly in
    the final response.
  - Format changed Markdown with the repo formatter before finishing.
- Use `.agents/runs/<session>` as a staging area for temporary edits (inside
  `.agents/docs` or elsewhere) when multiple agents are working in parallel.
  - Near completion, replace target files as atomically as possible.
  - If atomic replacement is not possible, use `.agents/runs/locks` for
    cross-agent file/folder locks.
- For tasks that require multiple steps, or multiple file edits, use a git
  worktree at `worktrees/<session>`, so multiple agents can work in parallel.
  - When the task is done, and I approve to either merge to main branch or
    create a PR, do the final merges and delete the worktree.
- If you have to use tmp files, use `tmp/` dir at the root of our repo and then
  clean up at the end of the session if everything is successful. Otherwise, ask
  user if we should keep them for debugging.
  - We do this for 2 reasons:
    - 1 easier for user to debug if need to.
    - 2 we can easily have the agent have read / write permissions to this
      folder without worrying about external permissions.

## Git

Without user explicit instruction or documented process in a playbook with user
pre-approval:

- Do NOT run git reset --hard, delete branches or other destructive git cmds
- Do NOT commit or push
- Do NOT auto-stage files unless necessary to lint or build, and it doesn't
  overwrite user changes
- Do NOT remove unrelated user changes if code drifts midway

ASK before proceeding with git ops that could lead to data loss or conflicts

## Secrets

### Disallowed

- Never read or attempt to read any of the files with `.key` extension inside
  the tree of `data/secrets`.
- If an action absolutely requires it, or would incidentally require it, stop
  and ask the user before proceeding.

### Allowed

- You may list these files when needed and infer reasonable context from
  filenames.
- Always tell the user you are listing them.
- Never read their contents, directly or indirectly.
