# Human Docs Quick Reference Reorg

- Reworked the human-facing Markdown docs to front-load the most commonly needed
  information first: purpose, commands, key rules, and declaration shapes.
- Reduced explanatory and conversational prose in favor of concise,
  developer-oriented reference style.
- Moved detailed lint workflow material out of the main `README.md` into
  `docs/linting.md`.
- Simplified platform docs such as hosts, deployment, Incus, Podman, nginx,
  Terraform, and service-boundary docs so internals and supporting detail come
  after the primary operational guidance.
- Preserved previously documented examples, commands, and internals, but
  restructured detailed sections so they only add information not already
  covered in the quick-reference sections at the top.
