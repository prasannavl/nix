{
  pkgs,
  nativeNix,
}:
pkgs.stdenv.mkDerivation {
  pname = "abird-host-manager-native";
  version = "3";
  src = ./.;
  dontUnpack = true;
  nativeBuildInputs = [pkgs.pkg-config];
  buildInputs = [nativeNix.libs.nix-cmd];
  buildPhase = ''
    runHook preBuild
    pkg-config --exact-version=2.34.9 nix-cmd
    $CXX -shared -fPIC -fvisibility=hidden -Wall -Wextra -Werror \
      -DABIRD_NIX_PROGRAM='"${nativeNix}/bin/nix"' \
      "$src/query.cc" "$src/acquisition.cc" \
      -o libabird-owned-nix.so $(pkg-config --cflags --libs nix-cmd)
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    install -Dm755 libabird-owned-nix.so "$out/lib/libabird-owned-nix.so"
    runHook postInstall
  '';
  meta.platforms = pkgs.lib.platforms.linux;
}
