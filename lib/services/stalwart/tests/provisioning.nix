{
  pkgs,
  mkUserdataProvisioning,
}: let
  lib = pkgs.lib;
  domainId = "domain-live";
  domainName = "example.test";

  users = {
    alice = {
      username = "alice";
      name = "Alice Admin";
      email = "alice@example.test";
      mailEnabled = true;
      groups = ["users" "admins" "team"];
    };
    bob = {
      username = "bob";
      name = "Bob User";
      email = "bob@external.test";
      mailEnabled = true;
      groups = ["users" "team" "news"];
    };
    carol = {
      username = "carol";
      name = "Carol Local";
      email = null;
      mailEnabled = true;
      groups = ["users"];
    };
    noMail = {
      username = "nomail";
      name = "No Mail";
      email = "nomail@example.test";
      mailEnabled = false;
      groups = ["users" "admins"];
    };
    disabled = {
      username = "disabled";
      name = "Disabled User";
      email = "disabled@example.test";
      mailEnabled = true;
      groups = ["users"];
    };
  };

  userSets = {
    active = builtins.removeAttrs users ["disabled"];
  };

  groupSets = {
    names = ["admins" "news" "team" "users"];
    members = {
      admins = ["alice"];
      news = ["alice" "bob"];
      team = ["alice" "bob" "carol"];
      users = ["alice" "bob" "carol" "noMail"];
    };
    hasAnyGroup = groupNames: user:
      lib.any (groupName: builtins.elem groupName user.groups) groupNames;
  };

  groupDefinitions = {
    admins = {
      mailingList = false;
      shared = {
        enable = true;
        name = "admins-box";
        aliases = ["admins@example.test" "admin-team"];
      };
    };
    news.mailingList = {
      enable = true;
      external = true;
      name = "announcements";
      aliases = ["announce@example.test" "updates"];
    };
    team = {
      mailingList = {
        enable = true;
        name = "team-list";
        aliases = ["team@example.test" "crew"];
      };
      shared = {
        enable = true;
        name = "team";
        aliases = ["team-shared@example.test"];
      };
    };
  };

  provisioning = mkUserdataProvisioning {
    inherit domainId domainName groupDefinitions groupSets userSets users;
  };

  findOne = field: value: items: let
    matches = builtins.filter (item: item.${field} == value) items;
  in
    assert builtins.length matches == 1;
      builtins.head matches;

  mailingListFor = name: findOne "name" name provisioning.mailingLists;
  sharedGroupFor = name: findOne "name" name provisioning.sharedGroups;
  aliasNames = item: map (alias: alias.name) item.aliases;

  roleProjection =
    map (role: {
      inherit (role) name role description domainId;
    })
    provisioning.userRoles;

  announcements = mailingListFor "announcements";
  teamList = mailingListFor "team-list";
  usersList = mailingListFor "users";
  teamShared = sharedGroupFor "team";
  adminsShared = sharedGroupFor "admins-box";

  conflictGroupSets =
    groupSets
    // {
      names = ["conflict"];
      members.conflict = [];
    };
  conflictEval = builtins.tryEval (
    builtins.deepSeq
    (
      mkUserdataProvisioning {
        inherit domainId domainName userSets users;
        groupSets = conflictGroupSets;
        groupDefinitions.conflict = {
          mailingList = true;
          shared.enable = true;
        };
      }
    )
    true
  );
in
  assert roleProjection
  == [
    {
      name = "alice";
      role = "Admin";
      description = "Alice Admin";
      inherit domainId;
    }
    {
      name = "bob@external.test";
      role = "User";
      description = "Bob User";
      inherit domainId;
    }
    {
      name = "carol";
      role = "User";
      description = "Carol Local";
      inherit domainId;
    }
  ];
  assert announcements.recipients == ["alice@example.test" "bob@external.test"];
  assert announcements.description == "Userdata-managed news mailing list.";
  assert announcements.domainId == domainId;
  assert aliasNames announcements == ["announce" "updates"];
  assert teamList.recipients == ["alice@example.test" "bob@external.test"];
  assert aliasNames teamList == ["team" "crew"];
  assert usersList.recipients
  == [
    "alice@example.test"
    "bob@external.test"
    "nomail@example.test"
  ];
  assert aliasNames usersList == [];
  assert teamShared.description == "Userdata-managed team shared mailbox.";
  assert aliasNames teamShared == ["team-shared"];
  assert aliasNames adminsShared == ["admins" "admin-team"];
  assert provisioning.internalMailingListAddresses
  == [
    "team-list@example.test"
    "team@example.test"
    "crew@example.test"
    "users@example.test"
  ];
  assert conflictEval.success == false;
    pkgs.runCommand "stalwart-provisioning-test" {} ''
      touch "$out"
    ''
