{
  stalwart-cli = {
    kind = "github-release";
    owner = "stalwartlabs";
    repo = "cli";
    tagPrefix = "v";
    version = "1.0.14";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-yQgk/mCynVbFpZC68yGjDUIhU/eqZKxfhA0W8wiV5Zw=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-v2QbfFF2syfSFGW1XuiyaeHqh0oMgdJ9JZ4ucj+eVbQ=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-Uj5ydZ11eWQEY/Y7lWKugVvgEvSCXjnNdTjiKMUNZXA=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-ugM6Qs+R6ey9SpElB41sBhX/dRL4bQdG4Tk4AEtJ3lY=";
      };
    };
  };
}
