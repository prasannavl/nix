{
  config,
  lib,
  ...
}: {
  options.x.sshDefault = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Apply minimum SSH hardening: disable root login, password auth, X11 forwarding, and agent forwarding except for explicitly allowed users.";
  };

  options.x.sshAgentForwardingUsers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [];
    description = "SSH users allowed to forward an agent while forwarding remains disabled for every other user.";
  };

  config = {
    services.openssh = {
      enable = true;
      settings = lib.mkIf config.x.sshDefault {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        X11Forwarding = false;
        MaxAuthTries = 3;
      };
      extraConfig = lib.mkIf (config.x.sshDefault || config.x.sshAgentForwardingUsers != []) (lib.mkAfter ''
        ${lib.optionalString (config.x.sshAgentForwardingUsers != []) ''
          Match User ${lib.concatStringsSep "," config.x.sshAgentForwardingUsers}
            AllowAgentForwarding yes
        ''}
        Match all
          AllowAgentForwarding no
      '');
    };
  };
}
