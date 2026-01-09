{
  lib,
  userdata,
  config,
  username ? (let first = builtins.head (builtins.attrNames userdata); in userdata.${first}.username),
  homeDirectory ? config.home.homeDirectory,
  wallpaperSrc ? "${homeDirectory}/src/dotfiles/x/files/backgrounds/sw.png",
  pictureOptions ? "zoom",
  colorShadingType ? "solid",
  primaryColor ? "#1b1f2a",
  secondaryColor ? "#10131a",
  traceExists ? false,
  ...
}: let
  wallpaperRelPath = ".local/share/backgrounds/${username}";
  wallpaperUri = "file://${homeDirectory}/${wallpaperRelPath}";
  existsRaw = builtins.pathExists wallpaperSrc;
  wallpaperExists =
    if traceExists
    then lib.traceVal existsRaw
    else existsRaw;
in {
  inherit wallpaperRelPath wallpaperUri wallpaperExists;

  dconfSettings = lib.optionalAttrs wallpaperExists {
    "org/gnome/desktop/background" = {
      color-shading-type = colorShadingType;
      picture-options = pictureOptions;
      picture-uri = wallpaperUri;
      picture-uri-dark = wallpaperUri;
      primary-color = primaryColor;
      secondary-color = secondaryColor;
    };
  };

  homeFiles = lib.optionalAttrs wallpaperExists {
    "${wallpaperRelPath}" = {
      source = wallpaperSrc;
    };
  };
}
