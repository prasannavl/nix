{pkgs}: let
  consumer = import ../consumer.nix;
  candidate = {
    target = "main";
    provider = "local";
    accountRef = "test-account";
    catalogKey = "required-chat";
    capabilities = ["chat"];
    auth = {
      kind = "none";
      credentialRef = null;
    };
    apis = {
      openai = {
        baseUrl = "http://compatible.test/v1";
        model = "compatible-id";
      };
      ollama = {
        baseUrl = "http://native.test";
        model = "native-id";
      };
    };
  };
  withOpenai = value: overrides: value // {apis = value.apis // {openai = value.apis.openai // overrides;};};
  other = withOpenai (candidate
    // {
      target = "other";
      catalogKey = "another-required-chat";
    }) {model = "other-id";};
  remote =
    candidate
    // {
      provider = "cloud";
      accountRef = "cloud-account";
      catalogKey = null;
      capabilities = [];
      auth = {
        kind = "bearer";
        credentialRef = "private";
      };
    };
  base = {
    roles = {
      main = candidate;
      smallTask = other;
    };
    choices.main = [other candidate];
    explicitChoiceRoles = ["main"];
  };
  spec = {
    roles.main = {};
    menu = "connection";
  };
  fails = value: !(builtins.tryEval (builtins.deepSeq value true)).success;
  bind = bindings: request:
    consumer.bind {
      resolve = name: roles:
        assert name == "fixture";
        assert roles == builtins.attrNames request.roles; bindings;
      roleCapabilities = {
        main = "chat";
        smallTask = "chat";
        embedding = "embedding";
      };
      catalog.required-chat.pinned = true;
      presentation = {
        labelPrefix = "Provider ";
        providers.local = {
          label = "Local";
          prefixes.ollama = "";
          pinCatalog = true;
        };
      };
    } "fixture"
    request;
  bindRole = role: value: spec:
    (bind {roles.${role} = value;} {roles.${role} = spec;}).roles.${role};
  embedding = candidate // {capabilities = ["embedding"];};
  multiPurpose = candidate // {capabilities = ["chat" "embedding"];};
  requireModel = value:
    bind {roles.main = value;} {
      roles.main.requiredModel = "required-chat";
    };
  protected =
    (requireModel (withOpenai candidate {
      provider = "wrong-provider";
      accountRef = "wrong-account";
      target = "wrong-target";
      capabilities = ["embedding"];
      auth = {
        kind = "bearer";
        credentialRef = "not-owned";
      };
    })).roles.main;
  menu = choices: explicit: overrides:
    (bind (base
      // {
        choices.main = choices;
        explicitChoiceRoles =
          if explicit
          then ["main"]
          else [];
      }) (spec // overrides)).menu;
  rejected = choices: fails (menu choices true {});
  groups = choices: (menu choices false {menu = "providers";}).connections;
  client = bind base (spec
    // {
      roles.main.requiredModel = "required-chat";
    });
  remoteChat = {
    allowRemote = true;
    transports = [
      {
        api = "ollama";
        auth = ["none"];
      }
      {
        api = "openai";
        auth = ["none" "bearer"];
      }
    ];
  };
  preferred = value:
    bind {roles.main = value;} {
      roles.main = remoteChat;
      credentialFiles = {
        private = "/run/private";
        unused = throw "Unused credentials must stay unforced";
      };
    };
  cyclicClient = bind {roles.main = remote;} {
    roles.main = remoteChat;
    credentialFiles.private = secret.path;
  };
  secret =
    if cyclicClient.credentialFiles != {}
    then {path = "/custom/agenix/provider-key";}
    else {};
  withFile = path:
    bind {roles.main = remote;} {
      roles.main = remoteChat;
      credentialFiles.private = path;
    };
  taskRoles = {
    main = {};
    smallTask = {};
  };
  colliding = [
    candidate
    (withOpenai other {model = "foo.bar";})
    (withOpenai (other
      // {
        target = "third";
        provider = "local.foo";
      }) {model = "bar";})
  ];
in
  # The whole result is checked, plain data; no selectors, callbacks or raw catalog data.
  assert builtins.fromJSON (builtins.toJSON client) == client;
  assert !(client.roles.main ? catalogKey);
  assert client.roles.main.capabilities == candidate.capabilities;
  assert client.roles.main.model == "compatible-id";
  assert client.roles.main.protocol == "openai-compatible";
  assert client.roles.main.id == "local.compatible-id";
  assert client.roles.main.label == "Local";
  assert client.menu.models == ["other-id" "compatible-id"];
  assert client.menu.ids == ["local.other-id" "local.compatible-id"];
  assert client.menu.pinnedModels == ["local.compatible-id"];
  assert client.credentialFiles == {};
  assert (requireModel candidate).roles.main.model == "compatible-id";
  assert protected.provider == candidate.provider && protected.accountRef == candidate.accountRef;
  assert protected.auth == candidate.auth && protected.target == candidate.target;
  assert protected.apis == candidate.apis;
  assert protected.capabilities == candidate.capabilities;
  assert fails (requireModel (candidate // {catalogKey = "other";}));
  assert fails (requireModel null);
  assert fails (requireModel remote);
  assert fails (requireModel (candidate // {apis = {};}));
  assert fails (requireModel (candidate // {capabilities = ["embedding"];}));
  assert fails (requireModel (candidate
    // {
      auth = {
        kind = "none";
        credentialRef = "private";
      };
    }));
  assert fails (bind base {
    roles.main = {
      api = "unknown";
    };
  });
  assert fails (bind base (spec // {menu = "unknown";}));
  assert (bind {roles.main = candidate;} {
    api = "ollama";
    roles.main = {};
  }).roles.main.id
  == "native-id";
  assert (bind {
    roles.main = candidate;
    choices = throw "A scalar client must not inspect menus";
    explicitChoiceRoles = throw "A scalar client must not inspect menus";
  } {roles.main = {};}).roles.main.model
  == "compatible-id";
  # Role intent defaults independently of the selected model; overrides cannot invent support.
  assert (bindRole "main" other {}).model == "other-id";
  assert (bindRole "smallTask" candidate {}).capabilities == ["chat"];
  assert (bindRole "embedding" embedding {}).capabilities == ["embedding"];
  assert fails (bindRole "main" embedding {});
  assert fails (bindRole "smallTask" embedding {});
  assert fails (bindRole "embedding" candidate {});
  assert (bindRole "main" embedding {capability = "embedding";}).capabilities == ["embedding"];
  assert fails (bindRole "main" candidate {capability = "embedding";});
  assert (bindRole "embedding" multiPurpose {}).capabilities == ["chat" "embedding"];
  assert (bindRole "main" multiPurpose {}).capabilities == ["chat" "embedding"];
  assert (bindRole "main" multiPurpose {capability = "embedding";}).capabilities == ["chat" "embedding"];
  assert fails (bindRole "custom" candidate {});
  assert (bindRole "custom" candidate {capability = "chat";}).model == "compatible-id";
  assert fails (bindRole "custom" candidate {capability = "embedding";});
  # Required models reject another otherwise-valid selection; they do not choose a replacement.
  assert fails (requireModel other);
  # Explicit unsupported choices fail; derived choices may filter. Required models do not pin menus.
  assert rejected [];
  assert rejected [other];
  assert rejected [candidate null];
  assert rejected [candidate candidate];
  assert rejected [candidate (other // {accountRef = "different-account";})];
  assert rejected [candidate (other // {provider = "different-provider";})];
  assert rejected [candidate (withOpenai other {baseUrl = "http://different.test";})];
  assert (menu [candidate null (other // {accountRef = "different-account";})] false {}).models == ["compatible-id"];
  assert fails (menu [candidate] false {roles = taskRoles;});
  assert fails (menu [other] false {roles = taskRoles;});
  assert fails (bind (base // {explicitChoiceRoles = ["main" "smallTask"];}) (spec // {roles = taskRoles;}));
  # A matching target is insufficient when a task requires a different API/model surface.
  assert fails (bind base (spec // {roles = taskRoles // {smallTask = taskRoles.smallTask // {api = "ollama";};};}));
  # Stable connection/model ordering. Only a namespaced menu requires globally unique IDs.
  assert (builtins.head (groups [other candidate])).models == ["other-id" "compatible-id"];
  assert fails (groups [candidate (other // {accountRef = "different";})]);
  assert fails (groups [candidate candidate]);
  assert builtins.map (value: value.provider) (groups [other (candidate // {provider = "second";}) candidate]) == ["local" "second"];
  assert builtins.length (groups colliding) == 2;
  assert fails (menu colliding true {menu = "namespaced";});
  # Native preference never routes bearer credentials to a native API.
  assert (preferred candidate).roles.main.protocol == "ollama";
  assert (preferred candidate).credentialFiles == {};
  assert (preferred remote).roles.main.protocol == "openai-compatible";
  assert (preferred remote).roles.main.auth == remote.auth;
  assert (preferred remote).roles.main.capabilities == [];
  assert (preferred remote).roles.main.label == "Provider cloud";
  assert (preferred remote).credentialFiles == {private = "/run/private";};
  # Slot ownership is eager; agenix paths resolve after the module fixed point.
  assert cyclicClient.credentialFiles == {private = "/custom/agenix/provider-key";};
  assert builtins.fromJSON (builtins.toJSON cyclicClient) == cyclicClient;
  assert (withFile (throw "Runtime path must stay lazy")).roles.main.model == "compatible-id";
  assert (withFile null).credentialFiles == {private = null;};
  assert fails (withFile "relative/key");
  assert fails (withFile (_: "/run/key"));
  assert fails (bind {roles.main = remote;} {roles.main = remoteChat // {allowRemote = false;};});
  assert fails (bind {roles.main = remote;} {roles.main = remoteChat // {capability = "typo";};});
  assert fails (preferred null);
  assert fails (preferred (candidate // {capabilities = ["embedding"];}));
  assert fails (preferred (remote // {apis = {};}));
  assert fails (preferred (remote
    // {
      auth = {
        kind = "bearer";
        credentialRef = null;
      };
    }));
  assert fails (bind {roles.main = remote;} {roles.main = remoteChat;}).roles.main;
    pkgs.runCommand "ai-consumer-selection-test" {} ''touch "$out"''
