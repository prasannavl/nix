{
  lib,
  stacks,
  ...
}: let
  userdata = stacks.all.users.nixbot;
in {
  services.nixbot = {
    enable = lib.mkDefault true;
    user.authorizedKeys = lib.mkDefault userdata.sshKeys;
  };
}
