# SSH Doc Split And Structure

- Move operator and bastion SSH guidance out of `docs/hosts.md` into a dedicated
  `docs/ssh-access.md` reference doc.
- Keep `docs/hosts.md` focused on host layout, profiles, registration,
  provisioning, and host-type guidance.
- Structure the SSH doc as an engineering reference: source of truth, access
  model, grant workflow, test commands, SSH config examples, deploy routing, and
  SSH-specific FAQ.
- Preserve the existing commands, config snippets, bastion details, and deploy
  `proxyJump` guidance instead of condensing them away.
