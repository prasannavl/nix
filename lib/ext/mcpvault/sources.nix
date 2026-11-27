{
  mcpvault = {
    # npm release. update.sh regenerates runtime/, whose lock pins this release
    # and its dependency closure; npmDepsHash covers that lock.
    kind = "npm";
    package = "@bitbonsai/mcpvault";
    owner = "bitbonsai";
    repo = "mcpvault";
    version = "0.18.4";
    npmDepsHash = "sha256-zp62vbWa2DxR0B4sq/e3LswzCQ0lhdUhlmAC7KTrzkw=";
  };
}
