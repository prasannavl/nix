{
  config,
  pkgs,
  ...
}: {
  security.tpm2 = {
    enable = true;
    abrmd.enable = true;
    tctiEnvironment.enable = true;
    pkcs11.enable = true;
  };
  security.rtkit.enable = true;
  security.polkit.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;

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
