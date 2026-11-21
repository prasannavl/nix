# niri master pin: ordered open-on-output fallbacks (PR #4618) plus everything
# since v26.04. Re-pin rev/narHash/cargoDeps on bump; drop after the next release.
_final: prev: let
  rev = "ed22699d99462f61ab171472d3ea67e844ea580d";
  src = builtins.fetchTree {
    type = "github";
    owner = "niri-wm";
    repo = "niri";
    inherit rev;
    narHash = "sha256-3BtIY8xxJHLai3/73kOqgSgcVmqpSKpz9uUstQYgfLk=";
  };
in {
  niri = prev.niri.overrideAttrs (_: {
    inherit src;
    # cargoHash is baked at eval time, so override cargoDeps directly.
    cargoDeps = prev.rustPlatform.fetchCargoVendor {
      inherit src;
      pname = "niri";
      version = "26.04";
      hash = "sha256-vtTh+TG6TdX46QydGKaeo50u2qdQf3UkQ50EML+5H9c=";
    };
  });
}
