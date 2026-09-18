{pkgs}: let
  registryLib = import ../service-registry.nix;
  fixtureArgs = {
    endpointGroups = {
      live = {
        project = "prod";
        subnetOctet = 30;
        weight = 100;
      };
      cold = {
        project = "stage";
        subnetOctet = 31;
        weight = 0;
      };
    };
    dnsRouteDomains = [];
    internalDomain = "example.internal";
    roleHosts = {
      proxy = "server";
      client = "caller";
    };
    roleOctets = {
      proxy = 60;
      client = 62;
    };
    serviceSpecs = {
      mail = {
        role = "proxy";
        ports.smtp = {
          port = 10026;
          allowedServices = ["app" "native" "app"];
        };
      };
      app = {
        role = "client";
        podmanSubnet = "10.89.3.0/24";
      };
      native = {role = "client";};
      denied = {role = "client";};
    };
  };
  fixture = overrides: registryLib.mkServiceRegistry (fixtureArgs // overrides);
  base = fixture {};
  endpoint = registry: client:
    registry.clientEndpointForService {
      inherit client;
      service = "mail";
      portName = "smtp";
    };
  cidrs = registry: registry.allowedClientIpv4CidrsFor "mail" "smtp";
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  colocated = fixture {
    roleHosts = fixtureArgs.roleHosts // {client = "server";};
    roleOctets = fixtureArgs.roleOctets // {client = 60;};
  };
  differentAddress = fixture {roleHosts = fixtureArgs.roleHosts // {client = "server";};};
  differentProject = fixture {
    roleHosts = fixtureArgs.roleHosts // {client = "server";};
    roleEndpoints.client = {
      project = "other";
      address = "10.10.30.60";
    };
  };
  coldClient = fixture {serviceSpecs = fixtureArgs.serviceSpecs // {app = fixtureArgs.serviceSpecs.app // {placement = "cold";};};};
  ipv6 = fixture {roleEndpoints.client.address = "fd42::62";};
  badSubnet = fixture {
    serviceSpecs =
      fixtureArgs.serviceSpecs
      // {
        app =
          fixtureArgs.serviceSpecs.app
          // {
            role = "proxy";
            podmanSubnet = "fd42::/64";
          };
      };
  };
  noPolicy = fixture {
    serviceSpecs =
      fixtureArgs.serviceSpecs
      // {
        mail = {
          role = "proxy";
          ports.smtp.port = 10026;
        };
      };
  };
  unknownClient = fixture {
    serviceSpecs =
      fixtureArgs.serviceSpecs
      // {
        mail = {
          role = "proxy";
          ports.smtp = {
            port = 10026;
            allowedServices = ["missing"];
          };
        };
      };
  };
in
  assert (endpoint base "app")
  == {
    host = "10.10.30.60";
    port = 10026;
  };
  assert cidrs base == ["10.10.30.62/32"];
  assert (endpoint colocated "app").host == "host.containers.internal";
  assert (endpoint colocated "native").host == "10.10.30.60";
  assert cidrs colocated == ["10.89.3.0/24" "10.10.30.60/32"];
  assert (endpoint differentAddress "app").host == "10.10.30.60";
  assert cidrs differentAddress == ["10.10.30.62/32"];
  assert (endpoint differentProject "app").host == "10.10.30.60";
  assert cidrs differentProject == ["10.10.30.60/32"];
  assert (endpoint coldClient "app").host == "10.10.30.60";
  assert cidrs coldClient == ["10.10.31.62/32" "10.10.30.62/32"];
  assert fails (endpoint base "denied");
  assert fails (endpoint noPolicy "app");
  assert cidrs noPolicy == [];
  assert fails (cidrs unknownClient);
  assert fails (cidrs ipv6);
  assert fails (cidrs badSubnet);
    pkgs.runCommand "service-client-endpoints-test" {} ''
      touch "$out"
    ''
