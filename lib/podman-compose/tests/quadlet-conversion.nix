{pkgs}: let
  lib = pkgs.lib;
  backend = import ../quadlet.nix {
    inherit lib pkgs;
    config.users.users.tester.uid = 1234;
  };
  serviceDefaults = {
    composeArgs = [];
    reload.method = "restart";
    removalPolicy = "delete";
    adopt = false;
    subnet = null;
    longRunning = true;
  };
  convert = {
    source,
    service ? serviceDefaults,
    baseService ? {entryFile = null;},
  }:
    backend.mkConversion {
      inherit source service baseService;
      systemdServiceName = "test-native";
      workingDir = "/srv/test/native";
      envSecretRuntimePaths = {};
      envSecretTargetServices = [];
      fileSecretMountsForService = _: [];
      fileSecretTargetServices = [];
      trustedCaEnvironmentForService = _: {};
    };
  valid = convert {
    source.services.web = {
      image = "docker.io/library/busybox:latest";
      command = ["sleep" 30];
      environment.ENABLED = true;
      env_file = ["./app.env"];
      ports = ["127.0.0.1:18080:8080"];
      volumes = ["./data:/data:ro"];
    };
  };
  rejects = needle: conversion:
    assert !conversion.supported;
    assert lib.any (lib.hasInfix needle) conversion.unsupported; true;
in
  assert valid.supported;
  assert valid.service.volumes == ["/srv/test/native/data:/data:ro"];
  assert valid.service.envFiles == ["/srv/test/native/app.env"];
  assert rejects "exactly one service" (convert {
    source.services = {
      one.image = "one";
      two.image = "two";
    };
  });
  assert rejects "unsupported top-level keys" (convert {
    source = {
      services.web.image = "one";
      volumes.data = {};
    };
  });
  assert rejects "unsupported service keys" (convert {
    source.services.web = {
      image = "one";
      depends_on = ["db"];
    };
  });
  assert rejects "named and anonymous volumes" (convert {
    source.services.web = {
      image = "one";
      volumes = ["data:/data"];
    };
  });
  assert rejects "named and anonymous volumes" (convert {
    source.services.web = {
      image = "one";
      volumes = "./data:/data";
    };
  });
  assert rejects "primitive values" (convert {
    source.services.web = {
      image = "one";
      environment.BAD.nested = true;
    };
  });
  assert rejects "primitive values" (convert {
    source.services.web = {
      image = "one";
      environment = ["MISSING_VALUE"];
    };
  });
  assert rejects "working_dir must be absolute" (convert {
    source.services.web = {
      image = "one";
      working_dir = "relative";
    };
  });
  assert rejects "must be strings" (convert {
    source.services.web = {
      image = "one";
      working_dir = 42;
    };
  });
  assert rejects "service must be an attrset" (convert {
    source.services.web = "not-an-attrset";
  });
  assert rejects "primitive argv list" (convert {
    source.services.web = {
      image = "one";
      command = "sleep 30";
    };
  });
  assert rejects "requires removalPolicy" (convert {
    source.services.web.image = "one";
    service = serviceDefaults // {removalPolicy = "keep";};
  });
  assert rejects "signal reload" (convert {
    source.services.web.image = "one";
    service = serviceDefaults // {reload.method = "signal";};
  });
  assert rejects "one-shot/job" (convert {
    source.services.web.image = "one";
    service = serviceDefaults // {longRunning = false;};
  });
  assert rejects "envSecrets target other services" (backend.mkConversion {
    source.services.web.image = "one";
    service = serviceDefaults;
    baseService.entryFile = null;
    systemdServiceName = "test-native";
    workingDir = "/srv/test/native";
    envSecretRuntimePaths = {};
    envSecretTargetServices = ["worker"];
    fileSecretMountsForService = _: [];
    fileSecretTargetServices = [];
    trustedCaEnvironmentForService = _: {};
  });
  assert rejects "mounted fileSecrets target other services" (backend.mkConversion {
    source.services.web.image = "one";
    service = serviceDefaults;
    baseService.entryFile = null;
    systemdServiceName = "test-native";
    workingDir = "/srv/test/native";
    envSecretRuntimePaths = {};
    envSecretTargetServices = [];
    fileSecretMountsForService = _: [];
    fileSecretTargetServices = ["worker"];
    trustedCaEnvironmentForService = _: {};
  });
    pkgs.runCommand "podman-compose-quadlet-conversion-test" {} ''
      touch "$out"
    ''
