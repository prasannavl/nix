{pkgs, ...}: let
  uid = 1234;
  imageRef = "localhost/podman-provider-transition:1";
  imageTar = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/podman-provider-transition";
    tag = "1";
    contents = [pkgs.busybox];
    config.Cmd = ["/bin/sleep" "infinity"];
  };
  imagePackage =
    imageTar
    // {
      passthru.imageRef = imageRef;
    };
  mkService = containerName: {
    image = imagePackage;
    container_name = containerName;
    command = ["/bin/sleep" "infinity"];
  };
in {
  name = "podman-compose-quadlet-provider-transition";

  nodes.machine = {lib, ...}: {
    imports = [../default.nix];

    system.stateVersion = "26.05";
    networking.hostName = "podman-provider-transition";
    virtualisation.podman.enable = true;
    environment.systemPackages = [pkgs.jq];

    users = {
      manageLingering = true;
      users.tester = {
        isNormalUser = true;
        uid = uid;
        group = "tester";
        home = "/home/tester";
        linger = true;
        autoSubUidGidRange = true;
      };
      groups.tester.gid = uid;
    };

    services.podman-compose.mixed = {
      user = "tester";
      stackDir = "/srv/mixed";
      servicePrefix = "mixed-";
      timeoutReadySeconds = 60;

      instances = {
        provider.source.services.provider = mkService "mixed-provider";
        broken = {
          backend = "quadlet";
          autoStart = false;
          source.services.broken = mkService "mixed-broken";
          files."config.txt".text = "staged before the failing hook\n";
          preStart = ["false"];
        };
        partial = {
          backend = "quadlet";
          autoStart = false;
          source.services = {
            good = mkService "mixed-partial-good";
            bad =
              (mkService "mixed-partial-bad")
              // {
                depends_on = ["good"];
                healthcheck = {
                  test = ["CMD" "/bin/false"];
                  interval = "1s";
                  timeout = "1s";
                  retries = 1;
                  start_period = "1s";
                };
              };
          };
          files."config.txt".text = "staged before the failing container\n";
        };
        consumer = {
          backend = "compose";
          source.services.consumer = mkService "mixed-consumer";
          dependsOn = ["provider"];
        };
      };
    };

    specialisation.quadlet.configuration.services.podman-compose.mixed.instances.consumer.backend =
      lib.mkForce "quadlet";
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("user@${toString uid}.service")

    ctl = "systemctl --user -M tester@"
    podman = "runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/${toString uid} podman"
    root = "tester-managed.target"
    provider = "mixed-provider.service"
    provider_ready = "mixed-provider-ready.target"
    consumer = "mixed-consumer.service"
    consumer_ready = "mixed-consumer-ready.target"
    consumer_stage = "mixed-consumer-stage.service"
    broken = "mixed-broken.service"
    broken_stage = "mixed-broken-stage.service"
    broken_config = "/srv/mixed/broken/config.txt"
    partial = "mixed-partial.service"
    partial_stage = "mixed-partial-stage.service"
    partial_good = "mixed-partial-good-container.service"
    partial_bad = "mixed-partial-bad-container.service"
    partial_network = "mixed-partial-network-network.service"
    partial_config = "/srv/mixed/partial/config.txt"
    private_container = "mixed-consumer-consumer-container.service"
    private_network = "mixed-consumer-network-network.service"
    state = "/srv/mixed/consumer/.podman-compose/state.json"

    def show(unit, prop):
        return machine.succeed(
            f"{ctl} show --property={prop} --value {unit}"
        ).strip()

    def wait_active(*units):
        for unit in units:
            machine.wait_for_unit(unit, "tester")

    def applied_backend():
        return machine.succeed(f"jq -r .appliedBackend {state}").strip()

    def container_id(name):
        return machine.succeed(
            f"{podman} container inspect --format '{{{{.Id}}}}' {name}"
        ).strip()

    def container_label(name, label):
        return machine.succeed(
            f"{podman} container inspect {name} "
            f"| jq -r '.[0].Config.Labels[\"{label}\"] // \"\"'"
        ).strip()

    with subtest("failed native staging cleans runtime files through ExecStopPost"):
        machine.fail(f"{ctl} start {broken}")
        assert show(broken_stage, "Result") == "exit-code"
        machine.fail(f"test -e {broken_config}")
        machine.fail(f"test -e {broken_config}.tmp")
        machine.succeed(f"{ctl} reset-failed {broken} {broken_stage}")

    with subtest("failed native container startup unwinds the private graph"):
        machine.fail(f"{ctl} start {partial}")
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {partial_good}",
            timeout=30,
        )
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {partial_stage}",
            timeout=30,
        )
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {partial_network}",
            timeout=30,
        )
        machine.fail(f"test -e {partial_config}")
        machine.fail(f"test -e {partial_config}.tmp")
        machine.fail(f"{podman} container inspect mixed-partial-good")
        machine.succeed(
            f"{ctl} reset-failed {partial} {partial_bad} {partial_good}"
        )

    wait_active(root, provider, provider_ready, consumer, consumer_ready)

    with subtest("base generation owns both services through Compose"):
        assert applied_backend() == "compose"
        provider_id = container_id("mixed-provider")
        consumer_id = container_id("mixed-consumer")
        assert provider_id
        assert consumer_id
        assert container_label(
            "mixed-consumer", "com.docker.compose.service"
        ) == "consumer"
        assert show(private_container, "LoadState") == "not-found"
        assert show(private_network, "LoadState") == "not-found"

    with subtest("switch migrates only the consumer to private Quadlet"):
        machine.succeed(
            "/run/current-system/specialisation/quadlet/bin/switch-to-configuration test"
        )
        wait_active(
            root,
            provider,
            provider_ready,
            consumer,
            consumer_ready,
            private_network,
            private_container,
        )

        machine.fail(f"test -e {state}")
        assert container_id("mixed-provider") == provider_id
        assert container_id("mixed-consumer") != consumer_id
        assert container_label(
            "mixed-consumer", "com.docker.compose.service"
        ) == ""
        assert show(private_container, "UnitFileState") == "generated"
        assert show(private_container, "Restart") == "no"
        assert show(private_container, "StopWhenUnneeded") == "yes"
        assert show(private_network, "UnitFileState") == "generated"
        assert show(consumer_stage, "ActiveState") == "active"
        assert private_container in show(consumer, "Requires").split()
        assert "podman-runtime-preflight-tester.service" not in show(
            consumer, "Requires"
        ).split()
        assert "NIX_PODMAN_COMPOSE_METADATA" not in show(
            consumer, "Environment"
        )
        container_source = (
            "/etc/containers/systemd/users/${toString uid}/"
            "mixed-consumer-consumer-container.container"
        )
        container_fragment = (
            "/run/user/${toString uid}/systemd/generator/"
            "mixed-consumer-consumer-container.service"
        )
        network_source = (
            "/etc/containers/systemd/users/${toString uid}/"
            "mixed-consumer-network.network"
        )
        network_fragment = (
            "/run/user/${toString uid}/systemd/generator/"
            "mixed-consumer-network-network.service"
        )
        assert {
            show(private_container, "SourcePath"),
            show(private_container, "FragmentPath"),
        } == {
            container_source,
            container_fragment,
        }
        assert {
            show(private_network, "SourcePath"),
            show(private_network, "FragmentPath"),
        } == {
            network_source,
            network_fragment,
        }
        machine.succeed(
            f"grep -Fx 'SourcePath={container_source}' {container_fragment}"
        )
        machine.succeed(
            f"grep -Fx 'SourcePath={network_source}' {network_fragment}"
        )
        machine.succeed(
            f"grep -Fx 'PartOf={consumer}' {container_fragment}"
        )
        machine.succeed(
            f"grep -Fx 'Before={consumer}' {container_fragment}"
        )
        machine.succeed(f"grep -Fx 'TimeoutStartSec=60' {container_source}")
        machine.succeed(f"grep -Fx 'TimeoutStartSec=60' {container_fragment}")

    with subtest("runtime verification never starts an inactive public service"):
        machine.succeed(f"{ctl} stop {consumer}")
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=ActiveState --value {consumer})" = inactive',
            timeout=30,
        )
        runtime = machine.succeed(
            "/run/current-system/sw/bin/podman-composectl expected-runtime tester"
        )
        assert (
            f"inactive-unit service=mixed-consumer unit={consumer}"
            in runtime.splitlines()
        )
        assert show(consumer, "ActiveState") == "inactive"
        machine.fail(
            f"{podman} ps --format '{{{{.Names}}}}' | grep -Fx mixed-consumer"
        )
        machine.succeed(f"{ctl} start {consumer_ready}")
        wait_active(consumer, consumer_ready, private_container)

    with subtest("a private unit exit unwinds the public graph"):
        machine.succeed(f"{podman} stop mixed-consumer")
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=ActiveState --value {private_container})" = failed',
            timeout=30,
        )
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {consumer}",
            timeout=30,
        )
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {consumer_stage}",
            timeout=30,
        )
        machine.wait_until_succeeds(
            f"! {ctl} is-active --quiet {private_network}",
            timeout=30,
        )
        runtime = machine.succeed(
            "/run/current-system/sw/bin/podman-composectl expected-runtime tester"
        )
        assert (
            f"inactive-unit service=mixed-consumer unit={consumer}"
            in runtime.splitlines()
        )
        machine.succeed(f"{ctl} restart {consumer}")
        machine.succeed(f"{ctl} start {consumer_ready}")
        wait_active(consumer, consumer_ready, private_container)

    with subtest("rollback restores Compose and removes the private unit"):
        quadlet_consumer_id = container_id("mixed-consumer")
        machine.succeed("/run/booted-system/bin/switch-to-configuration test")
        wait_active(root, provider, provider_ready, consumer, consumer_ready)
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=LoadState --value {private_container})" = not-found',
            timeout=30,
        )
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=LoadState --value {private_network})" = not-found',
            timeout=30,
        )

        assert applied_backend() == "compose"
        assert container_id("mixed-provider") == provider_id
        assert container_id("mixed-consumer") != quadlet_consumer_id
        assert container_label(
            "mixed-consumer", "com.docker.compose.service"
        ) == "consumer"
  '';
}
