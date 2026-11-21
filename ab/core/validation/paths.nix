{lib}: let
  validation = import ./.;
  safeComponents = components:
    lib.all
    (component: component != "" && component != "." && component != ".." && component != ".git")
    components;
in {
  inherit (validation) isName;

  indexedPairs = values:
    builtins.concatLists (lib.imap0 (index: left:
      map (right: {inherit left right;}) (lib.drop (index + 1) values))
    values);

  isCanonicalAbsolutePath = value:
    builtins.isString value
    && builtins.match "/[^/]+(/[^/]+)*" value != null
    && lib.all (character: builtins.match "[[:cntrl:]]" character == null) (lib.stringToCharacters value)
    && safeComponents (lib.drop 1 (lib.splitString "/" value));

  isRepositoryPath = value:
    validation.isNonEmptyString value
    && !lib.hasPrefix "/" value
    && lib.all (character: builtins.match "[[:cntrl:]]" character == null) (lib.stringToCharacters value)
    && safeComponents (lib.splitString "/" value);

  pathsOverlap = left: right: let
    leftParts = lib.filter (component: component != "") (lib.splitString "/" left);
    rightParts = lib.filter (component: component != "") (lib.splitString "/" right);
    shorter = lib.min (builtins.length leftParts) (builtins.length rightParts);
  in
    lib.take shorter leftParts == lib.take shorter rightParts;
}
