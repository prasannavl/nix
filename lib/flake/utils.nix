{lib}: {
  duplicateValues = values:
    builtins.attrNames (
      lib.filterAttrs (_: count: count > 1) (
        builtins.foldl'
        (acc: value:
          acc
          // {
            ${value} = (acc.${value} or 0) + 1;
          })
        {}
        values
      )
    );
}
