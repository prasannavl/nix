let
  allUserData = import ../flake/stack/users.nix {
    stackName = "all";
    defaultMailDomain = "invalid.invalid";
    includeAllStacks = true;
  };
in rec {
  pvl = import ./pvl.nix;
  all = {
    stackName = "all";
    org = "all";
    env = "aggregate";
    users = allUserData.userData;
    userLib = allUserData.lib;
    userSets = allUserData.userSets;
    groupSets = allUserData.groupSets;
    groupData = allUserData.groupData;
    nixosConfig = allUserData.nixosConfig;
  };
}
