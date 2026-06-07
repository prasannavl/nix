{
  stackName,
  defaultMailDomain,
  includeAllStacks ? false,
  rawUserdata ? import ../../../users/userdata.nix,
  rawGroupData ? import ../../../users/groupdata.nix,
}: let
  userDataLib = import ./user-data-lib.nix;
  inherit (userDataLib) unique userFilter;

  normalizeList = value:
    if value == null
    then []
    else if builtins.isList value
    then value
    else [value];

  hasValue = value: values:
    builtins.any (candidate: candidate == value) values;

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

  optional = condition: value:
    if condition
    then [value]
    else [];

  sortStrings = builtins.sort (a: b: a < b);

  enabled = details: details.enabled or true;

  stackEnabled = details:
    includeAllStacks || !(details ? stacks) || hasValue stackName (normalizeList details.stacks);

  usernameFor = userId: details:
    details.username or userId;

  rawSshKeysFor = details:
    normalizeList (details.sshKeys or (optional (details ? sshKey) details.sshKey));

  rawCiSshKeysFor = details:
    normalizeList (details.ciSshKeys or (optional (details ? ciSshKey) details.ciSshKey));

  normalizeUser = userId: details: let
    username = usernameFor userId details;
    userEnabled = enabled details;
    userStackEnabled = stackEnabled details;
    userMailEnabled = userEnabled && (details.email or true);
    aliases = normalizeList (details.aliases or []);
    localParts =
      if userMailEnabled
      then unique ([username] ++ aliases)
      else [];
    emails = map (localPart: "${localPart}@${defaultMailDomain}") localParts;
  in
    details
    // {
      id = userId;
      username = username;
      enabled = userEnabled;
      stackEnabled = userStackEnabled;
      mailEnabled = userMailEnabled;
      aliases = aliases;
      stacks = normalizeList (details.stacks or []);
      localParts = localParts;
      emails = emails;
      email =
        if emails != []
        then builtins.head emails
        else null;
      sshKeys =
        if userEnabled
        then rawSshKeysFor details
        else [];
      ciSshKeys =
        if userEnabled
        then rawCiSshKeysFor details
        else [];
    }
    // optionalAttrs (userEnabled && rawSshKeysFor details != []) {
      sshKey = builtins.head (rawSshKeysFor details);
    }
    // optionalAttrs (userEnabled && rawCiSshKeysFor details != []) {
      ciSshKey = builtins.head (rawCiSshKeysFor details);
    };

  optionalAttrs = condition: attrs:
    if condition
    then attrs
    else {};

  baseUsers = builtins.mapAttrs normalizeUser rawUserdata;

  sshKeysFor = details: details.sshKeys;

  ciSshKeysFor = details: details.ciSshKeys;

  activeStackBaseUserRecords = userFilter {isActive = true;} baseUsers;
  activeStackUserIds = builtins.attrNames activeStackBaseUserRecords;

  stackBaseUserRecords = filterAttrs (_: details: details.stackEnabled) baseUsers;
  stackUserIds = builtins.attrNames stackBaseUserRecords;

  disabledUserRecords = filterAttrs (_: details: !(enabled details)) baseUsers;
  disabledUserIds = builtins.attrNames disabledUserRecords;

  loadGroupData =
    if builtins.isFunction rawGroupData
    then
      rawGroupData {
        users = baseUsers;
        userLib = userDataLib;
      }
    else rawGroupData;

  normalizeGroup = groupId: details: let
    groupUsers = normalizeList (details.users or []);
    unknownUsers = builtins.filter (userId: !(builtins.hasAttr userId baseUsers)) groupUsers;
  in
    if unknownUsers != []
    then builtins.throw "groupData group ${groupId} references unknown users: ${builtins.concatStringsSep ", " unknownUsers}"
    else
      details
      // {
        id = groupId;
        name = details.name or groupId;
        users = builtins.filter (userId: hasValue userId activeStackUserIds) groupUsers;
        stacks = normalizeList (details.stacks or []);
        stackEnabled = stackEnabled details;
      };

  allGroupData = builtins.mapAttrs normalizeGroup loadGroupData;
  groupData = filterAttrs (_: details: details.stackEnabled) allGroupData;

  groupNames = sortStrings (builtins.attrNames groupData);

  groupNamesForUser = userId:
    builtins.filter (groupName: hasValue userId groupData.${groupName}.users) groupNames;

  users = builtins.mapAttrs (userId: details: details // {groups = groupNamesForUser userId;}) baseUsers;

  activeStackUserRecords = filterAttrs (_: details: details.enabled && details.stackEnabled) users;
  stackUserRecords = filterAttrs (_: details: details.stackEnabled) users;

  groupNamesForUserIds = userIds:
    builtins.filter (
      groupName:
        builtins.any (userId: hasValue userId groupData.${groupName}.users) userIds
    )
    groupNames;

  userIdsInGroup = groupName:
    groupData.${groupName}.users or [];

  groupMembers = builtins.listToAttrs (map (groupName: {
      name = groupName;
      value = userIdsInGroup groupName;
    })
    groupNames);

  mkNixosConfig = {
    lib,
    pkgs,
  }: let
    disabledLoginShell = "${pkgs.shadow}/bin/nologin";
    disabledUsernames = map (userId: disabledUserRecords.${userId}.username) disabledUserIds;
  in {
    disabledGroups =
      builtins.mapAttrs (_: details: {
        gid = lib.mkDefault details.uid;
      })
      disabledUserRecords;

    disabledUsers =
      builtins.mapAttrs (_: details: {
        uid = lib.mkDefault details.uid;
        group = lib.mkDefault details.username;
        hashedPassword = lib.mkForce "!";
        openssh.authorizedKeys.keys = lib.mkForce [];
        extraGroups = lib.mkForce [];
        packages = lib.mkForce [];
        linger = lib.mkForce false;
        shell = lib.mkForce disabledLoginShell;
      })
      disabledUserRecords;

    disabledActivationScripts = builtins.listToAttrs (map (username: {
        name = "terminate-disabled-${username}";
        value = ''
          if command -v loginctl >/dev/null 2>&1; then
            loginctl terminate-user ${lib.escapeShellArg username} || true
            loginctl disable-linger ${lib.escapeShellArg username} || true
          fi
        '';
      })
      disabledUsernames);
  };
in {
  userData = users;
  inherit groupData users;

  lib =
    userDataLib
    // {
      inherit
        ciSshKeysFor
        enabled
        sshKeysFor
        ;
    };

  userSets = {
    active = activeStackUserRecords;
    activeIds = activeStackUserIds;
    disabled = disabledUserRecords;
    disabledIds = disabledUserIds;
    stack = stackUserRecords;
    stackIds = stackUserIds;
  };

  groupSets = {
    names = groupNames;
    definitions = groupData;
    members = groupMembers;
    namesForUserIds = groupNamesForUserIds;
    userIdsIn = userIdsInGroup;
    hasAnyGroup = userDataLib.userHasAnyGroup;
    hasGroup = userDataLib.userHasGroup;
  };

  meta = {
    inherit defaultMailDomain rawUserdata stackName;
  };

  nixosConfig = mkNixosConfig;
}
