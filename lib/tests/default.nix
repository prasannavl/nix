{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: let
  incusTests = import ../incus/tests {pkgs = pkgs;};
  forgejoTests = import ../services/forgejo/tests {pkgs = pkgs;};
  hostNetworkQosTests = import ../services/host-network-qos/tests {pkgs = pkgs;};
  lintManifestTempCleanupTest =
    pkgs.runCommand "lint-manifest-temp-cleanup-test" {
      nativeBuildInputs = [pkgs.bash pkgs.gnused];
    } ''
      sed '$d' ${../../scripts/lint.sh} > lint-functions.sh
      source ./lint-functions.sh

      REPO_ROOT=${../..}
      test_tmpdir="$PWD/manifest-tmp"
      mktemp() {
        mkdir "$test_tmpdir"
        printf '%s\n' "$test_tmpdir"
      }

      if run_manifest_command "." "" "exec bash -c 'exit 7'"; then
        manifest_status=0
      else
        manifest_status=$?
      fi

      [ "$manifest_status" -eq 7 ]
      [ ! -e "$test_tmpdir" ]
      touch "$out"
    '';
  ollamaTests = import ../services/ollama/tests {pkgs = pkgs;};
  podmanComposeTests = import ../podman-compose/tests {inherit pkgs;};
  stalwartLib = import ../services/stalwart {inherit pkgs;};
  stalwartTests = import ../services/stalwart/tests {
    inherit pkgs;
    inherit (stalwartLib) mkUserdataProvisioning;
  };
in
  {
    lib-incus-helper = incusTests.helper;
    lib-incus-module = incusTests.module;
    lib-forgejo-helper = forgejoTests.helper;
    lib-host-network-qos-helper = hostNetworkQosTests.helper;
    lib-host-network-qos-module = hostNetworkQosTests.module;
    lib-lint-manifest-temp-cleanup = lintManifestTempCleanupTest;
    lib-openssh = import ./openssh.nix {inherit pkgs;};
    lib-ollama-helper = ollamaTests.helper;
    lib-podman-compose-helper = podmanComposeTests.helper;
    lib-podman-compose-module = podmanComposeTests.module;
    lib-abird-host-agent = import ./abird-host-agent.nix {inherit pkgs;};
    lib-abird-host-agent-transfer = import ./abird-host-agent-transfer.nix {inherit pkgs;};
    lib-podman-compose-quadlet-conversion = podmanComposeTests.quadlet-conversion;
    lib-profiles-incus-lxc = import ./profiles-incus-lxc.nix {inherit pkgs;};
    lib-stalwart-helper = stalwartTests.helper;
    lib-stalwart-provisioning = stalwartTests.provisioning;
  }
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    lib-podman-compose-quadlet-generator-lifecycle = podmanComposeTests.quadlet-generator-lifecycle;
    lib-podman-compose-systemd-user-lifecycle = podmanComposeTests.systemd-user-lifecycle;
  }
