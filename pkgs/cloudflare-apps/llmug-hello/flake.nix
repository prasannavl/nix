{
  description = "llmug-hello Cloudflare app build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = declaredInputs: let
    inputs = declaredInputs // {rustWorkspaceDeps = false;};
  in
    (import ../../../lib/project.nix).mkFlakeOutputs ./. (inputs
      // {
        stdFlakeOutputArgs = {
          ab,
          pkgs,
          build,
        }: {
          extraPackages."wrangler-deploy" = build.wrangler-deploy;
          extraApps."wrangler-deploy" = ab.flake.app pkgs build.wrangler-deploy;
        };
      });
}
