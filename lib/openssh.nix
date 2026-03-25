{
  config,
  lib,
  ...
}: {
  options.x.sshDefault = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Apply minimum SSH hardening: disable root login, password auth, X11 forwarding, and agent forwarding.";
  };

  config = {
    services.openssh = {
      enable = true;
      settings = lib.mkIf config.x.sshDefault {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        X11Forwarding = false;
        AllowAgentForwarding = false;
        MaxAuthTries = 3;
      };
    };
  };
}
