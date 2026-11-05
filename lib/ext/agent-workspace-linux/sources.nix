{
  agent-workspace-linux = {
    kind = "github-release";
    owner = "agent-sh";
    repo = "agent-workspace-linux";
    tagPrefix = "v";
    version = "0.6.3";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-gnu";
        hash = "sha256-Zm0AO38Xr3/2h5hCzWjteCd5psqCBMiYUYVxhHDP9Js=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-gnu";
        hash = "sha256-iM1IehIGDLiJ6cwAEq76AyRnOXeFmCHycpqsvhzt3Mw=";
      };
    };
  };
}
