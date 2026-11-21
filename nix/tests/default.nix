{
  pkgs ?
    import <nixpkgs> {
      config.allowUnfree = true;
    },
}: let
  aiCoreTests = import ../../ab/services/ai/tests {pkgs = pkgs;};
  incusTests = {
    helper = import ../../ab/runtime/incus/tests {pkgs = pkgs;};
    module = import ../../nix/tests/incus.nix {pkgs = pkgs;};
  };
  forgejoTests = import ../../ab/services/forgejo/tests {pkgs = pkgs;};
  gcpVmsFirewallTest = import ../../pkgs/ext/gcp-vms/tests {pkgs = pkgs;};
  hostNetworkQosTests = import ../../ab/services/host-network-qos/tests {pkgs = pkgs;};
  kanidmTests = import ../../ab/services/kanidm/tests {pkgs = pkgs;};
  llamaRouterTests = import ../../ab/services/llama-router/tests {pkgs = pkgs;};
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
  modelReconcilerTest = import ../../ab/services/model-reconciler/tests {inherit pkgs;};
  systemNixModule = ../profiles/policy/nix.nix;
  evalNixConfig = {
    specialArgs ? {},
    extraModules ? [],
  }: let
    effectiveSpecialArgs =
      {
        ab = (import ../../ab).forPkgs {pkgs = pkgs;};
        repository.nix = {
          substituters = [];
          trustedPublicKeys = [];
        };
      }
      // specialArgs;
  in
    import (pkgs.path + "/nixos/lib/eval-config.nix") {
      system = pkgs.stdenv.hostPlatform.system;
      inherit pkgs;
      specialArgs = effectiveSpecialArgs;
      modules =
        [
          systemNixModule
        ]
        ++ extraModules;
    };
  repoRegistry = {
    nix = {
      host = "test-cache";
      url = "http://test-cache:5000";
    };
    containers = {
      host = "test-registry";
      url = "https://registry.example.test";
    };
  };
  repositoryNix = {
    substituters = [repoRegistry.nix.url];
    trustedPublicKeys = [
      "test-cache-1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
  repoRegistryConfig =
    (evalNixConfig {
      specialArgs.repository.nix = repositoryNix;
      extraModules = [
        ({repository, ...}: {
          environment.etc."repo-registry-test".text = builtins.toJSON repository.nix;
        })
      ];
    }).config;
  defaultRepoRegistryConfig = (evalNixConfig {}).config;
  repoRegistryTest = assert repoRegistry.containers.url == "https://registry.example.test";
  assert builtins.head repoRegistryConfig.nix.settings.extra-substituters == repoRegistry.nix.url;
  assert builtins.fromJSON repoRegistryConfig.environment.etc."repo-registry-test".text == repositoryNix;
  assert builtins.head repoRegistryConfig.nix.settings.extra-trusted-public-keys == builtins.head repositoryNix.trustedPublicKeys;
  assert builtins.length repoRegistryConfig.nix.settings.extra-trusted-public-keys == 6;
  assert builtins.length defaultRepoRegistryConfig.nix.settings.extra-substituters == 5;
  assert defaultRepoRegistryConfig.nix.settings.extra-substituters
  == [
    "https://nix-community.cachix.org"
    "https://numtide.cachix.org"
    "https://cache.numtide.com"
    "https://go-overlay.cachix.org"
    "https://fenix.cachix.org"
  ];
  assert defaultRepoRegistryConfig.nix.settings.extra-trusted-public-keys
  == [
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    "niks3.numtide.com-1:DTx8wZduET09hRmMtKdQDxNNthLQETkc/yaX7M4qK0g="
    "go-overlay.cachix.org-1:rJ155O3K6WUyUcoKE4MqcC6JcLlK2vPXnP5/76BxWD8="
    "fenix.cachix.org-1:ecJhr+RdYEdcVgUkjruiYhjbBloIEGov7bos90cZi0Q="
  ];
  assert defaultRepoRegistryConfig.system.stateVersion == "25.11";
  assert defaultRepoRegistryConfig.nixpkgs.config.allowUnfree;
  assert defaultRepoRegistryConfig.nix.gc.automatic;
  assert defaultRepoRegistryConfig.nix.gc.dates == ["weekly"];
  assert defaultRepoRegistryConfig.nix.gc.options == "--delete-older-than 14d";
  assert builtins.elem "https://go-overlay.cachix.org" defaultRepoRegistryConfig.nix.settings.extra-substituters;
  assert builtins.elem "https://fenix.cachix.org" defaultRepoRegistryConfig.nix.settings.extra-substituters;
  assert builtins.elem "go-overlay.cachix.org-1:rJ155O3K6WUyUcoKE4MqcC6JcLlK2vPXnP5/76BxWD8=" defaultRepoRegistryConfig.nix.settings.extra-trusted-public-keys;
  assert builtins.elem "fenix.cachix.org-1:ecJhr+RdYEdcVgUkjruiYhjbBloIEGov7bos90cZi0Q=" defaultRepoRegistryConfig.nix.settings.extra-trusted-public-keys;
    pkgs.runCommand "nix-repo-registry-test" {} ''
      touch "$out"
    '';
  ollamaTests = import ../../ab/services/ollama/tests {pkgs = pkgs;};
  podmanImageUpdaterTest =
    pkgs.runCommand "podman-image-updater-test" {
      nativeBuildInputs = [pkgs.python3];
    } ''
      cp -R ${../../scripts/update} scripts-update
      chmod -R u+w scripts-update
      python scripts-update/tests/test_podman_image_updater.py
      touch "$out"
    '';
  prismLlamaCppPackageTest = pkgs.runCommand "prism-llama-cpp-package-test" {} ''
    test -x ${pkgs.prism-llama-cpp-rocm}/llama-server
    test -x ${pkgs.prism-llama-cpp-cuda}/llama-server
    test "${
      if pkgs.prism-llama-cpp-rocm.meta ? mainProgram
      then "true"
      else "false"
    }" = false
    test "${
      if pkgs.prism-llama-cpp-cuda.meta ? mainProgram
      then "true"
      else "false"
    }" = false
    touch "$out"
  '';
  prismLlamaCppUpdaterTest =
    pkgs.runCommand "prism-llama-cpp-updater-test" {
      nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3];
    } ''
      mkdir -p repo/nix/ext/prism-llama-cpp repo/scripts/update/tests repo/tmp
      cp ${../../nix/ext/prism-llama-cpp/update.sh} repo/nix/ext/prism-llama-cpp/update.sh
      cp ${../../scripts/update/tests/test_prism_llama_cpp_update.py} repo/scripts/update/tests/test_prism_llama_cpp_update.py
      chmod u+w repo/nix/ext/prism-llama-cpp/update.sh repo/scripts/update/tests/test_prism_llama_cpp_update.py
      cd repo
      python -m unittest scripts.update.tests.test_prism_llama_cpp_update
      touch "$out"
    '';
  userService = import ../../ab/services/support/user-service.nix;
  validTimeoutReadyServiceAttrs = userService.mkTimeoutReadyAttrs 900;
  invalidTimeoutReadyServiceAttrs = builtins.tryEval (userService.mkTimeoutReadyAttrs 0);
  serviceModuleTest = assert validTimeoutReadyServiceAttrs.environment.NIXBOT_TIMEOUT_READY_SECONDS == "900";
  assert validTimeoutReadyServiceAttrs.serviceConfig.TimeoutStartSec == 900;
  assert !invalidTimeoutReadyServiceAttrs.success;
    pkgs.runCommand "service-module-test" {} ''
      touch "$out"
    '';
  podmanRuntimeTests = import ../../ab/runtime/podman/tests {inherit pkgs;};
  podmanComposeTests =
    podmanRuntimeTests
    // {
      module = import ../../nix/tests/podman.nix {inherit pkgs;};
    };
  stalwartLib = import ../../ab/services/stalwart {inherit pkgs;};
  portableStalwartTests = import ../../ab/services/stalwart/tests {
    inherit pkgs;
    inherit (stalwartLib) mkUserdataProvisioning;
  };
  stalwartTests =
    portableStalwartTests
    // {
      cli = import ../../nix/ext/stalwart-cli/tests {inherit pkgs;};
    };
  tailscaleTest = import ../../ab/services/tailscale/tests {inherit pkgs;};
  zerobyteTest = import ../../ab/services/zerobyte/tests {inherit pkgs;};
in
  {
    lib-ab-extraction = import ../../ab/tests/extraction.nix {inherit pkgs;};
    lib-ab-package-contracts = import ../../ab/tests/package-contracts.nix {pkgs = pkgs;};
    lib-ab-stack-assembly = import ../../ab/stack/tests/assembly.nix {
      pkgs = pkgs;
      registry = (import ../../ab).stack.registry;
    };
    lib-system-optional-features = import ../../ab/tests/system-features.nix {inherit pkgs;};
    lib-ai-model-prefetch = aiCoreTests.model-prefetch;
    lib-ai-lib = aiCoreTests.lib;
    lib-ai-module = aiCoreTests.module;
    lib-ai-projection = aiCoreTests.projection;
    lib-ai-inference = aiCoreTests.inference;
    lib-ai-consumer-selection = aiCoreTests.consumer-selection;
    lib-ai-inference-runtime = aiCoreTests.inference-runtime;
    lib-incus-helper = incusTests.helper;
    lib-incus-module = incusTests.module;
    lib-excalidash-helper = import ../../ab/services/excalidash/tests {inherit pkgs;};
    lib-forgejo-helper = forgejoTests.helper;
    lib-gcp-vms-firewall = gcpVmsFirewallTest;
    lib-hardware-nvidia = import ../../ab/system/tests/hardware-nvidia.nix {pkgs = pkgs;};
    lib-host-network-qos-helper = hostNetworkQosTests.helper;
    lib-host-network-qos-module = hostNetworkQosTests.module;
    lib-kanidm-cli-metadata = import ../../pkgs/ext/kanidm-server/tests/cli.nix {inherit pkgs;};
    lib-kanidm-helper = kanidmTests.helper;
    lib-kanidm-normalization = kanidmTests.normalization;
    lib-llama-router-helper = llamaRouterTests.helper;
    lib-llama-router-module = llamaRouterTests.module;
    lib-lint-markdown = import ../../scripts/tests/lint-markdown.nix {pkgs = pkgs;};
    lib-update-helper-repository = import ../../scripts/update/tests {pkgs = pkgs;};
    lib-lint-manifest-temp-cleanup = lintManifestTempCleanupTest;
    lib-lint-no-ifd = lintNoIfdTest;
    lib-model-reconciler-wrapper = modelReconcilerTest;
    lib-nix-repo-registry = repoRegistryTest;
    lib-openssh = import ../../ab/system/tests/openssh.nix {inherit pkgs;};
    lib-ollama-helper = ollamaTests.helper;
    lib-ollama-module = ollamaTests.module;
    lib-pi-updater = import ../../nix/ext/pi/tests {inherit pkgs;};
    lib-pi-web = import ../../ab/services/pi-web/tests {inherit pkgs;};
    lib-podman-image-updater = podmanImageUpdaterTest;
    lib-prism-llama-cpp-updater = prismLlamaCppUpdaterTest;
    lib-service-module = serviceModuleTest;
    lib-service-client-identity = import ../../ab/stack/tests/service-client-identity.nix {inherit pkgs;};
    lib-swap-auto = import ../../ab/system/tests/swap-auto.nix {inherit pkgs;};
    lib-podman-compose-helper = podmanComposeTests.helper;
    lib-podman-compose-module = podmanComposeTests.module;
    lib-abird-host-agent = import ../../ab/services/abird-host-agent/tests/abird-host-agent.nix {inherit pkgs;};
    lib-abird-host-agent-generation = import ../../ab/services/abird-host-agent/tests/abird-host-agent-generation.nix {inherit pkgs;};
    lib-abird-host-manager = import ../../ab/services/abird-host-manager/tests/module.nix {inherit pkgs;};
    lib-nixbot = import ../../pkgs/tools/nixbot/tests/module.nix {inherit pkgs;};
    lib-nix-builder-gc-coordination = import ../../ab/system/nix/tests/module.nix {inherit pkgs;};
    lib-nginx-phase-projection-routes = import ./repository/nginx-phase-projection-routes.nix {inherit pkgs;};
    lib-nginx-runtime-candidate-validator = import ../../ab/services/nginx/tests/runtime-candidate-validator.nix {inherit pkgs;};
    lib-abird-host-agent-transfer = import ../../ab/services/abird-host-agent/tests/abird-host-agent-transfer.nix {inherit pkgs;};
    lib-podman-compose-quadlet-conversion = podmanComposeTests.quadlet-conversion;
    lib-profiles-incus-lxc = import ../profiles/tests/incus-lxc.nix {inherit pkgs;};
    lib-stalwart-cli = stalwartTests.cli;
    lib-stalwart-helper = stalwartTests.helper;
    lib-stalwart-lifecycle = stalwartTests.lifecycle;
    lib-stalwart-provisioning = stalwartTests.provisioning;
    lib-tailscale-helper = tailscaleTest;
    lib-zerobyte-helper = zerobyteTest;
  }
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isx86_64 {
    # The package only declares x86_64-linux support, so the contract check
    # cannot be evaluated (or built) on other Linux systems.
    lib-prism-llama-cpp-package = prismLlamaCppPackageTest;
  }
  // pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    lib-abird-host-agent-phase-projection-vm = import ../../ab/services/abird-host-agent/tests/abird-host-agent-phase-projection-vm.nix {inherit pkgs;};
    lib-nix-builder-containment-vm = import ../../ab/services/abird-host-agent/tests/nix-builder-containment-vm.nix {inherit pkgs;};
    lib-nix-builder-launch-gate-vm = import ../../ab/services/abird-host-agent/tests/nix-builder-launch-gate-vm.nix {inherit pkgs;};
    lib-build-executor-control = import ../../ab/services/abird-host-agent/tests/build-executor-control.nix {inherit pkgs;};
    lib-build-agent-workflow-vm = import ../../ab/services/abird-host-agent/tests/build-agent-workflow-vm.nix {inherit pkgs;};
    lib-opendesign-managed-byok-provider = (import ../../pkgs/ext/opendesign/tests {inherit pkgs;}).managed-byok-provider;
    lib-cloudflare-validation = import ../../tf/tests {inherit pkgs;};
    lib-podman-compose-quadlet-generator-lifecycle = podmanComposeTests.quadlet-generator-lifecycle;
    lib-podman-compose-quadlet-provider-transition = podmanComposeTests.quadlet-provider-transition;
    lib-podman-compose-systemd-user-lifecycle = podmanComposeTests.systemd-user-lifecycle;
    lib-swap-auto-remote-vm = import ../../ab/system/tests/swap-auto-remote-vm.nix {pkgs = pkgs;};
    lib-swap-auto-vm = import ../../ab/system/tests/swap-auto-vm.nix {inherit pkgs;};
  }
