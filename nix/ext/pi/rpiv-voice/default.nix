{pkgs ? import <nixpkgs> {}}: let
  pname = "rpiv-voice";
  source = (import ../sources.nix).${pname};
  # The resolved deps include decibri and sherpa-onnx-node plus their Linux x64
  # prebuilds. autoPatchelfHook wires the addons and the bundled ONNX Runtime to
  # glibc, libstdc++ and ALSA in the store.
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchzip {
      url = "https://registry.npmjs.org/${source.package}/-/${builtins.baseNameOf source.package}-${source.version}.tgz";
      hash = source.srcHash;
    };

    dontBuild = true;
    nativeBuildInputs = [pkgs.autoPatchelfHook];
    buildInputs = [
      pkgs.stdenv.cc.cc.lib
      pkgs.alsa-lib
    ];

    installPhase = ''
      runHook preInstall

      root="$out/share/pi/packages/${pname}"
      mkdir -p "$root"
      cp -R . "$root"

      # Runtime dependencies are resolved from the published dependency ranges
      # into sources.nix (see ../update.sh); Pi supplies @earendil-works/*,
      # typebox and node builtins itself.
      ${pkgs.lib.concatMapStrings (name: let
          dep = source.deps.${name};
        in ''
          mkdir -p "$root/node_modules/$(dirname ${name})"
          cp -R ${pkgs.fetchzip {
            url = "https://registry.npmjs.org/${name}/-/${builtins.baseNameOf name}-${dep.version}.tgz";
            hash = dep.srcHash;
          }} "$root/node_modules/${name}"
        '')
        (builtins.attrNames source.deps)}

      runHook postInstall
    '';

    meta = {
      description = "Voice input extension for Pi";
      homepage = "https://github.com/juicesharp/rpiv-mono/tree/main/packages/rpiv-voice";
      license = pkgs.lib.licenses.mit;
      platforms = ["x86_64-linux"];
    };
  }
