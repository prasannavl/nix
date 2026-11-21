let
  mkRegistry = {repository ? null}: let
    core = import ./core;
    runtime = import ./runtime {inherit core;};
    services = import ./services {core = core;};
    repo = import ./repo {inherit core repository;};
    stack = import ./stack {inherit core;};
    system = import ./system {inherit core;};

    forPkgs = {
      pkgs,
      projectRoot ? (
        if repository == null
        then null
        else repository.root or null
      ),
      treefmtConfig ? (
        if repository == null
        then null
        else repository.treefmtConfig or null
      ),
    }:
      core.mk {
        inherit pkgs projectRoot treefmtConfig;
        extensions =
          [
            runtime.extension
            services.extension
            system.extension
          ]
          ++ (
            if repository == null
            then []
            else [repo.extension]
          );
      };
  in {
    inherit core forPkgs repo runtime services stack system;

    withRepository = nextRepository:
      mkRegistry {repository = nextRepository;};
  };
in
  mkRegistry {}
