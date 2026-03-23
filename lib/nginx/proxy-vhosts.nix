{lib, ...}: let
  nginxLib = import ./default.nix {inherit lib;};
in {
  options.x.nginxProxyVhosts = nginxLib.proxyVhostsOption;
}
