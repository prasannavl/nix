{
  stdenv,
  fetchzip,
  glib,
}:
stdenv.mkDerivation rec {
  pname = "gnome-shell-extension-p7-borders";
  version = "44";

  uuid = "p7-borders@prasannavl.com";
  extensionDataUuid = builtins.replaceStrings ["@"] [""] uuid;
  passthru.extensionUuid = uuid;

  meta = {
    description = "A GNOME shell extension for drawing borders to windows";
    homepage = "https://github.com/prasannavl/p7-borders-shell-extension";
    compatibility = "GNOME Shell 45+";
  };

  src = fetchzip {
    url = "https://extensions.gnome.org/extension-data/${extensionDataUuid}.v${version}.shell-extension.zip";
    sha256 = "sha256-UXYotwW4DPuz+n/zA7RYnsT2SoLf1J7QkZOrqqUurjc=";
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
