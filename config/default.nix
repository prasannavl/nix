let
  accounts = import ../lib/flake/accounts {
    stackName = null;
    defaultMailDomain = "invalid.invalid";
    includeAllStacks = true;
  };
  readPublicKey = path:
    builtins.replaceStrings ["\r" "\n"] ["" ""] (builtins.readFile path);
in
  import ../lib/flake/repository-config.nix {
    defaultScope = "pvl";
    shared.accounts = accounts;
    nix.trustedPublicKeys = [
      (readPublicKey ../data/secrets/globals/nix/builder-abird.pub)
      (readPublicKey ../data/secrets/globals/nix/builder-pvl.pub)
    ];
    families.pvl = import ./pvl;
    modules.repo.abird-host-agent = ../lib/services/abird-host-agent;
  }
