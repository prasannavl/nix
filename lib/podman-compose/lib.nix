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
    ownerInstallArgs =
      (
        if userString == null
        then ""
        else " -o ${userString}"
      )
      + (
        if groupString == null
        then ""
        else " -g ${groupString}"
      );
    chownSpec =
      if userString == null && groupString == null
      then null
      else if userString == null
      then ":${groupString}"
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
        ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/install -d -m ${mode}${ownerInstallArgs} ${dir}
      ''
    }
    fi
    ${
      if chownSpec == null
      then ""
      else ''
        ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/chown ${chownSpec} ${dir}
        ${pkgs.podman}/bin/podman unshare ${pkgs.coreutils}/bin/chmod ${mode} ${dir}
      ''
    }
  '';
}
