{
  pkgs ? import <nixpkgs> {},
  helloWebStaticSite ? ./site,
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "hello-web-served";
  version = "0.1.0";

  src = ./.;

  installPhase = ''
    runHook preInstall

    install -d "$out/bin" "$out/share/hello-web-served"
    cp -r ${helloWebStaticSite}/. "$out/share/hello-web-served/"

    cat > "$out/bin/hello-web-served" <<EOF
    #!/usr/bin/env bash
    set -Eeuo pipefail
    bind_address="\''${HELLO_WEB_BIND:-127.0.0.1}"
    port="\''${HELLO_WEB_PORT:-8080}"
    root="\''${HELLO_WEB_ROOT:-$out/share/hello-web-served}"

    cd "\$root"
    exec ${pkgs.python3Minimal}/bin/python -m http.server "\$port" --bind "\$bind_address"
    EOF

    chmod +x "$out/bin/hello-web-served"

    runHook postInstall
  '';

  meta = {
    description = "Serve example static assets with Python's built-in HTTP server";
    mainProgram = "hello-web-served";
  };
}
