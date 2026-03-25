{...}: {
  boot.initrd.systemd.tpm2.enable = true;

  # Ref: https://github.com/NixOS/nixpkgs/blob/release-25.11/nixos/modules/security/tpm2.md
  security.tpm2 = {
    enable = true;
    abrmd.enable = true;
    pkcs11.enable = true;

    tctiEnvironment.enable = true;
    tctiEnvironment.interface = "tabrmd"; # alt: device
  };
}
