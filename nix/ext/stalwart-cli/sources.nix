{
  stalwart-cli = {
    kind = "github-release";
    owner = "stalwartlabs";
    repo = "cli";
    tagPrefix = "v";
    version = "2.0.0";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-JauYvTinnxps1z25ofFDgHIRpH8RFCMDy0IvKrhff54=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-3tY0GLg+DTg2m4rfKGU2y8g3Afx+WHbw6BcX5Pdq6Mc=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-XrYZzHv99PAfWDgwpMQhYUQHIpclZb732JNS7RcvzA4=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-8ZBpfgRGDV1M4RjXD1siNB5UNxBGjzqm5Z+zIZopI6M=";
      };
    };
  };
}
