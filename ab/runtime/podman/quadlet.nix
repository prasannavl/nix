{
  lib,
  pkgs,
}: let
  python = pkgs.python3.withPackages (packages: [packages.pyyaml]);
  compiler = ./quadlet-compiler.py;
in {
  # Compose is intentionally parsed only inside this derivation.  Callers may
  # pass the resulting paths onward, but must not import report.json into Nix
  # evaluation (which would be IFD).
  mkBundle = {
    name,
    config,
  }: let
    configFile = pkgs.writeText "podman-compose-${name}-quadlet-input.json" (builtins.toJSON config);
  in
    pkgs.runCommand "podman-compose-${name}-quadlet" {
      nativeBuildInputs = [python];
    } ''
      ${python}/bin/python ${compiler} \
        --config ${lib.escapeShellArg configFile} \
        --output "$out"
    '';

  mkUserBundle = {
    user,
    uid,
    bundles,
    reservedUnits ? [],
    reservedContainers ? [],
  }:
    pkgs.runCommand "podman-compose-${lib.strings.sanitizeDerivationName user}-quadlets" {
      nativeBuildInputs = [pkgs.coreutils pkgs.findutils pkgs.jq];
    } ''
      mkdir -p "$out"
      reports="$TMPDIR/reports"
      mkdir -p "$reports"
      ${lib.concatMapStringsSep "\n" (bundle: ''
          for source in ${bundle}/quadlet/*; do
            name="$(basename "$source")"
            if [ -e "$out/$name" ]; then
              echo "duplicate Quadlet path for uid ${toString uid}: $name" >&2
              exit 1
            fi
            ln -s "$source" "$out/$name"
          done
          ln -s ${bundle}/report.json "$reports/$(basename ${bundle}).json"
        '')
        bundles}

      ${pkgs.jq}/bin/jq -s \
        --argjson reservedUnits ${lib.escapeShellArg (builtins.toJSON reservedUnits)} \
        --argjson reservedContainers ${lib.escapeShellArg (builtins.toJSON reservedContainers)} '
        [.[].units[] | .unit] as $units
        | [.[].containers[] | .name] as $containers
        | if (($units | length) != ($units | unique | length)) then
            error("duplicate generated Quadlet runtime unit")
          elif (($containers | length) != ($containers | unique | length)) then
            error("duplicate generated Quadlet container name")
          elif ([.[].localImages[].runtimeRef] as $local
            | [.[].declaredImages[]] as $declared
            | (($local - ($local - $declared)) | length)) > 0 then
            error("Quadlet local image is also classified for registry pull")
          elif (($units - ($units - $reservedUnits)) | length) > 0 then
            error("generated Quadlet unit collides with a declared systemd.user service")
          elif (($containers - ($containers - $reservedContainers)) | length) > 0 then
            error("generated Quadlet container collides with an explicit Compose container name")
          else empty end
      ' "$reports"/*.json
    '';
}
