{lib}: {
  duplicateValues = values:
    builtins.attrNames (
      lib.filterAttrs (_: count: count > 1) (
        builtins.foldl'
        (acc: value: let
          key = toString value;
        in
          acc
          // {
            ${key} = (acc.${key} or 0) + 1;
          })
        {}
        values
      )
    );
}
