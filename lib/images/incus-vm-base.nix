{
  accounts,
  lib,
  ...
}: let
  userdata = accounts.users.nixbot;
in {
  imports = [
    (import ../../users/pvl).core
  ];

  services.nixbot = {
    enable = lib.mkDefault true;
    user.authorizedKeys = lib.mkDefault userdata.sshKeys;
  };
}
