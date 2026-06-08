---
name: skill-rules
description: "Abird: Rules for repository-local agent skills. Use for .agents skill metadata, registration, naming, and repo-specific skill conventions."
---

# Skill Rules

## Scope

Use this skill for repository-local skills in this repository. Keep personal
skill layout and upstream source management out of this skill; those belong in a
personal skill-rules skill.

## Repository-Local Layout

Store repository-specific skills under `.agents/skills/<skill-name>/`.

Each skill needs `SKILL.md`. Add `agents/openai.yaml` only for UI metadata such
as `display_name` or `default_prompt`.

Do not use tool-specific directories such as `.codex/` for repo-local skills. If
Codex does not auto-discover a repo-local skill, register its `SKILL.md`
explicitly in the relevant agent config.

## Metadata

Keep `SKILL.md` frontmatter concise:

```yaml
---
name: skill-name
description: "Abird: Concise trigger and purpose."
---
```

Use the `Abird:` prefix in repository-local skill descriptions when the skill
could be confused with a personal or generic skill. Quote the description when
it contains `Abird:` or any other colon-bearing prefix.

Do not put user-specific absolute paths in skill definitions. Use
`current
repository root`, `.agents/skills`, or repo-relative paths such as
`.agents/docs/README.md`.

## OpenAI Metadata

Keep `agents/openai.yaml` minimal:

```yaml
interface:
  display_name: "abird-skill-name"
  default_prompt: "Use $skill-name to perform the task."
```

Omit `short_description` unless it intentionally differs from the `SKILL.md`
description. Avoid duplicate descriptions that can drift.

Use `display_name` for visible disambiguation, such as showing `abird-git` while
keeping the internal skill name as `git` for `$git` invocation.

Keep `default_prompt` generic unless project-specific wording is explicitly
needed. Repo context should usually live in the skill body or description.

## Validation Checklist

Before finishing a repository-local skill change:

- Ensure YAML frontmatter parses.
- Ensure `name` is lowercase hyphen-case.
- Ensure `description` is short, quoted when needed, and starts with `Abird:`
  when the skill should be visibly repository-specific.
- Scan for user-specific absolute paths.
- Check `agents/openai.yaml` has no redundant `short_description` unless there
  is a clear reason.
