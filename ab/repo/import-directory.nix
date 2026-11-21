directory: let
  entries =
    if builtins.pathExists directory
    then builtins.readDir directory
    else {};
  reservedEntries = builtins.filter (name: name == "default.nix") (builtins.attrNames entries);
  files = builtins.filter (
    name:
      entries.${name}
      == "regular"
      && builtins.match ".*\\.nix" name != null
  ) (builtins.attrNames entries);
in
  assert reservedEntries == [] || throw "configuration fragment directory ${toString directory} may not contain default.nix";
    builtins.listToAttrs (map (name: {
        name = builtins.substring 0 (builtins.stringLength name - 4) name;
        value = import (directory + "/${name}");
      })
      files)
