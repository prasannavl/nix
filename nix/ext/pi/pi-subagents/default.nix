{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-subagents";
  source = (import ../sources.nix).${pname};

  # Pi's extension loader virtualizes the runtime imports an extension is
  # allowed to make (`@earendil-works/*` and `@sinclair/typebox`), so the
  # published npm tarball is self-contained and needs no npm dependency fetch.
  src = pkgs.fetchzip {
    url = "https://registry.npmjs.org/@gotgenes/pi-subagents/-/pi-subagents-${source.version}.tgz";
    hash = source.srcHash;
  };
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname src;
    inherit (source) version;

    # `src` is already an unpacked directory; copy it instead of running
    # unpackPhase, and skip the (nonexistent) build step.
    dontUnpack = true;
    dontBuild = true;

    installPhase = ''
      runHook preInstall

      root="$out/lib/node_modules/@gotgenes/pi-subagents"
      mkdir -p "$root"
      cp -R ${src}/. "$root"/

      # Pi discovers a directory extension through a root `index.ts`/`index.js`
      # entry point, but @gotgenes/pi-subagents only declares `src/index.ts` in
      # its package manifest. Add a thin re-export so the package's `#src/*`
      # imports keep resolving from the package root.
      cat > "$root/index.ts" <<'EOF'
      export { default } from "./src/index.ts";
      EOF

      runHook postInstall
    '';

    meta = {
      description = "In-process sub-agent core for Pi with a typed API and lifecycle events";
      homepage = "https://github.com/gotgenes/pi-packages/tree/main/packages/pi-subagents";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
