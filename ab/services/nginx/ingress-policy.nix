{lib}: let
  declarationPolicy = import ./declaration-policy.nix {inherit lib;};
in
  declarationPolicy
  // {
    resolveRateLimit = {
      defaultRateLimit ? null,
      rateLimit ? null,
    }: let
      resolved =
        if rateLimit != null
        then rateLimit
        else defaultRateLimit;
    in
      if resolved == null
      then null
      else if !resolved.enable
      then null
      else if
        resolved.requestsPerSecond
        == null
        && resolved.requestsPerMinute == null
        && resolved.requestsPerQuarterHour == null
        && resolved.requestsPerHour == null
      then null
      else resolved;
  }
