{...}: let
  sessionTargets = [
    "niri.service"
    "sway-session.target"
  ];
  mkWmPostService = description: execStart: {
    Unit = {
      Description = description;
      PartOf = sessionTargets;
      After = sessionTargets;
    };
    Service = {
      ExecStart = execStart;
      Restart = "on-failure";
      RestartSec = 1;
    };
    Install.WantedBy = sessionTargets;
  };
  mkWmPreService = description: execStart: {
    Unit = {
      Description = description;
      Before = sessionTargets;
      PartOf = sessionTargets;
    };
    Service = {
      Type = "oneshot";
      ExecStart = execStart;
    };
    Install.WantedBy = sessionTargets;
  };
in {
  inherit sessionTargets mkWmPostService mkWmPreService;
}
