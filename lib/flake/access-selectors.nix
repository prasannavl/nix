let
  inherit ((import ../validation).mk "invalid access selectors") require requireOnly uniqueStrings;
  selectorList = context: value: let
    values =
      if builtins.isAttrs value
      then [value]
      else value;
  in
    assert require (builtins.isList values && values != [] && builtins.all builtins.isAttrs values) "${context} must be a selector or nonempty selector list"; values;
  distinct = context: values:
    builtins.foldl' (seen: value:
      assert require (!builtins.elem value seen) "${context} duplicates a selector";
        seen ++ [value]) []
    values;
in rec {
  # Preserve singleton syntax at the logical contract boundary.
  mapSelectors = context: f: value: let
    mapped = map f (selectorList context value);
  in
    if builtins.isAttrs value
    then builtins.head mapped
    else mapped;

  names = context: attrs: singular: plural: fallback:
    assert require (!(builtins.hasAttr singular attrs && builtins.hasAttr plural attrs)) "${context} cannot specify both ${singular} and ${plural}"; let
      values = uniqueStrings context (
        if builtins.hasAttr singular attrs
        then [attrs.${singular}]
        else attrs.${plural} or fallback
      );
    in
      assert require (values != []) "${context} must not be empty"; values;

  # Every source reaches every destination, with exactly the declared ports.
  expand = endpointKey: edge:
    assert require (builtins.isAttrs edge && edge ? from && edge ? to) "access requires from and to";
    assert requireOnly ["id" "from" "to" "tcp" "udp"] edge "access"; let
      expandSelector = context: selector:
        assert requireOnly ["fabric" "fabrics" endpointKey] selector context;
        assert require (!(builtins.hasAttr endpointKey selector) || (builtins.isString selector.${endpointKey} && selector.${endpointKey} != "")) "${context} ${endpointKey} must be a nonempty string";
          map (fabric: (builtins.removeAttrs selector ["fabrics"]) // {fabric = fabric;})
          (names context selector "fabric" "fabrics" []);
      side = name: distinct name (builtins.concatMap (expandSelector name) (selectorList name edge.${name}));
      sources = side "from";
      destinations = side "to";
    in
      builtins.concatMap (from: map (to: edge // {inherit from to;}) destinations) sources;
}
