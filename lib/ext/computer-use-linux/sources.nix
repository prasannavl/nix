{
  computer-use-linux = {
    # Upstream publishes tagged releases; the per-target binary assets are
    # pinned below. No package-local updater, so the generic reporter tracks
    # tags read-only.
    kind = "github-tags";
    owner = "agent-sh";
    repo = "computer-use-linux";
    tagPrefix = "v";
    version = "0.7.35";
    binaries = [
      "computer-use-linux"
      "computer-use-linux-cosmic"
      "computer-use-linux-indicator"
    ];
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hashes = {
          computer-use-linux = "sha256-iUQ2j9BVwGl6Ni/fovU574dyoUbKgkbb7kj9PbqRwSU=";
          computer-use-linux-cosmic = "sha256-svf/5sWwuvxs9yrZ5mxgSwp1uvQLDiqv6y9xOc3XmVA=";
          computer-use-linux-indicator = "sha256-Iaa0OLNS14mGjomo1szHUk7LjI7mE1IIa+DEYjtc/z8=";
        };
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hashes = {
          computer-use-linux = "sha256-VKHwrBHkA3Irif16/Wt2A0ioUDQtaztIGO8UFN2h1zY=";
          computer-use-linux-cosmic = "sha256-Z2L/hsP1lPqvo/hwaFG5MyuW7dR4JuaUyKZy3TCVE8U=";
          computer-use-linux-indicator = "sha256-2aE5Pn1t0IVML6K2c8PjtDkgSwoKarPe+lfs62wF0zQ=";
        };
      };
    };
  };
}
