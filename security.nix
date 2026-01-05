{ config, pkgs, ... }:
{
  security.tpm2 = {
     enable = true;
     abrmd.enable = true;
     tctiEnvironment.enable = true;
     pkcs11.enable = true;
  };
  security.rtkit.enable = true;
  security.pam.services.login.enableGnomeKeyring = true;
}
