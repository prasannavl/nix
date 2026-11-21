{
  agent-workspace-linux = {
    kind = "github-release";
    owner = "agent-sh";
    repo = "agent-workspace-linux";
    tagPrefix = "v";
    version = "0.6.4";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hash = "sha256-2RklPmNUC1fG59VmzXRoBUOYH995BS8Ak2fsPiZ9uBs=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hash = "sha256-j0npXqdW4WTvaCupv1MqEm0iCIFhfzFm5nfpydBIKe0=";
      };
    };
  };
}
