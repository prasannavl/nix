{
  pkgs ? import <nixpkgs> {},
  i18nDefaultLocale ? "zh-CN",
}: let
  pname = "pi-models-discovery";
  source = (import ../sources.nix).${pname};
in
  pkgs.stdenvNoCC.mkDerivation {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchFromGitHub {
      owner = "maplezzk";
      repo = "pi-extensions";
      inherit (source) rev;
      hash = source.srcHash;
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      packageRoot="$out/share/pi/packages/${pname}"
      mkdir -p "$packageRoot/node_modules"
      cp -R packages/${pname}/. "$packageRoot"
      cp -R packages/pi-extensions-i18n \
        "$packageRoot/node_modules/pi-extensions-i18n"

      # The shared i18n runtime persists its locale selection at
      # $PI_CODING_AGENT_DIR/extensions/pi-extensions-i18n/config.json, which is
      # read-only once the package is linked from the Nix store. Pin the default
      # locale here instead; changing it means editing this argument, not using
      # the in-app /config:language switcher.
      substituteInPlace \
        "$packageRoot/node_modules/pi-extensions-i18n/src/index.ts" \
        --replace-fail 'export const DEFAULT_LOCALE_PREFERENCE: LocalePreference = "zh-CN";' \
        'export const DEFAULT_LOCALE_PREFERENCE: LocalePreference = "${i18nDefaultLocale}";'

      runHook postInstall
    '';

    meta = {
      description = "Dynamic provider model discovery extension for Pi";
      homepage = "https://github.com/maplezzk/pi-extensions/tree/main/packages/pi-models-discovery";
      license = pkgs.lib.licenses.mit;
      platforms = pkgs.lib.platforms.all;
    };
  }
