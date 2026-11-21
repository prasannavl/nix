{
  pkgs,
  ab,
}:
ab.build.rust {
  pkgs = pkgs;
  pname = "nats-wrecking-ball";
  version = "0.1.0";
  projectDir = "pkgs/tools/nats-wrecking-ball";
  enableDevShell = true;
  meta = {
    description = "NATS stress tool for fanout, queue, req-reply, and JetStream queue/replay tests";
    mainProgram = "nats-wrecking-ball";
  };
  extraPassthru = build: let
    identityIntent = {name = build.pname;};
    clientIdentityModule = {
      config,
      lib,
      stack,
      ...
    }: let
      identity = stack.identity.bind identityIntent;
      installedNames = map (package: package.name or package.pname) config.environment.systemPackages;
    in {
      age.secrets = lib.mkIf (builtins.elem (build.name or build.pname) installedNames) identity.ageSecrets;
    };
  in {
    inherit identityIntent;
    flakeExtraNixosModules.clientIdentity = clientIdentityModule;
  };
}
