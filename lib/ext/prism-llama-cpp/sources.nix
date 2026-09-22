{
  prism-llama-cpp = {
    kind = "github-release";
    owner = "PrismML-Eng";
    repo = "llama.cpp";
    tagPrefix = "";
    # PrismML's rolling fork branch tag: the fork name plus the upstream
    # llama.cpp build it was cut from (b10709) and the fork commit prefix.
    version = "prism-b10709-9a9394a";
    # Release archives are flat directories of llama-server plus its shared
    # libraries, all linked with RUNPATH $ORIGIN. They are bind-mounted over a
    # container's /app rather than patched, so only the archive is pinned.
    assets = {
      rocm = {
        target = "bin-ubuntu-rocm-7.2-x64";
        hash = "sha256-Iw+HnVOLufeU0lyQi8jA9nZ3TEHD5w6nGRMchtiZhB0=";
      };
      cuda = {
        target = "bin-linux-cuda-12.8-x64";
        hash = "sha256-iuxn6wI7JRcSx+ZJDzZ7VnG/WH7O0UNqm4X0qQw7fT0=";
      };
    };
  };
}
