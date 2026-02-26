# AGENTS.md

## Tasks management

- Use `docs/ai/` to document tasks and related context.
- Use `docs/ai/README.md` as the canonical top-level index of `docs/ai/**`.
  - Keep it updated whenever files are added, removed, renamed, or moved under `docs/ai`.
  - Agents should consult this index first to decide what to load into context.
- Use `docs/ai/playbooks` for user-defined, reusable processes.
  - When a user asks to "record a process" (or equivalent), create/update a playbook here.
  - Playbooks should be execution-oriented so an agent can run them step-by-step later.
  - If a user tweaks a process, update the same playbook (or create a clear versioned successor) so the latest procedure is explicit.
- Use `docs/ai/notes` for task-specific memory and decision logs.
  - Record user interventions, changes in direction, constraints, and key decisions.
  - Keep notes scoped to a specific task (one task-focused file, not mixed notes across unrelated tasks).
- Use `docs/ai/runs/<session>` as a staging area for temporary edits (inside `docs/ai` or elsewhere) when multiple agents are working in parallel.
  - Near completion, replace target files as atomically as possible.
  - If atomic replacement is not possible, use `docs/ai/runs/locks` for cross-agent file/folder locks.
  - Agents waiting on a lock should pause changes on the locked target until release.
  - After another agent releases a lock, treat local context as stale and re-evaluate before continuing.

## Secrets

### Disallowed

- Never read or attempt to read any of the files with `.key` extension inside the tree of `data/secrets`.
- If an action absolutely requires it, or would incidentally require it, stop and ask the user before proceeding.

### Allowed

- You may list these files when needed and infer reasonable context from filenames.
- Always tell the user you are listing them.
- Never read their contents, directly or indirectly.
