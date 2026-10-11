{inputs, ...}: {
  imports = [inputs.dotlink.nixosModules.default];

  services.dotlink = {
    enable = true;
    user = "pvl";
    workingDirectory = "/home/pvl/spaces/abird/";
    logging.verbosity = "tools";
  };
}
