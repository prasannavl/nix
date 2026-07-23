{pkgs, ...}: let
  uid = 1234;
  fixture = pkgs.writeText "test-native.container" ''
    [Unit]
    Description=private Quadlet transition fixture

    [Container]
    Image=docker.io/library/busybox:latest
    Pull=never
    ContainerName=test-native
    Label=io.abird.podman-compose.backend=quadlet

    [Service]
    Restart=no
  '';
in {
  name = "podman-compose-quadlet-generator-lifecycle";

  nodes.machine = {...}: {
    system.stateVersion = "26.05";
    virtualisation.podman.enable = true;
    environment.etc."containers/systemd/users/${toString uid}/test-native.container".source = fixture;
    users = {
      manageLingering = true;
      users.tester = {
        isNormalUser = true;
        uid = uid;
        linger = true;
      };
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("user@${toString uid}.service")

    ctl = "systemctl --user -M tester@"
    unit = "test-native.service"
    unit_dir = "/etc/containers/systemd/users/${toString uid}"

    with subtest("declarative private Quadlet has no install membership"):
        machine.succeed("test -x /run/current-system/sw/lib/systemd/user-generators/podman-user-generator")
        machine.succeed("test -x /etc/systemd/user-generators/podman-user-generator")
        machine.succeed(f"{ctl} show-environment | grep -F 'HOME=/home/tester'")
        dry_run = machine.succeed(
            "su tester -s /bin/sh -c 'HOME=/home/tester XDG_RUNTIME_DIR=/run/user/${toString uid} "
            "/run/current-system/sw/lib/systemd/user-generators/podman-user-generator --user --dryrun --no-kmsg-log'"
        )
        assert "test-native.service" in dry_run
        machine.succeed(f"{ctl} daemon-reload")
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=LoadState --value {unit})" = loaded',
            timeout=30,
        )
        assert machine.succeed(
            f"{ctl} show --property=UnitFileState --value {unit}"
        ).strip() == "generated"
        fragment_path = machine.succeed(
            f"{ctl} show --property=FragmentPath --value {unit}"
        ).strip()
        assert machine.succeed(
            f"{ctl} show --property=SourcePath --value {unit}"
        ).strip() == f"{unit_dir}/test-native.container"
        assert fragment_path == f"/run/user/${toString uid}/systemd/generator/{unit}"
        machine.fail(f"grep -F '[Install]' {fragment_path}")
        assert machine.succeed(
            f"{ctl} show --property=Restart --value {unit}"
        ).strip() == "no"

    with subtest("generated-file removal plus daemon reload removes the private unit"):
        machine.succeed(f"rm {unit_dir}/test-native.container")
        machine.succeed(f"{ctl} daemon-reload")
        machine.wait_until_succeeds(
            f'test "$({ctl} show --property=LoadState --value {unit})" = not-found',
            timeout=30,
        )
  '';
}
