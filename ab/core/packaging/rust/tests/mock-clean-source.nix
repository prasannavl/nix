# Preserve the cleanSourceWith metadata consumed by source-aware constructors.
{
  src,
  name,
  filter,
}: let
  inputIsFiltered = src._isLibCleanSourceWith or false;
  origSrc =
    if inputIsFiltered
    then src.origSrc
    else src;
  combinedFilter = path: type: filter path type && (!inputIsFiltered || src.filter path type);
in {
  _isLibCleanSourceWith = true;
  origSrc = origSrc;
  filter = combinedFilter;
  outPath = builtins.path {
    path = origSrc;
    name = name;
    filter = combinedFilter;
  };
}
