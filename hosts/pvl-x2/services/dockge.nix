{...}: {
  config.services.podmanCompose.pvl.instances.dockge = {
    workDir,
    stackDir,
    podmanSocket,
    ...
  }: rec {
    exposedPorts.http = {
      port = 5001;
      openFirewall = true;
    };

    source = {
      services.dockge = {
        image = "louislam/dockge:1";
        restart = "unless-stopped";
        user = "0:0";
        ports = ["${toString exposedPorts.http.port}:5001"];
        volumes = [
          "${podmanSocket}:/var/run/docker.sock"
          "${workDir}/data:/app/data"
          "${stackDir}:${stackDir}"
        ];
        environment.DOCKGE_STACKS_DIR = stackDir;
      };
    };
  };
}
