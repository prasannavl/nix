# pvl-x2 services.nix source format correction to Nix attrsets

## Summary
- Reversed prior YAML-string conversion for `hosts/pvl-x2/services.nix`.
- Compose content is now expressed as Nix attrsets so the module renderer emits YAML.

## Changes
- Converted `services.beszel.source` from YAML string to Nix attrset.
- Converted `services.dockge.source` from YAML string to Nix attrset.
- Converted `services.docmost.source` from YAML string to Nix attrset.
- Converted `services.immich.source` from YAML string back to Nix attrset.
- Converted `services.immich.files."hwaccel.ml.yml"` and `"hwaccel.transcoding.yml"` from YAML strings to Nix attrsets.

## Validation
- Verified all compose `source` entries in this file use attrset form.
- Parsed file with `nix-instantiate --parse` successfully.
