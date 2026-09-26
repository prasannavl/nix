let
  mk = prefix: rec {
    fail = message: throw "${prefix}: ${message}";

    require = condition: message:
      if condition
      then true
      else fail message;

    requireOnly = allowed: value: context: let
      unknown = builtins.filter (name: !builtins.elem name allowed) (builtins.attrNames value);
    in
      require (unknown == []) "${context} has unknown fields: ${builtins.concatStringsSep ", " unknown}";

    uniqueStrings = context: values:
      assert require (builtins.isList values) "${context} must be a list";
        builtins.foldl' (result: value:
          assert require (builtins.isString value && value != "") "${context} must contain non-empty strings";
          assert require (!builtins.elem value result) "${context} duplicates ${value}";
            result ++ [value])
        []
        values;
  };
in {
  inherit mk;

  isName = value:
    builtins.isString value
    && builtins.stringLength value <= 64
    && builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" value != null;

  isNonEmptyString = value:
    builtins.isString value && value != "";
}
