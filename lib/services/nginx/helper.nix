{
  pkgs,
  runtimePackages ? {
    coreutils = pkgs.coreutils;
    podman = pkgs.podman;
    systemd = pkgs.systemd;
    util-linux = pkgs.util-linux;
  },
}:
pkgs.writeShellApplication {
  name = "nginx-helper";
  runtimeInputs = builtins.attrValues runtimePackages;
  text = builtins.readFile ./helper.sh;
}
