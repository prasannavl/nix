# Docs Sensitive Info Cleanup 2026-03

## Summary

Removed concrete domain names and a personal repository SSH URL from
documentation so those values remain only in configuration and operational
state.

## What Changed

- Replaced the explicit zone list in `tf/README.md` with a reference to
  `zones.auto.tfvars`.
- Reworded the OpenTofu DNS task note to refer to managed zones generically.
- Reworded the nixbot key-rotation playbook to describe repository SSH access
  without embedding the full repo URL.
- Generalized operational docs and AI notes so live hostnames, guest names, and
  example internal addresses no longer appear in prose.

## Notes

- Runtime and configuration files were intentionally left unchanged.
- No secret file contents were read during this cleanup.
