{inputs}: final: prev: let
  unstable = import inputs.unstable {
    system = prev.stdenv.hostPlatform.system;
    config = prev.config;
  };
in {
  unstable = unstable;
  
  vscode = unstable.vscode;
  crun = unstable.crun;
  jan = unstable.jan;
}
