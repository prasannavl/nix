# Markdown

## Scope

- Apply these rules to Markdown files, especially `.agents/docs/**/*.md`.

## Formatting authority

- The repo formatter for Markdown is `deno fmt`.
- `treefmt` includes `*.md` and `**/*.md` through the `deno` formatter.
- When an agent creates or edits Markdown, finish by formatting the changed
  Markdown with the repo formatter before concluding the task.
- Acceptable ways to do that are:
  - `deno fmt <paths...>` for targeted Markdown edits.
  - `nix fmt` for the repository, or `nix fmt -- --project <package>` for a
    package. The wrapper does not accept positional file paths.

Plan events follow ordinary Markdown formatting and linting. Append-only means
preserve historical content and sequence; it does not require preserving raw
whitespace against the repository formatter.

## Lint interaction

- `markdownlint-cli2` enforces Markdown structure and content rules.
- `MD013` line-length linting is disabled in this repo because `deno fmt` owns
  prose wrapping.
- Do not preserve manual wrapping that fights `deno fmt`; prefer formatter-owned
  output.

## Writing conventions

- Keep headings, lists, and fenced code blocks in formatter-stable form.
- Prefer concise durable prose in `.agents/docs` notes and playbooks; avoid
  conversational filler.
- Discover relevant `.agents/docs` subtrees directly; no index file is
  maintained.
