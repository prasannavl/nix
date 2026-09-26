{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-diff";
  source = (import ../sources.nix).${pname};

  upstream = pkgs.fetchFromGitHub {
    owner = source.owner;
    repo = source.repo;
    rev = "v${source.version}";
    hash = source.releaseHash;
  };

  # Pi loads the TypeScript source directly, so the prebuilt dist bundle is not
  # needed. Reconcile the upstream manifest with Pi's extension model:
  #
  # - Pi provides the @earendil-works core packages to TypeScript extensions at
  #   runtime, so they must not be bundled into node_modules. Upstream lists
  #   them as regular dependencies, which also pulls in bundled lockfile entries
  #   that carry a registry URL but no integrity hash; prefetch-npm-deps rejects
  #   those.
  # - The manifest must point at src/index.ts and ship src/ in the tarball.
  # - Dev-only dependencies are irrelevant for a runtime extension.
  src =
    pkgs.runCommand "${pname}-${source.version}-src" {
      nativeBuildInputs = [pkgs.jq];
    } ''
      cp -R ${upstream}/. $out/
      chmod -R u+w $out

      jq '
        del(
          .dependencies["@earendil-works/pi-coding-agent"],
          .dependencies["@earendil-works/pi-tui"],
          .dependencies["@earendil-works/pi-server"],
          .devDependencies
        )
        | .pi.extensions = ["./src/index.ts"]
        | .files = ["src/", "media/", "README.md", "LICENSE"]
      ' $out/package.json >$out/package.json.fixed
      mv $out/package.json.fixed $out/package.json

      jq '
        .packages[""].dependencies |=
          del(
            .["@earendil-works/pi-coding-agent"],
            .["@earendil-works/pi-tui"],
            .["@earendil-works/pi-server"]
          )
        | del(.packages[""].devDependencies)
        | .packages |= with_entries(select(.key | test("(^|/)@earendil-works/") | not))
      ' $out/package-lock.json >$out/package-lock.json.fixed
      mv $out/package-lock.json.fixed $out/package-lock.json
    '';
in
  pkgs.buildNpmPackage {
    pname = "pi-diff";
    inherit (source) version;
    inherit src;

    npmDepsFetcherVersion = 2;
    inherit (source) npmDepsHash;

    dontNpmBuild = true;

    meta = {
      description = "Shiki-powered terminal diff renderer extension for Pi";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
