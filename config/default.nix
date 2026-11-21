let
  accountData = {
    rawUserdata = import ../users/userdata.nix;
    rawGroupData = import ../users/groupdata.nix;
  };
  accounts = (import ../ab).stack.accounts.mk {
    stackName = null;
    defaultMailDomain = "invalid.invalid";
    includeAllStacks = true;
    inherit (accountData) rawUserdata rawGroupData;
  };
  readPublicKey = path:
    builtins.replaceStrings ["\r" "\n"] ["" ""] (builtins.readFile path);
in
  (import ../ab).repo.config {
    defaultScope = "pvl";
    shared.accounts = accounts;
    nix.caches = import ./pvl/nix-caches.nix;
    nix.trustedPublicKeys = [
      (readPublicKey ../data/secrets/globals/nix/builder-abird.pub)
      (readPublicKey ../data/secrets/globals/nix/builder-pvl.pub)
    ];
    families.pvl = import ./pvl {inherit accountData;};
    modules.repo = {
      abird-host-agent = ../ab/services/abird-host-agent;
      projection-authority-staging = ./pvl/projection-authority-staging.nix;
    };
  }
