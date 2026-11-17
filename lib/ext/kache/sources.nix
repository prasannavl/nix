{
  kache = {
    # Tagged releases with per-target static musl archives. No package-local
    # updater, so the generic reporter tracks tags read-only.
    kind = "github-tags";
    owner = "kunobi-ninja";
    repo = "kache";
    tagPrefix = "v";
    version = "2.1.1";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-dgMCLueLSKmv3pBVsN8n5cLO8TUaVPot5rT94PN64iw=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-Rm8K70iF9SkTWbPBvAyZdoJGNBlMW2fhzuKk/jA1FVo=";
      };
    };
  };
}
