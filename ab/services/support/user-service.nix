{
  mkTimeoutReadyAttrs = timeoutReadySeconds:
    if builtins.isInt timeoutReadySeconds && timeoutReadySeconds > 0
    then {
      environment.NIXBOT_TIMEOUT_READY_SECONDS = toString timeoutReadySeconds;
      serviceConfig.TimeoutStartSec = timeoutReadySeconds;
    }
    else throw "user-service timeoutReadySeconds must be a positive integer";
}
