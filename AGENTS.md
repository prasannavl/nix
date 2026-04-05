# AGENTS.md

## Tasks management

- Use `docs/ai/` to document tasks and related context.
- Use `docs/ai/README.md` as the canonical top-level index of `docs/ai/**`.
  - Keep it updated whenever files are added, removed, renamed, or moved under
    `docs/ai`.
  - Agents should consult this index first to decide what to load into context.
- Use `docs/ai/lang-patterns/` for language-specific coding rules and
  conventions.
  - When working in a language, agents should scan the matching
    `docs/ai/lang-patterns/<language>.md` files before editing.
  - If a relevant language-pattern file does not exist yet and the user defines
    durable rules for that language, create it and update the index.
- Look at `docs/ai/design-patterns/` for system design and architectural rules
  and conventions relevant to the task.
- Use `docs/ai/playbooks` for user-defined, reusable processes.
  - When a user asks to "record a process" (or equivalent), create/update a
    playbook here.
  - Playbooks should be execution-oriented so an agent can run them step-by-step
    later.
  - If a user tweaks a process, update the same playbook (or create a clear
    versioned successor) so the latest procedure is explicit.
- Use `docs/ai/notes` for task-specific memory and decision logs.
  - Record user interventions, changes in direction, constraints, and key
    decisions.
  - Keep notes scoped to a specific task (one task-focused file, not mixed notes
    across unrelated tasks).
- Use `docs/ai/runs/<session>` as a staging area for temporary edits (inside
  `docs/ai` or elsewhere) when multiple agents are working in parallel.
  - Near completion, replace target files as atomically as possible.
  - If atomic replacement is not possible, use `docs/ai/runs/locks` for
    cross-agent file/folder locks.
  - Agents waiting on a lock should pause changes on the locked target until
    release.
  - After another agent releases a lock, treat local context as stale and
    re-evaluate before continuing.
- If you have to use tmp files, use `tmp/` dir at the root of our repo and then
  clean up at the end of the session if everything is successful. Otherwise, ask
  user if we should keep them for debugging.
  - We do this for 2 reasons:
    - 1 easier for user to debug if need to.
    - 2 we can easily have the agent have read / write permissions to this
      folder without worrying about external permissions.

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
