let
  normalizeList = value:
    if value == null
    then []
    else if builtins.isList value
    then value
    else [value];

  hasValue = value: values:
    builtins.any (candidate: candidate == value) values;

  unique = values: let
    go = seen: rest:
      if rest == []
      then []
      else let
        value = builtins.head rest;
        tail = builtins.tail rest;
      in
        if builtins.elem value seen
        then go seen tail
        else [value] ++ go (seen ++ [value]) tail;
  in
    go [] values;

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
    unique (builtins.attrNames attrs);

  userIsActive = details:
    (details.enabled or true) && (details.stackEnabled or true);

  userHasMail = details:
    details.mailEnabled or ((details.enabled or true) && (details.email or true));

  userHasGroup = group: details:
    hasValue group (normalizeList (details.groups or []));

  userHasAnyGroup = groups: details:
    builtins.any (group: userHasGroup group details) (normalizeList groups);

  userIsAdmin = userHasGroup "admins";

  matchesUserFilter = {
    isActive ? null,
    hasMail ? null,
    isAdmin ? null,
    group ? null,
    groups ? [],
  }: _: details: let
    groupFilters = normalizeList group ++ normalizeList groups;
  in
    (isActive == null || userIsActive details == isActive)
    && (hasMail == null || userHasMail details == hasMail)
    && (isAdmin == null || userIsAdmin details == isAdmin)
    && (groupFilters == [] || userHasAnyGroup groupFilters details);

  userFilter = {
    isActive ? null,
    hasMail ? null,
    isAdmin ? null,
    group ? null,
    groups ? [],
    id ? false,
  }: users: let
    filtered =
      filterAttrs
      (matchesUserFilter {
        inherit
          group
          groups
          hasMail
          isActive
          isAdmin
          ;
      })
      users;
  in
    if id
    then getIds filtered
    else filtered;
in {
  inherit
    unique
    userFilter
    userHasAnyGroup
    userHasGroup
    userIsAdmin
    ;
}
