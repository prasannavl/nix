{...}: {
  systemd.services.systemd-suspend.unitConfig = {
    StartLimitIntervalSec = "30min";
    StartLimitBurst = 3;
  };
}
