{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-mcp-adapter";
  source = (import ../sources.nix).${pname};

  # The npm tarball ships the runtime TypeScript sources and the prebuilt
  # `dist/` bundle, but no lockfile. Pair it with the tagged upstream lockfile
  # so the runtime dependency closure is reproducible.
  upstream = pkgs.fetchFromGitHub {
    owner = source.owner;
    repo = source.repo;
    rev = "v${source.version}";
    hash = source.releaseHash;
  };

  # Reconcile the upstream manifest with Pi's extension model:
  #
  # - Pi provides `@earendil-works/pi-ai`, `@earendil-works/pi-tui`,
  #   `@earendil-works/pi-coding-agent`, and `typebox` to TypeScript extensions
  #   at runtime, so they must not be bundled into node_modules. Upstream lists
  #   them as peer/dev dependencies, which also pulls transitive
  #   `@earendil-works` lockfile entries that carry a registry URL but no
  #   integrity hash; prefetch-npm-deps rejects those.
  # - Dev-only dependencies are irrelevant for a runtime extension.
  src =
    pkgs.runCommand "${pname}-${source.version}-src" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      cp -R ${pkgs.fetchzip {
        url = "https://registry.npmjs.org/${pname}/-/${pname}-${source.version}.tgz";
        hash = source.srcHash;
      }}/. $out/
      chmod -R u+w $out

      cp ${upstream}/package-lock.json $out/package-lock.json

      jq '
        del(.devDependencies)
        | del(.scripts.prepack, .scripts.prepare)
        | del(
          .peerDependencies["@earendil-works/pi-ai"],
          .peerDependencies["@earendil-works/pi-tui"],
          .peerDependencies.typebox
        )
      ' $out/package.json >$out/package.json.fixed
      mv $out/package.json.fixed $out/package.json

      jq '
        del(.packages[""].devDependencies)
        | del(
          .packages[""].peerDependencies["@earendil-works/pi-ai"],
          .packages[""].peerDependencies["@earendil-works/pi-tui"],
          .packages[""].peerDependencies.typebox
        )
        | .packages |= with_entries(select((.key | test("(^|/)@earendil-works/")) | not))
        | .packages |= with_entries(select((.key == "node_modules/typebox") | not))
      ' $out/package-lock.json >$out/package-lock.json.fixed
      mv $out/package-lock.json.fixed $out/package-lock.json
    '';
in
  pkgs.buildNpmPackage {
    inherit pname;
    inherit (source) version;
    inherit src;

    npmDepsFetcherVersion = 2;
    inherit (source) npmDepsHash;

    dontNpmBuild = true;

    meta = {
      description = "MCP adapter extension for the Pi coding agent";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
