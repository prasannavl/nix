{lib}: let
  defaultRateLimitProfile = {
    enable = true;
    requestsPerSecond = 10;
    requestsPerSecondBurst = 30;
    requestsPerMinute = 300;
    requestsPerMinuteBurst = 900;
    requestsPerQuarterHour = null;
    requestsPerQuarterHourBurst = null;
    requestsPerHour = null;
    requestsPerHourBurst = null;
    statusCode = 429;
    bypass = {
      cidrs = [];
      lan = false;
      cloudflareTunnel = false;
    };
  };

  bypassProfileType = lib.types.submodule {
    options = {
      cidrs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = defaultRateLimitProfile.bypass.cidrs;
        description = "CIDR ranges that should bypass request rate limiting.";
      };

      lan = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimitProfile.bypass.lan;
        description = "Whether private LAN and loopback client ranges should bypass request rate limiting.";
      };

      cloudflareTunnel = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimitProfile.bypass.cloudflareTunnel;
        description = "Whether requests carrying Cloudflare Tunnel client headers should bypass request rate limiting.";
      };
    };
  };

  bypassOverrideType = lib.types.submodule {
    options = {
      cidrs = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Optional override for CIDR ranges that should bypass request rate limiting.";
      };

      lan = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional override for whether LAN and loopback client ranges bypass request rate limiting.";
      };

      cloudflareTunnel = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional override for whether Cloudflare Tunnel requests bypass request rate limiting.";
      };
    };
  };

  rateLimitProfileType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = defaultRateLimitProfile.enable;
        description = "Whether the selected ingress backend should apply request rate limiting.";
      };

      requestsPerSecond = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = defaultRateLimitProfile.requestsPerSecond;
        description = "Optional steady-state request rate limit per client IP.";
      };

      requestsPerMinute = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = defaultRateLimitProfile.requestsPerMinute;
        description = "Optional longer-window request rate limit per client IP.";
      };

      requestsPerQuarterHour = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = defaultRateLimitProfile.requestsPerQuarterHour;
        description = "Optional quarter-hour request rate limit per client IP.";
      };

      requestsPerHour = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = defaultRateLimitProfile.requestsPerHour;
        description = "Optional hourly request rate limit per client IP.";
      };

      requestsPerSecondBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = defaultRateLimitProfile.requestsPerSecondBurst;
        description = "Optional burst size allowed above the per-second request rate.";
      };

      requestsPerMinuteBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = defaultRateLimitProfile.requestsPerMinuteBurst;
        description = "Optional burst size allowed above the per-minute request rate.";
      };

      requestsPerQuarterHourBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = defaultRateLimitProfile.requestsPerQuarterHourBurst;
        description = "Optional burst size allowed above the quarter-hour request rate.";
      };

      requestsPerHourBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = defaultRateLimitProfile.requestsPerHourBurst;
        description = "Optional burst size allowed above the hourly request rate.";
      };

      statusCode = lib.mkOption {
        type = lib.types.ints.between 400 599;
        default = defaultRateLimitProfile.statusCode;
        description = "HTTP status code returned when the request rate limit is exceeded.";
      };

      bypass = lib.mkOption {
        type = bypassProfileType;
        default = {};
        description = "Allowlist rules that bypass request rate limiting.";
      };
    };
  };

  rateLimitOverrideType = lib.types.submodule {
    options = {
      enable = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = "Optional override for whether the selected ingress backend should apply request rate limiting.";
      };

      requestsPerSecond = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional override for the steady-state request rate limit per client IP.";
      };

      requestsPerMinute = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional override for the longer-window request rate limit per client IP.";
      };

      requestsPerQuarterHour = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional override for the quarter-hour request rate limit per client IP.";
      };

      requestsPerHour = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Optional override for the hourly request rate limit per client IP.";
      };

      requestsPerSecondBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Optional override for the allowed burst size above the per-second request rate.";
      };

      requestsPerMinuteBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Optional override for the allowed burst size above the per-minute request rate.";
      };

      requestsPerQuarterHourBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Optional override for the allowed burst size above the quarter-hour request rate.";
      };

      requestsPerHourBurst = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.unsigned;
        default = null;
        description = "Optional override for the allowed burst size above the hourly request rate.";
      };

      statusCode = lib.mkOption {
        type = lib.types.nullOr (lib.types.ints.between 400 599);
        default = null;
        description = "Optional override for the response status code when the request rate limit is exceeded.";
      };

      bypass = lib.mkOption {
        type = bypassOverrideType;
        default = {};
        description = "Optional overrides for the request rate-limit bypass rules.";
      };
    };
  };

  overrideOrNull = overrides: name:
    if builtins.hasAttr name overrides
    then overrides.${name}
    else null;

  mergeBypass = profileBypass: overrideBypass:
    profileBypass
    // lib.optionalAttrs (overrideOrNull overrideBypass "cidrs" != null) {
      cidrs = overrideOrNull overrideBypass "cidrs";
    }
    // lib.optionalAttrs (overrideOrNull overrideBypass "lan" != null) {
      lan = overrideOrNull overrideBypass "lan";
    }
    // lib.optionalAttrs (overrideOrNull overrideBypass "cloudflareTunnel" != null) {
      cloudflareTunnel = overrideOrNull overrideBypass "cloudflareTunnel";
    };

  applyOverride = profile: overrides: let
    bypassOverrides = overrideOrNull overrides "bypass";
  in
    profile
    // lib.optionalAttrs (overrideOrNull overrides "enable" != null) {
      enable = overrideOrNull overrides "enable";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerSecond" != null) {
      requestsPerSecond = overrideOrNull overrides "requestsPerSecond";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerMinute" != null) {
      requestsPerMinute = overrideOrNull overrides "requestsPerMinute";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerQuarterHour" != null) {
      requestsPerQuarterHour = overrideOrNull overrides "requestsPerQuarterHour";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerHour" != null) {
      requestsPerHour = overrideOrNull overrides "requestsPerHour";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerSecondBurst" != null) {
      requestsPerSecondBurst = overrideOrNull overrides "requestsPerSecondBurst";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerMinuteBurst" != null) {
      requestsPerMinuteBurst = overrideOrNull overrides "requestsPerMinuteBurst";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerQuarterHourBurst" != null) {
      requestsPerQuarterHourBurst = overrideOrNull overrides "requestsPerQuarterHourBurst";
    }
    // lib.optionalAttrs (overrideOrNull overrides "requestsPerHourBurst" != null) {
      requestsPerHourBurst = overrideOrNull overrides "requestsPerHourBurst";
    }
    // lib.optionalAttrs (overrideOrNull overrides "statusCode" != null) {
      statusCode = overrideOrNull overrides "statusCode";
    }
    // {
      bypass =
        mergeBypass
        profile.bypass
        (
          if bypassOverrides != null
          then bypassOverrides
          else {}
        );
    };
in {
  inherit defaultRateLimitProfile rateLimitProfileType rateLimitOverrideType;

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
