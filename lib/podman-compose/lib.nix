{pkgs}: {
  dirBootstrapScript = {
    dir,
    mode,
    user ? null,
    group ? null,
  }: let
    chownSpec =
      if user == null && group == null
      then null
      else if group == null
      then user
      else "${user}:${group}";
  in ''
    if [ ! -d ${dir} ]; then
      ${
      if chownSpec == null
      then ''
        ${pkgs.coreutils}/bin/install -d -m ${mode} ${dir}
      ''
      else ''
        ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} ${dir}
      ''
    }
    fi
  '';
}
