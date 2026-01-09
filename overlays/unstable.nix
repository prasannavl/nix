{ inputs }:
final: prev:
let
  unstable = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config // { allowUnfree = true; };
  };
in
{
  vscode = unstable.vscode;
  crun = unstable.crun;
}
