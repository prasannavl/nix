{
  stdenv,
  fetchzip,
  glib,
}:
stdenv.mkDerivation rec {
  pname = "gnome-shell-extension-p7-borders";
  version = "35";

  src = fetchzip {
    url = "https://extensions.gnome.org/extension-data/p7-bordersprasannavl.com.v${version}.shell-extension.zip";
    sha256 = "sha256-DZ+eKJuE/i5HG6VTudpOmPO5U88X3Hr4y98uS16XCrQ=";
    stripRoot = false;
  };

  uuid = "p7-borders@prasannavl.com";

  nativeBuildInputs = [glib];

  buildPhase = ''
    runHook preBuild
    if [ -d schemas ]; then
      glib-compile-schemas schemas
    fi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/gnome-shell/extensions/${uuid}
    cp -r . $out/share/gnome-shell/extensions/${uuid}
    runHook postInstall
  '';

  passthru.extensionUuid = uuid;

  meta = {
    description = "A GNOME shell extension for drawing borders to windows";
    homepage = "https://github.com/prasannavl/p7-borders-shell-extension";
    compatibility = "GNOME Shell 45+";
  };
}
