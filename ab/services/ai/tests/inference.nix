{pkgs}: let
  inferenceLib = import ../inference.nix;
  resolve = inferenceLib.resolveInference;
  hosting = {
    catalog = {
      chat = {
        id = "served-alias";
        ollama = "native-tag:1";
        llama = "example/chat:Q4";
        capabilities = ["chat"];
      };
      embed = {
        id = "embedding-alias";
        ollama = "native-embedding:1";
        capabilities = ["embedding"];
      };
    };
    models = ["chat" "embed"];
  };
  inference = {
    providers = {
      local = {
        endpoint = "cpu";
        auth = "none";
      };
      cloud = {
        apiBases.openai = "https://cloud.example/v1/";
        auth = "bearer";
        accountRef = "account-a";
      };
      other = {
        apiBases.openai = "https://other.example/api";
        auth = "bearer";
        accountRef = "account-b";
      };
    };
    targets = {
      local-chat = {
        provider = "local";
        catalogKey = "chat";
      };
      local-embed = {
        provider = "local";
        catalogKey = "embed";
      };
      cloud-chat = {
        provider = "cloud";
        model = "same-model:1";
      };
      other-chat = {
        provider = "other";
        model = "same-model:1";
      };
    };
    defaults = {
      main = "local-chat";
      embedding = "local-embed";
    };
    consumers = {
      local-app = {};
      cloud-app = {
        roles.main = "cloud-chat";
        credentials.cloud = "cloud-app-key";
      };
      menu-app = {
        choices.main = ["other-chat" "local-chat" "cloud-chat"];
        credentials = {
          cloud = "menu-cloud-key";
          other = "menu-other-key";
        };
      };
    };
  };
  localEndpoints.ollama = [
    {
      instance = "cpu";
      url = "http://models.internal:11434";
      modelIds = ["native-tag:1" "native-embedding:1"];
    }
  ];
  base = {
    inherit hosting inference localEndpoints;
    requests.local-app = ["main" "embedding"];
  };
  local = resolve base;
  cloud = resolve (base
    // {
      hosting = {
        catalog = {};
        models = [];
      };
      localEndpoints = {};
      requests.cloud-app = ["main"];
    });
  menu = resolve (base // {requests.menu-app = ["main"];});
  multi = resolve (base
    // {
      localEndpoints =
        localEndpoints
        // {
          llama = [
            {
              instance = "gpu";
              url = "http://gpu.internal:8080";
              modelIds = ["served-alias"];
            }
          ];
        };
      inference =
        inference
        // {
          providers =
            inference.providers
            // {
              local-gpu = {
                endpoint = "gpu";
                auth = "none";
              };
              unavailable = {
                endpoint = "absent";
                auth = "none";
              };
            };
          targets =
            inference.targets
            // {
              gpu-chat = {
                provider = "local-gpu";
                catalogKey = "chat";
              };
              unavailable-chat = {
                provider = "unavailable";
                catalogKey = "chat";
              };
            };
        };
    });
  updateConsumer = name: value: base // {inference = inference // {consumers = inference.consumers // {${name} = value;};};};
  invalid = input: let result = resolve input; in !result.valid && result.consumers == {} && result.diagnostics != [];
  strictFailure = input: (builtins.tryEval (builtins.deepSeq (resolve input) true)).success;
in
  assert local.valid;
  assert builtins.attrNames local.consumers == ["local-app"];
  assert local.consumers.local-app.roles.main.apis
  == {
    ollama = {
      baseUrl = "http://models.internal:11434";
      model = "native-tag:1";
    };
    openai = {
      baseUrl = "http://models.internal:11434/v1";
      model = "native-tag:1";
    };
  };
  assert local.consumers.local-app.roles.embedding.capabilities == ["embedding"];
  assert builtins.map (choice: choice.target) local.consumers.local-app.choices.main == ["local-chat" "local-embed"];
  assert cloud.valid && builtins.attrNames cloud.consumers == ["cloud-app"];
  assert cloud.consumers.cloud-app.roles.main.auth.credentialRef == "cloud-app-key";
  assert cloud.consumers.cloud-app.roles.main.apis.openai.baseUrl == "https://cloud.example/v1";
  assert menu.valid;
  assert builtins.map (choice: choice.target) menu.consumers.menu-app.choices.main == ["other-chat" "local-chat" "cloud-chat"];
  assert (builtins.head menu.consumers.menu-app.choices.main).accountRef == "account-b";
  assert (resolve (base // {requests = {};})).consumers == {};
  assert (resolve (base
    // {
      requests = {};
      localEndpoints = throw "declaration-only validation forced unused topology";
      hosting = throw "declaration-only validation forced hosting";
    })).valid;
  assert multi.valid;
  assert builtins.map (choice: choice.target) multi.consumers.local-app.choices.main == ["gpu-chat" "local-chat" "local-embed"];
  assert (builtins.head multi.consumers.local-app.choices.main).apis
  == {
    openai = {
      baseUrl = "http://gpu.internal:8080/v1";
      model = "served-alias";
    };
  };
  assert invalid (base
    // {
      requests = {};
      inference =
        inference
        // {
          targets =
            inference.targets
            // {
              invalid = {
                provider = "cloud";
                catalogKey = "chat";
              };
            };
        };
    });
  assert invalid (base
    // {
      requests = {};
      inference =
        inference
        // {
          targets =
            inference.targets
            // {
              invalid = {
                provider = "local";
                model = "native-tag:1";
              };
            };
        };
    });
  assert invalid (base // {requests.unknown = ["main"];});
  assert invalid (base // {requests.local-app = ["main" "main"];});
  assert invalid (base // {requests.local-app = [];});
  assert invalid (updateConsumer "local-app" {roles.typographical = "local-chat";});
  assert invalid (updateConsumer "local-app" {roles.main = {};});
  assert invalid (updateConsumer "local-app" {optionalRoles = ["main"];});
  assert invalid (updateConsumer "local-app" {choices.main = ["local-embed"];});
  assert invalid (updateConsumer "local-app" {choices.main = ["local-chat" "local-chat"];});
  assert invalid (updateConsumer "local-app" {credentials.local = "not-permitted";});
  assert invalid (base // {hosting = hosting // {models = [];};});
  assert invalid (base // {localEndpoints.ollama = [];});
  assert invalid (base // {localEndpoints = localEndpoints // {llama = localEndpoints.ollama;};});
  assert (resolve (updateConsumer "local-app" {roles.main = null;})).consumers.local-app.roles.main == null;
  assert (resolve (updateConsumer "local-app" {roles.main = null;})).consumers.local-app.choices.main == [];
  assert builtins.all (value: invalid (base // {inference = value;})) [null 1 [] "invalid" {providers.invalid = {auth = "none";};}];
  assert builtins.all (value: strictFailure (base // {requests = value;}) && invalid (base // {requests = value;})) [null 1 [] "invalid"];
  assert builtins.all (url: invalid (base // {inference = inference // {providers = inference.providers // {cloud = inference.providers.cloud // {apiBases.openai = url;};};};})) [
    "http://cloud.example/v1"
    "https://user:password@cloud.example/v1"
    "https://cloud.example/v1?key=secret"
    "https://cloud.example/v1#secret"
    "https://cloud.example/../v1"
    "https://cloud.example/%0a"
  ];
    pkgs.runCommand "ai-inference-test" {} ''touch "$out"''
