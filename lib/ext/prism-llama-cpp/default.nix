{
  fetchurl,
  lib,
  stdenvNoCC,
  # Release variant: "rocm" or "cuda". Both carry the same llama-server and
  # shared libraries, built against the matching accelerator userspace.
  variant,
}: let
  source = (import ./sources.nix).prism-llama-cpp;
  asset =
    source.assets.${variant}
    or (throw "prism-llama-cpp: unknown variant '${variant}' (expected rocm or cuda)");
  version = source.version;
in
  stdenvNoCC.mkDerivation {
    pname = "prism-llama-cpp-${variant}";
    inherit version;

    src = fetchurl {
      url = "https://github.com/${source.owner}/${source.repo}/releases/download/${source.tagPrefix}${version}/llama-${version}-${asset.target}.tar.gz";
      hash = asset.hash;
    };

    # Archive top directory is llama-<version>/. Its contents reference each
    # other through RUNPATH $ORIGIN, so the store path is mounted intact over
    # a container's /app; no patchelf, no separate library layout.
    sourceRoot = "llama-${version}";

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -a . $out/
      runHook postInstall
    '';

    meta = {
      description = "PrismML llama.cpp fork server (ternary GGUF support), ${variant} build";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = [lib.licenses.mit];
      mainProgram = "llama-server";
      platforms = ["x86_64-linux"];
    };
  }
