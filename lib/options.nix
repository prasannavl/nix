{lib, ...}: {
  options.x = {
    fdlimit = lib.mkOption {
      type = lib.types.int;
      default = 1048576;
      description = "Global file descriptor limit used by systemd and PAM.";
    };

    panicReboot = lib.mkOption {
      type = lib.types.enum [0 1];
      default = 1;
      description = "Enable or disable panic recovery sysctl settings.";
    };
  };
}
