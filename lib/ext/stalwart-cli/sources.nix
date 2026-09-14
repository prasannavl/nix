{
  stalwart-cli = {
    kind = "github-release";
    owner = "stalwartlabs";
    repo = "cli";
    tagPrefix = "v";
    version = "1.0.12";
    releases = {
      x86_64-linux = {
        target = "x86_64-unknown-linux-musl";
        hash = "sha256-dvzXJQoQx77nBNxKCAALP6ymtaIoldQYMcDDfv2VrM4=";
      };
      aarch64-linux = {
        target = "aarch64-unknown-linux-musl";
        hash = "sha256-Wd/11SGA32ae7HBes/4rgM7pJnKR6IEjvXKvhV1MW8M=";
      };
      x86_64-darwin = {
        target = "x86_64-apple-darwin";
        hash = "sha256-Vd1OvsjyWAOaaz4rzoLz+YVtKOv3MZZv1XVIBJcwY1w=";
      };
      aarch64-darwin = {
        target = "aarch64-apple-darwin";
        hash = "sha256-TD4vy83lk4FHOUJtrTaahOqoIUDa91EkWiXCdhpSJM8=";
      };
    };
  };
}
