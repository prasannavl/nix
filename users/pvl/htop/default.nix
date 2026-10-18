{
  nixos = {...}: {
    # Root has no home-manager profile; pin the same config via tmpfiles.
    systemd.tmpfiles.rules = [
      "d /root/.config/htop 0700 root root -"
      "L+ /root/.config/htop/htoprc - - - - ${./htoprc}"
    ];
  };

  home = {...}: {
    xdg.configFile."htop/htoprc" = {
      source = ./htoprc;
      force = true;
    };
  };
}
