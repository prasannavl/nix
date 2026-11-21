{core}:
assert core.name == "ab-core"; let
  mk = {pkgs}: {
    incus = import ./incus {inherit pkgs;};
    network = import ./network {inherit pkgs;};
    podman = import ./podman {inherit pkgs;};
  };

  extension = {
    pkgs,
    ab,
  }:
    assert ab ? nixos; {
      runtime = mk {inherit pkgs;};
    };
in {
  name = "ab-runtime";
  dependencies = {
    required = ["core"];
    optional = [];
  };

  inherit extension mk;
}
