{
  kache = {
    kind = "github-release";
    owner = "kunobi-ninja";
    repo = "kache";
    tagPrefix = "v";
    version = "2.4.0";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-bcX+sv3MmCU4hpvA0PY60NosjxosImSedwf/TrTbqrc=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-Bh4CIyuhtfZKC7O44c25fNLf8SkyoVImZuMmcfgYKq4=";
      };
    };
  };
}
