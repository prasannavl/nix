{
  description = "llmug-hello Cloudflare app build";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = inputs:
    (import ../../../lib/flake/stack/package.nix).mkFlakeOutputs ./default.nix (inputs
      // {
        stdFlakeOutputArgs = {
          pkgs,
          build,
          pkgHelper,
        }: {
          extraPackages = {
            "wrangler-deploy" = build.wrangler-deploy;
          };
          extraApps = {
            "wrangler-deploy" = pkgHelper.mkPackageApp pkgs build.wrangler-deploy;
          };
        };
      });
}
