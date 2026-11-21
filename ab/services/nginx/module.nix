{lib, ...}: let
  nginxLib = import ./default.nix {inherit lib;};
in {
  options.services.nginx-proxy-vhosts = lib.mkOption {
    type = lib.types.attrsOf nginxLib.model.types.httpProxy;
    default = {};
    description = "Additional host-managed nginx reverse-proxy vhosts.";
  };
}
