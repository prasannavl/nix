{pkgs}: let
  consumer = import ../consumer.nix;
  select = consumer.selectNoAuth;
  candidate = {
    target = "main";
    provider = "local";
    accountRef = "test-account";
    catalogKey = "qualified-chat";
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
  route = select "openai" "chat" candidate;
  menu = choices: explicit:
    consumer.connectionModels {
      inherit (pkgs) lib;
      main = route;
      inherit choices explicit;
    };
  other =
    route
    // {
      target = "other";
      model = "other-id";
    };
  rejected = choices: !(builtins.tryEval (builtins.deepSeq (menu choices true) true)).success;
in
  assert route == candidate // candidate.apis.openai;
  assert (select "ollama" "chat" candidate).model == "native-id";
  assert select "openai" "chat" null == null;
  assert select "openai" "embedding" candidate == null;
  assert select "missing" "chat" candidate == null;
  assert select "openai" "chat" (candidate // {catalogKey = null;}) == null;
  assert select "openai" "chat" (candidate
    // {
      auth = {
        kind = "bearer";
        credentialRef = "private";
      };
    })
  == null;
  assert select "openai" "chat" (candidate
    // {
      auth = {
        kind = "none";
        credentialRef = "private";
      };
    })
  == null;
  assert menu [other route] true == ["other-id" "compatible-id"];
  assert rejected [];
  assert rejected [other];
  assert rejected [route null];
  assert rejected [route route];
  assert rejected [route (other // {accountRef = "different-account";})];
  assert rejected [route (other // {provider = "different-provider";})];
  assert rejected [route (other // {baseUrl = "http://different.test";})];
  assert menu [route null (other // {accountRef = "different-account";})] false == ["compatible-id"];
    pkgs.runCommand "ai-consumer-selection-test" {} ''touch "$out"''
