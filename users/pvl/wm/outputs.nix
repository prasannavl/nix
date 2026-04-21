let
  a1 = {
    name = "BOE NE140QDM-NX7 Unknown";
    mode = "2560x1600@165Hz";
    scale = "1.25";
    scaleFilter = "nearest";
    subpixel = "rgb";
    transform = "normal";
    vrr = true;
  };

  lg-uw3840 = {
    name = "LG Electronics LG ULTRAWIDE 506NTQDDR844";
    mode = "3840x1600@144.05Hz";
    scale = "1";
    scaleFilter = "nearest";
    subpixel = "rgb";
    transform = "normal";
    vrr = true;
  };
in {
  all = [
    a1
    lg-uw3840
  ];

  inherit a1 lg-uw3840;
}
