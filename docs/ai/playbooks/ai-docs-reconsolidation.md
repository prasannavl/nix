# AI Docs Reconsolidation

## Goal

Periodically compress `docs/ai` back into a smaller canonical set by merging
completed `notes` and `runs` into durable notes, keeping reusable procedures in
`playbooks`, and updating the top-level index.

## When To Run

Run this playbook when one or more of these are true:

- `docs/ai/notes/` has accumulated several small overlapping notes in the same
  topic area.
- `docs/ai/runs/` contains completed session artifacts that should no longer be
  treated as active staging state.
- `docs/ai/README.md` has become noisy, flat, or out of sync with the current
  canonical files.
- A migration or investigation thread has stabilized and should be represented
  by one durable note instead of many incremental fragments.

## Core rules

1. Keep `docs/ai/playbooks/` for reusable, execution-oriented procedures.
2. Keep `docs/ai/notes/` for durable task memory, design decisions, lessons, and
   final state.
3. Treat `docs/ai/runs/` as temporary staging or short-lived execution history.
   Once the outcome is durable and settled, fold the important content back into
   notes and remove the run artifacts.
4. Update `docs/ai/README.md` whenever files are added, removed, renamed, or
   moved.
5. Preserve only short provenance in canonical notes; do not keep multiple full
   copies of the same story.
6. Sanitize durable docs so concrete hostnames, domains, bucket names, Worker
   names, and similar operational identifiers are replaced with generic,
   role-based placeholders unless the literal name is required to explain a repo
   path or interface.

## Preparation

1. Read `AGENTS.md`.
2. Read `docs/ai/README.md` first to understand the current documented shape.
3. List the current contents of:
   - `docs/ai/notes/`
   - `docs/ai/playbooks/`
   - `docs/ai/runs/`
4. Identify topic clusters with duplicated or incremental notes.
5. Check whether any `runs/` entries are still active staging work before
   deleting or folding them back.

## Reconsolidation workflow

This workflow is not complete after an index-only pass. A successful run must
review note content for overlapping topic clusters and either merge, reclassify,
or explicitly retain those docs as distinct canonical survivors.

### 1. Find canonical survivors

For each topic cluster:

1. Choose the one note that should remain canonical, or create a new
   consolidated note if none of the existing ones is a clean landing page.
2. Prefer broad, stable filenames that describe the topic rather than one narrow
   sub-step.
3. Keep the surviving note focused on durable information:
   - current shape
   - durable decisions
   - final outcomes
   - lessons worth reusing
4. Do not stop after checking filenames or index coverage; read the overlapping
   notes in each cluster and decide whether the extra files still need to exist
   as separate canonical docs.

### 2. Merge note content

For each superseded note:

1. Copy only durable content into the canonical note.
2. Drop duplicated chronology, transient troubleshooting noise, and repetitive
   intermediate state.
3. Preserve important operational findings, constraints, acceptance gates, and
   final import/adoption outcomes.
4. Add or update a short `Superseded notes` section in the canonical note.

### 2.5. Sanitize durable identifiers

Before finalizing any surviving note or playbook:

1. Replace concrete operational names with generic placeholders where the exact
   live value is not needed, for example:
   - `<bastion-host>` instead of a real bastion hostname
   - `<zone>` instead of a real domain
   - `<bucket>` instead of a real R2 bucket name
   - `<worker>` instead of a specific Worker service name
2. Keep examples executable in structure, but not tied to live naming.
3. Leave real values in runtime/configuration files alone; this sanitization is
   for documentation, notes, and playbooks.
4. If a literal repo path must stay because it is the real interface, explain it
   in generic terms around the path rather than duplicating extra concrete
   prose.

### 3. Reclassify playbooks vs notes

For each document being reviewed:

1. If it is a step-by-step reusable operating procedure, it belongs in
   `docs/ai/playbooks/`.
2. If it is a summary of what was learned, decided, or implemented, it belongs
   in `docs/ai/notes/`.
3. If a note has drifted into procedure-heavy content, either trim it back to
   durable memory or extract the repeatable procedure into a playbook.

### 4. Fold completed runs back into notes

For each completed run folder:

1. Read the markdown manifests and decide which findings are durable.
2. Merge the durable content into the relevant canonical note.
3. Keep only the information that matters long-term, for example:
   - imported resource lists
   - important provider quirks
   - verification outcomes
   - one-time reconciliation decisions
4. Remove temporary run markdowns once their durable content is preserved.
5. Remove temporary state snapshots and other bulky run artifacts when they are
   no longer needed for active work.
6. Delete empty run directories.

### 5. Clean the index

1. Rewrite `docs/ai/README.md` into grouped sections when helpful.
2. Keep the index concise and pointed at canonical files.
3. Do not keep completed run artifacts indexed once they have been folded back
   into notes.
4. Make sure every surviving `docs/ai/**` doc that should be discoverable is
   represented in the index.
5. Make sure index descriptions also stay generic and do not reintroduce live
   identifiers through summaries.

## Verification

1. Re-list `docs/ai/notes/`, `docs/ai/playbooks/`, and `docs/ai/runs/`.
2. Confirm the surviving files match the updated `docs/ai/README.md`.
3. Confirm each remaining doc has a clear home:
   - note
   - playbook
   - active run staging artifact
4. Confirm the canonical notes still contain the important final state from any
   deleted note or run manifest.
5. If `docs/ai/runs/` is empty after cleanup, leave it empty rather than
   reintroducing placeholder clutter.
6. Confirm the surviving docs use generic role-based placeholders instead of
   live hostnames, domains, or other operational names where possible.
7. Run the full repo lint entrypoint before finishing so Markdown and any
   touched hook/config files are checked the same way CI will check them:
   - `nix run .#lint`

## Output expectations

A successful run of this playbook should leave:

- fewer overlapping files under `docs/ai/notes/`
- only reusable procedures under `docs/ai/playbooks/`
- little or nothing under `docs/ai/runs/` unless active staging is in progress
- an updated `docs/ai/README.md` that points at the current canonical set
