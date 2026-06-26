{lib}: let
  addressLocalPart = domainName: address:
    if lib.hasSuffix "@${domainName}" address
    then lib.removeSuffix "@${domainName}" address
    else address;
in {
  mkUserdataDirectory = {
    domainName,
    groupDefinitions ? {},
    groupSets,
    users,
  }: let
    definitionFor = groupName:
      groupDefinitions.${groupName} or {};

    normalizeSurface = default: value:
      if builtins.isAttrs value
      then {
        enable = value.enable or default;
        external = value.external or false;
        name = value.name or null;
        description = value.description or null;
        aliases = value.aliases or [];
      }
      else {
        enable = value;
        external = false;
        name = null;
        description = null;
        aliases = [];
      };

    groupFlagsFor = groupName: let
      definition = definitionFor groupName;
      mailingListConfig = normalizeSurface true (definition.mailingList or {});
      sharedConfig = normalizeSurface false (definition.shared or {});
    in {
      mailingList = mailingListConfig.enable;
      externalList = mailingListConfig.external;
      mailingListName = mailingListConfig.name;
      mailingListAliases = mailingListConfig.aliases;
      shared = sharedConfig.enable;
      sharedName = sharedConfig.name;
      sharedDescription = sharedConfig.description;
      sharedAliases = sharedConfig.aliases;
    };

    groupFor = groupName: let
      definition = definitionFor groupName;
      flags = groupFlagsFor groupName;
      memberIds = groupSets.members.${groupName} or [];
      recipients = lib.unique (
        builtins.filter (value: value != null)
        (map (userId: users.${userId}.email) memberIds)
      );
      kanidmName = definition.name or groupName;
      listName =
        if flags.mailingListName != null
        then flags.mailingListName
        else groupName;
      sharedName =
        if flags.sharedName != null
        then flags.sharedName
        else groupName;
      aliasLocalParts = map (addressLocalPart domainName) flags.mailingListAliases;
      aliasAddresses = map (localPart: "${localPart}@${domainName}") aliasLocalParts;
    in
      if flags.mailingList && flags.shared && listName == sharedName
      then
        builtins.throw ''
          groupData group ${groupName} enables both mailingList and shared with the same local part ${listName}.
          Set mailingList.enable = false, shared.enable = false, mailingList.name, or shared.name so Stalwart does not create two principals for ${listName}@${domainName}.
        ''
      else {
        name = groupName;
        inherit kanidmName;
        description = "Userdata-managed ${groupName} mail group.";
        members = memberIds;
        listName = listName;
        sharedName = sharedName;
        listAddress = "${listName}@${domainName}";
        sharedAddress = "${sharedName}@${domainName}";
        aliases = flags.mailingListAliases;
        inherit aliasLocalParts aliasAddresses;
        sharedAliases = flags.sharedAliases;
        sharedDescription = flags.sharedDescription;
        sharedAliasLocalParts = map (addressLocalPart domainName) flags.sharedAliases;
        inherit recipients;
        inherit (flags) externalList mailingList shared;
      };

    groups = lib.genAttrs groupSets.names groupFor;
    groupList = map (groupName: groups.${groupName}) groupSets.names;
    mailingListGroups = builtins.filter (group: group.mailingList) groupList;
    sharedGroups = builtins.filter (group: group.shared) groupList;
  in {
    inherit
      groups
      groupList
      mailingListGroups
      sharedGroups
      ;

    internalMailingListAddresses = lib.concatMap (group: [group.listAddress] ++ group.aliasAddresses) (
      builtins.filter (group: !group.externalList) mailingListGroups
    );
  };
}
