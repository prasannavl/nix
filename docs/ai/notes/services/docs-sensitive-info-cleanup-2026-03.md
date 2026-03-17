# Docs Sensitive Info Cleanup 2026-03

## Summary

Removed concrete operational identifiers from documentation so live names stay
in configuration and operational state instead of durable notes and playbooks.

## What Changed

- Replaced the explicit zone list in `tf/README.md` with a reference to
  `dns.auto.tfvars`.
- Reworded the OpenTofu DNS task note to refer to managed zones generically.
- Reworded the nixbot key-rotation playbook to describe repository SSH access
  without embedding the full repo URL.
- Generalized operational docs and AI notes so live hostnames, guest names, and
  example internal addresses no longer appear in prose.
- Renamed several AI notes so host and zone identifiers no longer appear in the
  docs index solely through note filenames.
- Generalized Cloudflare adoption notes and playbooks to use placeholders such
  as `<zone>`, `<bucket>`, `<worker>`, and `<bastion-host>` instead of concrete
  live names.
- Updated the AI reconsolidation playbook so future cleanup passes include this
  sanitization step by default.

## Notes

- Runtime and configuration files were intentionally left unchanged.
- No secret file contents were read during this cleanup.
- When literal repo paths or interfaces must be shown, keep the structure but
  prefer generic placeholders in the surrounding examples.
