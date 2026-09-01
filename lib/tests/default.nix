{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: let
  incusTests = import ../incus/tests {pkgs = pkgs;};
  forgejoTests = import ../services/forgejo/tests {pkgs = pkgs;};
  gcpVmsFirewallTest = import ../../pkgs/ext/gcp-vms/tests {pkgs = pkgs;};
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
  lintNoIfdTest =
    pkgs.runCommand "lint-no-ifd-test" {
      nativeBuildInputs = [pkgs.bash pkgs.gnused pkgs.nix];
    } ''
      sed '$d' ${../../scripts/lint.sh} > lint-functions.sh
      source ./lint-functions.sh

      NIX_CONFIG='allow-import-from-derivation = true'
      enforce_no_ifd

      [ "$NIX_CONFIG" = $'allow-import-from-derivation = true\nallow-import-from-derivation = false' ]
      effective_ifd="$(nix --extra-experimental-features nix-command config show 2>/dev/null |
        sed -n 's/^allow-import-from-derivation = //p')"
      [ "$effective_ifd" = false ]
      touch "$out"
    '';
  ollamaTests = import ../services/ollama/tests {pkgs = pkgs;};
  podmanImageReportTest =
    pkgs.runCommand "podman-image-report-test" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      cp -R ${../../scripts/support} scripts-support
      chmod -R u+w scripts-support
      python scripts-support/tests/test_report_podman_images.py
      touch "$out"
    '';
  serviceModuleFactory = import ../flake/service-module.nix;
  validTimeoutReadyServiceAttrs = serviceModuleFactory.mkUserTimeoutReadyServiceAttrs 900;
  invalidTimeoutReadyServiceAttrs = builtins.tryEval (serviceModuleFactory.mkUserTimeoutReadyServiceAttrs 0);
  serviceModuleTest = assert validTimeoutReadyServiceAttrs.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
  assert validTimeoutReadyServiceAttrs.serviceConfig.TimeoutStartSec == 900;
  assert !invalidTimeoutReadyServiceAttrs.success;
    pkgs.runCommand "service-module-test" {} ''
      touch "$out"
    '';
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
    lib-gcp-vms-firewall = gcpVmsFirewallTest;
    lib-host-network-qos-helper = hostNetworkQosTests.helper;
    lib-host-network-qos-module = hostNetworkQosTests.module;
    lib-lint-manifest-temp-cleanup = lintManifestTempCleanupTest;
    lib-lint-no-ifd = lintNoIfdTest;
    lib-openssh = import ./openssh.nix {inherit pkgs;};
    lib-ollama-helper = ollamaTests.helper;
    lib-ollama-module = ollamaTests.module;
    lib-podman-image-report = podmanImageReportTest;
    lib-service-module = serviceModuleTest;
    lib-swap-auto = import ./swap-auto.nix {inherit pkgs;};
    lib-podman-compose-helper = podmanComposeTests.helper;
    lib-podman-compose-module = podmanComposeTests.module;
    lib-abird-host-agent = import ./abird-host-agent.nix {inherit pkgs;};
    lib-abird-host-manager = import ./abird-host-manager.nix {inherit pkgs;};
    lib-nixbot = import ./nixbot.nix {inherit pkgs;};
    lib-nginx-phase-projection-routes = import ./nginx-phase-projection-routes.nix {inherit pkgs;};
    lib-nginx-runtime-candidate-validator = import ./nginx-runtime-candidate-validator.nix {inherit pkgs;};
    lib-abird-host-agent-transfer = import ./abird-host-agent-transfer.nix {inherit pkgs;};
    lib-podman-compose-quadlet-conversion = podmanComposeTests.quadlet-conversion;
    lib-profiles-incus-lxc = import ./profiles-incus-lxc.nix {inherit pkgs;};
    lib-stalwart-helper = stalwartTests.helper;
    lib-stalwart-provisioning = stalwartTests.provisioning;
  }
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    lib-abird-host-agent-phase-projection-vm = import ./abird-host-agent-phase-projection-vm.nix {inherit pkgs;};
    lib-podman-compose-quadlet-generator-lifecycle = podmanComposeTests.quadlet-generator-lifecycle;
    lib-podman-compose-quadlet-provider-transition = podmanComposeTests.quadlet-provider-transition;
    lib-podman-compose-systemd-user-lifecycle = podmanComposeTests.systemd-user-lifecycle;
    lib-swap-auto-remote-vm = import ./swap-auto-remote-vm.nix {pkgs = pkgs;};
    lib-swap-auto-vm = import ./swap-auto-vm.nix {inherit pkgs;};
  }
