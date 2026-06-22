{
  stdenv,
  fetchzip,
  glib,
}:
stdenv.mkDerivation rec {
  pname = "gnome-shell-extension-p7-cmds";
  version = "33";

  uuid = "p7-cmds@prasannavl.com";
  extensionDataUuid = builtins.replaceStrings ["@"] [""] uuid;
  passthru.extensionUuid = uuid;

  meta = {
    description = "A GNOME shell extension for adding compositor tweaks";
    homepage = "https://github.com/prasannavl/p7-cmds-shell-extension";
    compatibility = "GNOME Shell 45+";
  };

  src = fetchzip {
    url = "https://extensions.gnome.org/extension-data/${extensionDataUuid}.v${version}.shell-extension.zip";
    sha256 = "sha256-deGfIZyxgzHTfTPZ3r5XocESRzBT67+C9P9yQpvT1rw=";
    stripRoot = false;
  };

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
}
