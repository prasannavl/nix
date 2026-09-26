{
  agent-workspace-linux = {
    kind = "github-release";
    owner = "agent-sh";
    repo = "agent-workspace-linux";
    tagPrefix = "v";
    version = "0.3.3";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hash = "sha256-0oNDqZnTGl2G5SMdh6VwFz4IWTNbgKYJOeul+ODlC4g=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hash = "sha256-KPlWYxP/VrbF3ozmarpeKyyFqakG3skDqahdU2jtD98=";
      };
    };
  };
}
