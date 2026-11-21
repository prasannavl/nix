{pkgs}: {
  release = builtins.fromJSON (builtins.readFile ./release.json);
  mkRunner = {
    name,
    container,
  }:
    pkgs.writeShellApplication {
      name = name;
      runtimeInputs = [pkgs.python3 pkgs.podman];
      text = ''
        exec python3 ${./runner.py} --policy ${./release.json} \
          --container ${pkgs.lib.escapeShellArg container} "$@"
      '';
    };
}
