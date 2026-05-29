{
  pkgs ? import <nixpkgs> {},
  stack ? import ../../../lib/flake/stack/package.nix,
}: let
  s = stack;
  pkg = s.pkg;
  srv = s.srv;
in
  pkg.mkRustDerivation {
    pkgs = pkgs;
    pname = "nats-wrecking-ball";
    version = "0.1.0";
    projectDir = "pkgs/tools/nats-wrecking-ball";
    enableDevShell = true;
    meta = {
      description = "NATS stress tool for fanout, queue, req-reply, and JetStream queue/replay tests";
      mainProgram = "nats-wrecking-ball";
    };
    extraPassthru = build: {
      clientIdentity = builtins.removeAttrs (srv.mkIdentity build) [
        "flakeExtraNixosModules"
        "nixosModule"
      ];
    };
  }
