{config, ...}: {
  security = {
    rtkit.enable = true;
    polkit.enable = true;

    # Only needed in hardened setups
    # unprivilegedUsernsClone = true;
    pam.loginLimits = map (domain: {
      domain = domain;
      type = "-";
      item = "nofile";
      value = toString config.x.fdlimit;
    }) ["*" "root"];
  };
}
