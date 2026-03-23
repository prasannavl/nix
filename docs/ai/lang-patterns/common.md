# Common

## Scope

- Apply these rules when a task involves general code-writing practices that are
  not specific to one language.

## Line width

- Default recommendation:
  - cap code at `100` columns
  - cap comments at `80` columns
  - treat `120` columns as the hard maximum
- Prefer the repo or formatter default when a project already standardizes a
  different width.
- Prefer structural wrapping, extracted locals, and smaller expressions before
  asking for a wider limit.
- Allow narrow exceptions for unsplittable content such as URLs, generated
  strings, embedded examples, and syntax where wrapping is materially worse for
  readability.

## Rationale

- `100` columns is a pragmatic middle ground used by modern style guides and
  formatters.
- `80` columns remains a good comment limit because prose wraps better than
  code, and comments often need to stay readable in narrow panes and review
  views.
- `120` columns is a guardrail, not a target.

## Supporting analysis

- For the evidence summary, studies, and style-guide references behind this
  recommendation, see
  `docs/ai/notes/tooling/code-practices-line-width-2026-03.md`.
