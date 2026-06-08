# PVL-A1 Google Cloud SDK Log Streaming (2026-04)

- Replaced the plain `pkgs.google-cloud-sdk` entry in
  `hosts/pvl-a1/packages.nix` with a host-local
  `pkgs.google-cloud-sdk.withExtraComponents` build that includes the
  `log-streaming` component.
- This keeps the install Nix-managed while allowing
  `gcloud beta run services logs tail ...` to work without the blocked
  imperative `gcloud components install log-streaming` flow.
