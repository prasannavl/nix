let
  userdata = import ../../users/userdata.nix;
  incusCertLib = import ../../lib/incus/certs.nix {users = userdata;};

  groups = {
    pvl = incusCertLib.mkIncusCertsForUser {
      user = "pvl";
      certificates = [
        {
          name = "pvl";
          projects = [];
          restricted = false;
        }
      ];
    };
  };
in
  incusCertLib.mergeIncusCertGroups groups
