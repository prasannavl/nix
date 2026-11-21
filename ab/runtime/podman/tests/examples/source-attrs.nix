{
  services = {
    web = {
      image = "docker.io/library/nginx:latest";
      ports = ["8080:80"];
      volumes = [
        "./config/app.yml:/etc/app.yml:ro"
        "./reload:/etc/reload:ro"
      ];
    };
    worker.image = "docker.io/library/busybox:latest";
  };
}
