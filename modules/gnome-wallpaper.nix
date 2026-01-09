{
  lib,
  config,
  wallpaperUri,
  pictureOptions ? "zoom",
  colorShadingType ? "solid",
  primaryColor ? "#1b1f2a",
  secondaryColor ? "#10131a",
  ...
}: {
  dconfSettings = {
    "org/gnome/desktop/background" = {
      color-shading-type = colorShadingType;
      picture-options = pictureOptions;
      picture-uri = wallpaperUri;
      picture-uri-dark = wallpaperUri;
      primary-color = primaryColor;
      secondary-color = secondaryColor;
    };
  };
}
