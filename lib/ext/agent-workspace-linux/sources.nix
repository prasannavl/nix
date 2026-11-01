{
  agent-workspace-linux = {
    kind = "github-release";
    owner = "agent-sh";
    repo = "agent-workspace-linux";
    tagPrefix = "v";
    version = "0.6.1";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hash = "sha256-Q1bkPikvVgVpQQ+jhU7QVFsK6VKmuAW0qKuUuDEuk8E=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hash = "sha256-XfbPxeoW3nLuG+m5wp97diAzKzsaKGY5IRrvuUFLBO8=";
      };
    };
  };
}
