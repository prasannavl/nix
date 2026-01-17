{
  config,
  pkgs,
  ...
}: {
  security.rtkit.enable = true;
  security.polkit.enable = true;

  security.sudo.enable = true;
  security.sudo.configFile = ''
    # Add this line to set timeout to 10 minutes (e.g.)
    Defaults timestamp_timeout=720
  '';

  security.pam.loginLimits = [
    {
      domain = "*";
      type = "-";
      item = "nofile";
      value = "1048576";
    }
    {
      domain = "root";
      type = "-";
      item = "nofile";
      value = "1048576";
    }
  ];

  # security.unprivilegedUsernsClone = true; # only needed in hardened setups
}
