{
  computer-use-linux = {
    # Upstream publishes tagged releases; the per-target binary assets are
    # pinned below. No package-local updater, so the generic reporter tracks
    # tags read-only.
    kind = "github-tags";
    owner = "agent-sh";
    repo = "computer-use-linux";
    tagPrefix = "v";
    version = "0.7.64";
    binaries = [
      "computer-use-linux"
      "computer-use-linux-cosmic"
      "computer-use-linux-indicator"
    ];
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hashes = {
          computer-use-linux = "sha256-JoqQlW+CB8/qsX9ZSxA4TJU9TC9dwBDQfoDY7nocqL4=";
          computer-use-linux-cosmic = "sha256-3XXRfdwmZiBBTzvbQ1wsZQs5xMJrpPAG0e7FRZmP3ZY=";
          computer-use-linux-indicator = "sha256-QqkoXjBM6Zcik4hqttEpqQecuPwg5/exu7tDZtg3RAc=";
        };
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hashes = {
          computer-use-linux = "sha256-nYPAuScNVdQAp/nz6PsmuysB+yDRzNmuS2BEvaaljuw=";
          computer-use-linux-cosmic = "sha256-JorDmkYu/mjFMeTArvo+1KWkG5WO2o3BGi2Uk9tWiJU=";
          computer-use-linux-indicator = "sha256-t2A9YIX1dBGhHgpC9x7SerzK+qOc67l9dIhZu/H/wuI=";
        };
      };
    };
  };
}
