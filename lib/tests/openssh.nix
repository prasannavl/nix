{pkgs}: let
  evaluated = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = pkgs.stdenv.hostPlatform.system;
    inherit pkgs;
    modules = [
      ../openssh.nix
      {
        x = {
          sshDefault = true;
          sshAgentForwardingUsers = ["nixbot"];
        };
      }
    ];
  };
  sshdConfig = evaluated.config.environment.etc."ssh/sshd_config".source;
in
  pkgs.runCommand "openssh-policy-test" {
    nativeBuildInputs = [pkgs.gnugrep pkgs.gnused pkgs.openssh];
  } ''
    ssh-keygen -q -t ed25519 -N "" -f host-key
    sed '/^HostKey /d' ${sshdConfig} > sshd_config

    sshd -T -f sshd_config -h host-key \
      -C user=nixbot,host=test,addr=127.0.0.1 > nixbot-policy
    grep -Fx 'AllowAgentForwarding yes' nixbot-policy

    sshd -T -f sshd_config -h host-key \
      -C user=operator,host=test,addr=127.0.0.1 > operator-policy
    grep -Fx 'AllowAgentForwarding no' operator-policy

    touch "$out"
  ''
