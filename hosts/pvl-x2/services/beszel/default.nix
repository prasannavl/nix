{
  config,
  stack,
  ...
}: {
  config = {
    services.podman-compose.pvl.instances.beszel = {podmanSocket, ...}: rec {
      exposedPorts.http = {
        port = 8090;
        openFirewall = true;
      };

      source = ''
        services:
          beszel:
            image: henrygd/beszel:latest
            container_name: beszel
            user: 0:0
            ports:
              - "${toString exposedPorts.http.port}:8090"
            volumes:
              - ./beszel_data:/beszel_data
              - ./beszel_socket:/beszel_socket

          beszel-agent:
            image: henrygd/beszel-agent:latest
            container_name: beszel-agent
            user: 0:0
            network_mode: host
            volumes:
              - ./beszel_agent_data:/var/lib/beszel-agent
              - ./beszel_socket:/beszel_socket
              - ${podmanSocket}:/var/run/docker.sock:ro
            environment:
              LISTEN: /beszel_socket/beszel.sock
              HUB_URL: http://localhost:${toString exposedPorts.http.port}
      '';

      envSecrets."beszel-agent" = {
        KEY = config.age.secrets.beszel-key.path;
        TOKEN = config.age.secrets.beszel-token.path;
      };
    };

    age.secrets = let
      composeSecretUser = "pvl";
    in {
      beszel-key = {
        file = stack.secrets.serviceKey "beszel" "key";
        owner = composeSecretUser;
        group = composeSecretUser;
      };
      beszel-token = {
        file = stack.secrets.serviceKey "beszel" "token";
        owner = composeSecretUser;
        group = composeSecretUser;
      };
    };
  };
}
