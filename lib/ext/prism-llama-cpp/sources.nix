{
  prism-llama-cpp = {
    kind = "github-release";
    owner = "PrismML-Eng";
    repo = "llama.cpp";
    tagPrefix = "";
    # PrismML's rolling fork branch tag: the fork name plus the upstream
    # llama.cpp build it was cut from (b10709) and the fork commit prefix.
    version = "prism-b10772-e8fd209";
    # Release archives are flat directories of llama-server plus its shared
    # libraries, all linked with RUNPATH $ORIGIN. They are bind-mounted over a
    # container's /app rather than patched, so only the archive is pinned.
    assets = {
      rocm = {
        target = "bin-ubuntu-rocm-7.2-x64";
        hash = "sha256-2md77NGrClFMSBJ1+HIIB550nihpCKBKrVpCrP7n+wE=";
      };
      cuda = {
        target = "bin-linux-cuda-12.8-x64";
        hash = "sha256-lLtKjPl93bn/h/AtZU398nRO5fBaXZ3wRj76jXrEd1k=";
      };
    };
  };
}
