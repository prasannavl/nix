let
  filterAttrs = predicate: attrs:
    builtins.listToAttrs (
      builtins.filter ({
        name,
        value,
      }:
        predicate name value) (
        map (name: {
          inherit name;
          value = attrs.${name};
        }) (builtins.attrNames attrs)
      )
    );

  getIds = attrs:
    builtins.attrNames attrs;

  userIsActive = details:
    (details.enabled or true) && (details.stackEnabled or true);

  userHasMail = details:
    details.mailEnabled or false;

  matchesUserFilter = {
    isActive ? null,
    hasMail ? null,
  }: _: details:
    (isActive == null || userIsActive details == isActive)
    && (hasMail == null || userHasMail details == hasMail);

  userFilter = {
    isActive ? null,
    hasMail ? null,
    id ? false,
  }: users: let
    filtered = filterAttrs (matchesUserFilter {inherit isActive hasMail;}) users;
  in
    if id
    then getIds filtered
    else filtered;
in {
  inherit filterAttrs userFilter;
}
