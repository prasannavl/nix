{
  stalwart-cli = {
    kind = "github-release";
    owner = "stalwartlabs";
    repo = "cli";
    tagPrefix = "v";
    version = "1.0.13";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-aJZEpJHCmLSRZxSpOioknuLqcPLywFSZFljD6PDyfBM=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-CirYbeb/M25cjiaqTS/ROtePF/UcfBTx2Wx5Wx1dnTA=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-ezWY9xubGMTh1ZZ2nEG7YZRRFGIENGcPsO0rtfPwCac=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-veUhufoDXiLNx8P4g3oYzpS5dcZDpQVCK9NzjczaCvw=";
      };
    };
  };
}
