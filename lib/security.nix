{config, ...}: {
  security.rtkit.enable = true;
  security.polkit.enable = true;

  # Only needed in hardened setups
  # security.unprivilegedUsernsClone = true;

  security.pam.loginLimits = map (domain: {
    inherit domain;
    type = "-";
    item = "nofile";
    value = toString config.x.fdlimit;
  }) ["*" "root"];
}
