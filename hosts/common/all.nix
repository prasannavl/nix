{
  lib,
  stacks,
  ...
}: let
  userdata = stacks.all.users.nixbot;
in {
  x.sshAgentForwardingUsers = lib.mkAfter ["nixbot"];

  services.abird-host-agent.enable = lib.mkDefault true;

  services.nixbot = {
    enable = lib.mkDefault true;
    user.authorizedKeys = lib.mkDefault userdata.sshKeys;
  };
}
