let
  backends = import ./backends.nix;
  prefetch = import ./prefetch.nix;
in {
  inherit backends prefetch;
  catalog = import ./catalog.nix;
  consumer = import ./consumer.nix;
  deployment.plan = import ./deployment.nix {
    backendLib = backends;
    prefetchLib = prefetch;
  };
  inference = import ./inference.nix;
  module = ./module.nix;
  modelPrefetch = {
    cachePreparer = ./model-prefetch-cache.py;
    script = ./model-prefetch.sh;
  };
  projection = import ./projection.nix;
  runtime = ./runtime.py;
}
