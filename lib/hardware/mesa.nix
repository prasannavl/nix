{pkgs, ...}: {
  
  # Configure the mesa stack
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    package = pkgs.mesa;
    package32 = pkgs.pkgsi686Linux.mesa;

    extraPackages = with pkgs; [
      libva
      libva-vdpau-driver
      libvdpau-va-gl
    ];
    extraPackages32 = with pkgs.pkgsi686Linux; [
      libva
      libva-vdpau-driver
      libvdpau-va-gl
    ];
  };
}
