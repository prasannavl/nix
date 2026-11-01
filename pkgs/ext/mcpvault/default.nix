{
  buildNpmPackage,
  fetchurl,
  lib,
  makeWrapper,
  nodejs_22,
  stdenvNoCC,
}: let
  source = (import ./sources.nix).mcpvault;

  # Upstream's committed package-lock.json is bun-generated and incomplete:
  # entries such as `xdg-trashdir` carry no `resolved`/`integrity`, so npm
  # cannot install offline from it. Pin the manifest's declared runtime
  # dependencies in `runtime/` instead and reuse their closure.
  runtimeDeps = buildNpmPackage {
    pname = "mcpvault-runtime-deps";
    version = source.version;

    src = ./runtime;

    nodejs = nodejs_22;
    npmDepsHash = source.npmDepsHash;
    dontNpmBuild = true;

    installPhase = ''
      mkdir -p $out
      cp -R node_modules $out/node_modules
    '';
  };

  packageRoot = "$out/lib/node_modules/mcpvault";
in
  stdenvNoCC.mkDerivation {
    pname = source.repo;
    version = source.version;

    src = fetchurl {
      url = source.tarball;
      hash = source.srcHash;
    };

    nativeBuildInputs = [makeWrapper];

    installPhase = ''
      runHook preInstall

      mkdir -p ${packageRoot}
      cp -R . ${packageRoot}/
      cp -R ${runtimeDeps}/node_modules ${packageRoot}/node_modules

      # Node >= 22.12 is required by upstream's engines field.
      makeWrapper ${lib.getExe nodejs_22} $out/bin/mcpvault \
        --add-flags ${packageRoot}/dist/server.js

      runHook postInstall
    '';

    meta = {
      description = "Local MCP server for reading and editing an Obsidian vault";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "mcpvault";
      platforms = lib.platforms.all;
    };
  }
