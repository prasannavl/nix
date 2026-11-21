rec {
  sizeToBytes = size: let
    match = builtins.match "([0-9]+)([kKmMgG]?)" size;
    number = builtins.fromJSON (builtins.elemAt match 0);
    unit = builtins.elemAt match 1;
    multiplier =
      if unit == "g" || unit == "G"
      then 1024 * 1024 * 1024
      else if unit == "m" || unit == "M"
      then 1024 * 1024
      else if unit == "k" || unit == "K"
      then 1024
      else 1;
  in
    if match == null
    then throw "Unsupported size value: ${size}"
    else number * multiplier;

  sizesToBytes = sizes: builtins.mapAttrs (_: sizeToBytes) sizes;
}
