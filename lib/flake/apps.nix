{
  packageSet,
  lint ? null,
}: let
  baseApps = {
    "hello-rust" = {
      type = "app";
      program = "${packageSet.hello-rust}/bin/hello-rust";
    };

    nixbot = {
      type = "app";
      program = "${packageSet.nixbot}/bin/nixbot";
    };

    "cloudflare-apps-deploy" = {
      type = "app";
      program = "${packageSet.cloudflare-apps.deploy}/bin/cloudflare-apps-deploy";
    };

    "gap3-ai-wrangler-deploy" = {
      type = "app";
      program = "${packageSet.cloudflare-apps.gap3-ai.wrangler-deploy}/bin/gap3-ai-wrangler-deploy";
    };

    "llmug-hello-wrangler-deploy" = {
      type = "app";
      program = "${packageSet.cloudflare-apps.llmug-hello.wrangler-deploy}/bin/llmug-hello-wrangler-deploy";
    };
  };
in
  baseApps
  // (
    if lint == null
    then {}
    else lint.apps
  )
