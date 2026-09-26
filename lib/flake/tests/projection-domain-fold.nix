{pkgs}: let
  mkOutput = {
    domain,
    admission ? {enabled = false;},
    claims ? [],
    nextContext ? {},
    ownedPaths ? ["config/test/${domain}.nix"],
    runtimeSchema ? 1,
  }: {
    schema_version = 1;
    contract = {inherit domain;};
    generation = {documents = [domain];};
    runtime = {
      plans = [
        {
          schema_version = runtimeSchema;
          adapter = "test-runtime";
          payload = {inherit domain;};
        }
      ];
    };
    inherit admission;
    inherit claims;
    repository = {
      document_kind = domain;
      owned_paths = ownedPaths;
    };
    next_context = nextContext;
  };
  adapters = {
    placements = {
      schema_version = 1;
      dependencies = [];
      evaluate = _:
        mkOutput {
          domain = "placements";
          nextContext.placementsReady = true;
        };
    };
    identities = {
      schema_version = 1;
      dependencies = ["placements"];
      evaluate = state:
        assert state.context.placementsReady;
          mkOutput {
            domain = "identities";
            claims = [
              {
                namespace = "identity";
                key = "abird/alice";
                owner = "alice";
                access = "exclusive";
                overlap = "exact";
              }
            ];
          };
    };
  };
  folded = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    inherit adapters;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments = {
      placements = {};
      identities = {};
    };
  };
  minimalFold = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    fragments.minimal = {};
    adapters.minimal = {
      schema_version = 1;
      dependencies = [];
      evaluate = _: {
        schema_version = 1;
        contract = {enabled = true;};
      };
    };
  };
  conflicting = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments = {
      left = {};
      right = {};
    };
    adapters =
      builtins.mapAttrs (domain: _: {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            inherit domain;
            claims = [
              {
                namespace = "host-resource";
                key = "abird-proxy/service:nginx";
                owner = "same-logical-id";
                access = "exclusive";
                overlap = "exact";
              }
            ];
          };
      }) {
        left = null;
        right = null;
      };
  };
  unsafeRepository = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments.unsafe = {};
    adapters.unsafe = {
      schema_version = 1;
      dependencies = [];
      evaluate = _:
        mkOutput {
          domain = "unsafe";
          ownedPaths = ["../outside.nix"];
        };
    };
  };
  gitMetadataRepository = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments.unsafe = {};
    adapters.unsafe = {
      schema_version = 1;
      dependencies = [];
      evaluate = _:
        mkOutput {
          domain = "unsafe";
          ownedPaths = ["config/.git/config"];
        };
    };
  };
  controlCharacterRepository = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments.unsafe = {};
    adapters.unsafe = {
      schema_version = 1;
      dependencies = [];
      evaluate = _:
        mkOutput {
          domain = "unsafe";
          ownedPaths = ["config/test/unsafe\npath.nix"];
        };
    };
  };
  overlappingRepository = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments = {
      parent = {};
      child = {};
    };
    adapters = {
      parent = {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            domain = "parent";
            ownedPaths = ["config/test"];
          };
      };
      child = {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            domain = "child";
            ownedPaths = ["config/test/child.nix"];
          };
      };
    };
  };
  cyclic = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments = {
        parent = {};
        child = {};
      };
      adapters = {
        parent = {
          schema_version = 1;
          dependencies = ["child"];
          evaluate = _:
            mkOutput {
              domain = "parent";
              ownedPaths = ["config/test/parent.nix"];
            };
        };
        child = {
          schema_version = 1;
          dependencies = ["parent"];
          evaluate = _:
            mkOutput {
              domain = "child";
              ownedPaths = ["config/test/child.nix"];
            };
        };
      };
    }).domains
    true);
  missingDependency = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments.child = {};
      adapters.child = {
        schema_version = 1;
        dependencies = ["missing"];
        evaluate = _:
          mkOutput {
            domain = "child";
            ownedPaths = ["config/test/child.nix"];
          };
      };
    }).domains
    true);
  duplicateDependency = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments = {
        parent = {};
        child = {};
      };
      adapters = {
        parent = {
          schema_version = 1;
          dependencies = [];
          evaluate = _: mkOutput {domain = "parent";};
        };
        child = {
          schema_version = 1;
          dependencies = ["parent" "parent"];
          evaluate = _: mkOutput {domain = "child";};
        };
      };
    }).domains
    true);
  undeclaredDependency = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments = {
        a = {};
        b = {};
      };
      adapters = {
        a = {
          schema_version = 1;
          dependencies = [];
          evaluate = _:
            mkOutput {
              domain = "a";
              nextContext.secret = true;
            };
        };
        b = {
          schema_version = 1;
          dependencies = [];
          evaluate = state:
            assert state.context.secret or (throw "undeclared dependency context is unavailable");
              mkOutput {domain = "b";};
        };
      };
    }).domains
    true);
  contextOverwrite = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      initialContext.shared = true;
      fragments.child = {};
      adapters.child = {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            domain = "child";
            nextContext.shared = false;
          };
      };
    }).domains
    true);
  nullFragment = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [1];
    fragments.nullable = null;
    adapters.nullable = {
      schema_version = 1;
      dependencies = [];
      evaluate = state:
        assert state.fragment == null;
          mkOutput {domain = "nullable";};
    };
  };
  extensionDomain = {
    empty = {};
    validate = _: _: _: fragment: fragment;
    merge = _: fragments: builtins.foldl' (left: right: left // right) {} fragments;
  };
  extensionRepository = import ../repository-config.nix {
    shared = {};
    families.fixture = {
      stacks.fixture = {
        stackName = "fixture";
        serviceRegistry = {
          roles = {};
          services = {
            mail = {};
            zulip = {};
          };
        };
      };
      projectionScopes = {};
      projections = {
        identities = {};
        auditing = {};
      };
    };
    projectionDomainExtensions = {
      identities = {
        specification = extensionDomain;
        adapter = {
          schema_version = 1;
          dependencies = ["serviceMoves"];
          evaluate = state:
            assert builtins.attrNames state.domains == ["serviceMoves"];
              mkOutput {domain = "identities";};
        };
      };
      auditing = {
        specification = extensionDomain;
        adapter = {
          schema_version = 1;
          dependencies = ["identities"];
          evaluate = state:
            assert builtins.attrNames state.domains == ["identities"];
              mkOutput {domain = "auditing";};
        };
      };
    };
  };
  extensionFold = import ../projection-domains.nix {
    inherit (pkgs) lib;
    stacks = extensionRepository.scopeStacks;
    scopeOwners = extensionRepository.scopeOwners;
    scopeDefinitions = extensionRepository.scopeDefinitions;
    inventory.hosts = {};
    repositoryProjections = extensionRepository.projections;
    extraAdapters = extensionRepository.projectionAdapters;
    extraRuntimeAdapters.test-runtime.schema_versions = [1];
  };
  resolvedRepositoryMutations = extensionFold.serviceMoveMutationsFor {
    schema_version = 1;
    scope = "fixture";
    owner = "fixture";
    transaction = "move-demo";
    services = ["zulip" "mail"];
  };
  invalidRepositoryMutationOwner = builtins.tryEval (builtins.deepSeq
    (extensionFold.serviceMoveMutationsFor {
      schema_version = 1;
      scope = "fixture";
      owner = "other";
      transaction = "move-demo";
      services = ["zulip"];
    })
    true);
  invalidRepositoryMutationService = builtins.tryEval (builtins.deepSeq
    (extensionFold.serviceMoveMutationsFor {
      schema_version = 1;
      scope = "fixture";
      owner = "fixture";
      transaction = "move-demo";
      services = ["unknown"];
    })
    true);
  unknownRuntimeAdapter = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      fragments.unknown = {};
      adapters.unknown = {
        schema_version = 1;
        dependencies = [];
        evaluate = _: mkOutput {domain = "unknown";};
      };
    }).domains
    true);
  futureRuntimePlan = import ../projection-domain-fold.nix {
    inherit (pkgs) lib;
    runtimeAdapters.test-runtime.schema_versions = [2];
    fragments.future = {};
    adapters.future = {
      schema_version = 1;
      dependencies = [];
      evaluate = _:
        mkOutput {
          domain = "future";
          runtimeSchema = 2;
        };
    };
  };
  unsupportedFutureRuntimePlan = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments.future = {};
      adapters.future = {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            domain = "future";
            runtimeSchema = 2;
          };
      };
    }).domains
    true);
  missingAdmissionDocument = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      runtimeAdapters.test-runtime.schema_versions = [1];
      fragments.admitted = {};
      adapters.admitted = {
        schema_version = 1;
        dependencies = [];
        evaluate = _:
          mkOutput {
            domain = "admitted";
            admission = {
              enabled = true;
              schema_version = 1;
              adapter = "test-admission";
              authority_paths = ["authority.json"];
            };
          };
      };
    }).domains
    true);
  missingOutputContract = builtins.tryEval (builtins.deepSeq
    (import ../projection-domain-fold.nix {
      inherit (pkgs) lib;
      fragments.incomplete = {};
      adapters.incomplete = {
        schema_version = 1;
        dependencies = [];
        evaluate = _: {schema_version = 1;};
      };
    }).domains
    true);
  orphanFragment = builtins.tryEval (builtins.deepSeq
    (import ../projection-domains.nix {
      inherit (pkgs) lib;
      stacks = {};
      scopeOwners = {};
      scopeDefinitions = {};
      inventory.hosts = {};
      repositoryProjections = {
        servicePlacements = {
          schema_version = 3;
          placements = {};
        };
        serviceMoves = {};
        orphan = {};
      };
    }).contracts
    true);
in
  assert builtins.attrNames folded.domains == ["identities" "placements"];
  assert folded.domainOrder == ["placements" "identities"];
  assert folded.domains.identities.contract.domain == "identities";
  assert folded.domains.identities.runtime.plans
  == [
    {
      schema_version = 1;
      adapter = "test-runtime";
      payload.domain = "identities";
    }
  ];
  assert folded.domains.identities.admission == {enabled = false;};
  assert minimalFold.domains.minimal.generation == {};
  assert minimalFold.domains.minimal.runtime == {plans = [];};
  assert minimalFold.domains.minimal.repository
  == {
    document_kind = "minimal";
    owned_paths = [];
  };
  assert folded.repository.owners
  == [
    {
      domain = "identities";
      kind = "identities";
      path = "config/test/identities.nix";
    }
    {
      domain = "placements";
      kind = "placements";
      path = "config/test/placements.nix";
    }
  ];
  assert !(builtins.tryEval (builtins.deepSeq conflicting true)).success;
  assert !(builtins.tryEval (builtins.deepSeq unsafeRepository true)).success;
  assert !(builtins.tryEval (builtins.deepSeq gitMetadataRepository true)).success;
  assert !(builtins.tryEval (builtins.deepSeq controlCharacterRepository true)).success;
  assert !(builtins.tryEval (builtins.deepSeq overlappingRepository true)).success;
  assert !cyclic.success;
  assert !missingDependency.success;
  assert !duplicateDependency.success;
  assert !undeclaredDependency.success;
  assert !contextOverwrite.success;
  assert !unknownRuntimeAdapter.success;
  assert (builtins.head futureRuntimePlan.domains.future.runtime.plans).schema_version == 2;
  assert !unsupportedFutureRuntimePlan.success;
  assert !missingAdmissionDocument.success;
  assert !missingOutputContract.success;
  assert nullFragment.domains.nullable.contract.domain == "nullable";
  assert builtins.attrNames extensionFold.contracts == ["auditing" "identities" "serviceMoves" "servicePlacements"];
  assert extensionFold.contracts.identities.domain == "identities";
  assert map (plan: plan.payload.domain) extensionFold.runtime.plans == ["identities" "auditing"];
  assert resolvedRepositoryMutations
  == {
    schema_version = 1;
    mutations = [
      {
        domain = "serviceMoves";
        kind = "service-move";
        path = "config/fixture/moves/move-demo.nix";
        transaction = "move-demo";
      }
      {
        domain = "servicePlacements";
        kind = "service-placement";
        path = "config/fixture/placements/fixture/mail.nix";
        service = "mail";
      }
      {
        domain = "servicePlacements";
        kind = "service-placement";
        path = "config/fixture/placements/fixture/zulip.nix";
        service = "zulip";
      }
    ];
  };
  assert !invalidRepositoryMutationOwner.success;
  assert !invalidRepositoryMutationService.success;
  assert !(extensionFold ? context);
  assert !(extensionFold ? domains);
  assert !(extensionFold ? runtimeHosts);
  assert extensionFold.runtime ? runtimeHosts;
  assert !orphanFragment.success;
    pkgs.runCommand "projection-domain-fold-test" {} ''
      touch "$out"
    ''
