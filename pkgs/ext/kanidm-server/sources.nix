{
  kanidm-server = {
    kind = "registry-tags";
    registry = "registry-1.docker.io";
    repository = "kanidm/server";
    version = "1.10.4";
    cli = {
      package = "kanidm_1_10";
      vendorName = "kanidm-vendor";
      unstable = false;
      rustVersion = "1.93";
      sourceHash = "sha256-+PutvVt7mqnZN+/vr0FwstB8JPuO3kJ4TSmX2Sx8WvA=";
      cargoHash = "sha256-rfANfheiQnHEcbBODRW0nrPrlPdWQx3S7NmSQ50q010=";
    };
    upstreamCommit = "97b1edbc4183084e1a942823d867bed0fd73e0c9";
    imageDigest = "sha256:d68cc899542fa494120f4014a76c59d5beacad8ee1673e1e62e95f82a332fb68";
    imageHash = "sha256-MXZvjmeiK0k/R25ZUwo7Sk0FzjSTqNZmxMKsEAQDUIE=";
  };
  kanidm-gap3 = {
    # Manual release: CLI and server are reviewed as one compatibility unit.
    kind = "registry-tags";
    registry = "registry-1.docker.io";
    repository = "kanidm/server";
    version = "1.11.2";
    imageDigest = "sha256:e45f00bd354c1fc1c06a4be484b4e87b094c431e78280f1d19e911815e63efb5";
    cli = {
      package = "kanidm_1_11";
      vendorName = "kanidm";
      unstable = true;
      rustVersion = "1.96";
      sourceHash = "sha256-W7LkbHu2jS5pB63eTvmKsypOzL/bzm/5ssnzlpME6jc=";
      cargoHash = "sha256-pn1g0sesG9YtFf/qUvrSHW/m+2rHEyeZGzW1V5XRT+Y=";
    };
  };
}
