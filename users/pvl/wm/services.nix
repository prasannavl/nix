{...}: let
  sessionTargets = [
    "niri.service"
    "sway-session.target"
  ];
  mkWmService = description: execStart: {
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
in {
  inherit sessionTargets mkWmService;
}
