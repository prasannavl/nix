{pkgs, ...}: let
  uid = 1234;
  imageRef = "localhost/stalwart-lifecycle:1";
  fixture = pkgs.writeTextDir "bin/stalwart-fixture" ''
    exec 9>/var/lib/stalwart/LOCK
    flock -n 9 || exit 81
    if [ -n "''${STALWART_RECOVERY_MODE:-}" ]; then
      if [ -e /var/lib/stalwart/crash ]; then
        rm /var/lib/stalwart/crash
        exit 41
      fi
      httpd -f -p 8080 -h /web &
      server=$!
      trap 'kill "$server"; wait "$server"; exit 0' TERM
      wait "$server"
      exit $?
    fi
    trap 'sleep 2; exit 0' TERM
    while true; do sleep 1 & wait $!; done
  '';
  imageTar = pkgs.dockerTools.buildLayeredImage {
    name = "localhost/stalwart-lifecycle";
    tag = "1";
    contents = [pkgs.busybox fixture];
    extraCommands = ''
      mkdir web
      echo '{}' > web/index.html
    '';
    config.Cmd = ["/bin/sh" "/bin/stalwart-fixture"];
  };
  imagePackage = imageTar // {passthru.imageRef = imageRef;};
  cli = pkgs.writeTextFile {
    name = "stalwart-lifecycle-cli";
    executable = true;
    text = ''
      #!/bin/sh
      exec wget -qO- "$STALWART_URL"
    '';
  };
  configFile = pkgs.writeText "fixture-config" "{}";
  tokenFile = pkgs.writeText "fixture-token" "test-token";
  apply = pkgs.writeShellApplication {
    name = "fixture-stalwart-apply";
    runtimeInputs = with pkgs; [bash coreutils jq podman systemd util-linux];
    excludeShellChecks = ["SC1091"];
    runtimeEnv = {
      STALWART_CLI_BIN = cli;
      STALWART_CONFIG_HOST_PATH = configFile;
      STALWART_PLAN_HOST_PATH = configFile;
      STALWART_PLAN_CONTAINER_PATH = "/etc/stalwart/plan.json";
      STALWART_DATA_DIR = "/srv/stalwart/data";
      STALWART_KANIDM_LDAP_TOKEN_HOST_PATH = tokenFile;
      STALWART_CREDENTIALS_FILE = tokenFile;
      STALWART_IMAGE = imageRef;
      STALWART_IMAGE_TAR = imageTar;
      STALWART_CONTAINER = "fixture_stalwart_1";
      STALWART_SERVICE_NAME = "fixture-stalwart.service";
      STALWART_RECOVERY_CONTAINER = "fixture-recovery";
      STALWART_RECOVERY_URL = "http://127.0.0.1:18081";
      STALWART_RECOVERY_WAIT_SECONDS = "10";
    };
    text = ''
      source ${../helper.sh}
      stalwart_startup=0
      apply_plan() {
        if [ "$stalwart_startup" -eq 0 ] && [ -e /srv/stalwart/fail ]; then
          rm /srv/stalwart/fail
          return 42
        fi
      }
      main "$@"
    '';
  };
in {
  name = "stalwart-recovery-lifecycle";
  nodes.machine = {...}: {
    imports = [../../../podman-compose];
    system.stateVersion = "26.05";
    systemd.targets.network-online.wantedBy = ["multi-user.target"];
    virtualisation = {
      podman.enable = true;
      cores = 2;
      memorySize = 2048;
      diskSize = 4096;
    };
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
    systemd.tmpfiles.rules = ["d /srv/stalwart 0750 tester tester -" "d /srv/stalwart/data 0750 tester tester -"];
    environment.systemPackages = [apply];
    services.podman-compose.fixture = {
      backend = "quadlet";
      user = "tester";
      stackDir = "/srv/stalwart/compose";
      servicePrefix = "fixture-";
      instances.stalwart = {
        autoStart = false;
        timeoutReadySeconds = 60;
        source.services = {
          stalwart = {
            image = imagePackage;
            container_name = "fixture_stalwart_1";
            volumes = ["/srv/stalwart/data:/var/lib/stalwart"];
          };
          haproxy = {
            image = imagePackage;
            command = ["/bin/sh" "-c" "trap 'exit 0' TERM; sleep infinity & wait $!"];
            depends_on = ["stalwart"];
          };
        };
        preStart = ["${apply}/bin/fixture-stalwart-apply apply-startup"];
        verifyCommand = ["${pkgs.coreutils}/bin/test" "!" "-e" "/srv/stalwart/bad-health"];
      };
    };
  };
  testScript = ''
    machine.start()
    machine.wait_for_unit("user@${toString uid}.service")
    ctl = "systemctl --user -M tester@"
    run = "runuser -u tester -- env HOME=/home/tester XDG_RUNTIME_DIR=/run/user/${toString uid}"
    apply = run + " fixture-stalwart-apply apply"
    parent = "fixture-stalwart.service"
    container = "fixture-stalwart-stalwart-container.service"

    def healthy():
        for unit in [parent, container, "fixture-stalwart-haproxy-container.service"]:
            machine.succeed(f"{ctl} is-active --quiet {unit}")
        machine.succeed(f"{run} podman container exists fixture_stalwart_1")
        machine.fail(f"{run} podman container exists fixture-recovery")

    # Cold start and delayed shutdown use actual generated Quadlet units.
    machine.succeed(f"{ctl} start {parent}")
    healthy()
    machine.succeed(apply)
    healthy()
    # Requests serialize across both the offline apply and nested startup hook.
    machine.succeed(f"{apply} > /srv/stalwart/a.log 2>&1 & a=$!; {apply} > /srv/stalwart/b.log 2>&1 & b=$!; wait $a && wait $b")
    healthy()
    machine.succeed("touch /srv/stalwart/fail; chown tester:tester /srv/stalwart/fail")
    status, _ = machine.execute(apply)
    assert status == 42, status
    healthy()
    machine.succeed("touch /srv/stalwart/data/crash; chown tester:tester /srv/stalwart/data/crash")
    machine.fail(apply)
    healthy()
    machine.succeed("touch /srv/stalwart/bad-health")
    machine.fail(apply)
    machine.succeed(f"{ctl} is-active --quiet {parent}")
    machine.succeed("rm /srv/stalwart/bad-health")
    machine.succeed(f"{ctl} start fixture-stalwart-ready.target")
    healthy()
    machine.succeed(f"{ctl} stop {parent} fixture-stalwart-stage.service")
    machine.succeed(f"{ctl} start {parent}")
    healthy()
  '';
}
