# Markdown

## Scope

- Apply these rules to Markdown files, especially `docs/ai/**/*.md`.

## Formatting authority

- The repo formatter for Markdown is `deno fmt`.
- `treefmt` includes `*.md` and `**/*.md` through the `deno` formatter.
- When an agent creates or edits Markdown, finish by formatting the changed
  Markdown with the repo formatter before concluding the task.
- Acceptable ways to do that are:
  - `deno fmt <paths...>` for targeted Markdown edits.
  - `nix fmt <paths...>` or repo-standard fix flows when broader formatting is
    already being run.

## Lint interaction

- `markdownlint-cli2` enforces Markdown structure and content rules.
- `MD013` line-length linting is disabled in this repo because `deno fmt` owns
  prose wrapping.
- Do not preserve manual wrapping that fights `deno fmt`; prefer formatter-owned
  output.

## Writing conventions

- Keep headings, lists, and fenced code blocks in formatter-stable form.
- Prefer concise durable prose in `docs/ai` notes and playbooks; avoid
  conversational filler.
- When updating `docs/ai`, keep `docs/ai/README.md` in sync with file adds,
  removals, renames, or moves.
