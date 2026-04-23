{pkgs}: {
  dirBootstrapScript = {
    dir,
    mode,
    user ? null,
    group ? null,
  }: let
    ownerToString = value:
      if value == null
      then null
      else toString value;
    userString = ownerToString user;
    groupString = ownerToString group;
    chownSpec =
      if userString == null && groupString == null
      then null
      else if groupString == null
      then userString
      else "${userString}:${groupString}";
  in ''
    if [ ! -d ${dir} ]; then
      ${
      if chownSpec == null
      then ''
        ${pkgs.coreutils}/bin/install -d -m ${mode} ${dir}
      ''
      else ''
        ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/install -d -m ${mode} -o ${userString} -g ${groupString} ${dir}
      ''
    }
    fi
  '';
}
