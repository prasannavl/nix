{
  stdenv,
  fetchzip,
  glib,
}: let
  source = (import ./sources.nix).p7-cmds;
in
  stdenv.mkDerivation rec {
    pname = "gnome-shell-extension-p7-cmds";
    version = source.version;

    uuid = source.uuid;
    extensionDataUuid = builtins.replaceStrings ["@"] [""] uuid;
    passthru.extensionUuid = uuid;

    meta = {
      description = "A GNOME shell extension for adding compositor tweaks";
      homepage = "https://github.com/prasannavl/p7-cmds-shell-extension";
      compatibility = "GNOME Shell 45+";
    };

    src = fetchzip {
      url = "https://extensions.gnome.org/extension-data/${extensionDataUuid}.v${version}.shell-extension.zip";
      hash = source.hash;
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
