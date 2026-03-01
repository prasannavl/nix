# pvl-x2 services.nix YAML source format conversion

## Summary
- Converted `hosts/pvl-x2/services.nix` compose definitions for `immich` from Nix attrset `source`/YAML helper files to explicit YAML string sources.

## Changes
- Replaced `services.immich.source` attrset with a YAML multiline string.
- Replaced `services.immich.files."hwaccel.ml.yml"` attrset with YAML multiline string.
- Replaced `services.immich.files."hwaccel.transcoding.yml"` attrset with YAML multiline string.
- Preserved escaped compose env placeholders as `\${...}` so Nix does not interpolate them.

## Notes
- Existing `beszel`, `dockge`, and `docmost` definitions were already using YAML string `source` format.
