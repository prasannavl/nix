{...}: {
  boot.initrd.systemd.tpm2.enable = true;

  security.tpm2 = {
    enable = true;
    abrmd.enable = true;
    tctiEnvironment.enable = true;
    pkcs11.enable = true;
  };
}
