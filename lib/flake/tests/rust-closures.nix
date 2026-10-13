# nix eval --offline --option allow-import-from-derivation false --json --file lib/flake/tests/rust-closures.nix
let
  api = import ../rust-closures.nix;
  pkg = name: {package.name = name;};
  ws = dirs: {workspace.members = dirs;};
  evaluate = workspace: members: api.planFromManifests {inherit workspace members;};
  hasReason = code: result:
    !result.supported && result.plan == null && builtins.any (r: r.code == code) result.reasons;
  basicRoot = ws ["a" "b" "c" "d"];
  basicMembers = {
    a = (pkg "a") // {dependencies.b.path = "../b";};
    b = (pkg "b") // {"build-dependencies".c.path = "../c";};
    c = pkg "c";
    d = pkg "d";
  };
  basic = evaluate basicRoot basicMembers;
  withA = attrs: evaluate basicRoot (basicMembers // {a = (pkg "a") // attrs;});
  inherited = evaluate ((ws ["nested/a" "b"])
    // {
      workspace = {
        members = ["nested/a" "b"];
        dependencies.renamed = {
          path = "b";
          package = "actual";
        };
      };
    }) {
    "nested/a" =
      (pkg "a")
      // {
        dependencies.renamed = {
          workspace = true;
          optional = true;
        };
      };
    b = pkg "actual";
  };
  inheritedWith = memberFlags: rootFlags:
    evaluate {
      workspace = {
        members = ["a" "b"];
        dependencies.b = {path = "b";} // rootFlags;
      };
    } {
      a = (pkg "a") // {dependencies.b = {workspace = true;} // memberFlags;};
      b = pkg "b";
    };
  nestedMembers = {
    a = pkg "a";
    "a/b" = pkg "b";
  };
  rootFsInputs = api.readWorkspace {src = ./fixtures/rust-closures/root-package;};
  rootFsPlan = api.plan {src = ./fixtures/rust-closures/root-package;};
  conservative = withA {
    dependencies.b = {
      path = "../b";
      optional = true;
      "default-features" = false;
    };
    "build-dependencies".c.path = "../c";
    "dev-dependencies".d.path = "../d";
    target."cfg(any())".dependencies.c.path = "../c";
    target."not-the-host"."dev-dependencies".b.path = "../b";
  };
  cycle = evaluate (ws ["b" "a" "c"]) {
    a = (pkg "a") // {dependencies.b.path = "../b";};
    b = (pkg "b") // {dependencies.a.path = "../a";};
    c = (pkg "c") // {dependencies.a.path = "../a";};
  };
  tie = evaluate (ws ["c" "b" "a"]) {
    a = pkg "a";
    b = pkg "b";
    c =
      (pkg "c")
      // {
        dependencies = {
          a.path = "../a";
          b.path = "../b";
        };
      };
  };
  reordered = evaluate (ws ["d" "c" "b" "a" "a"]) basicMembers;
  fixture = api.plan {src = ./fixtures/rust-closures/regular;};
  assertions = {
    supported = basic.supported;
    lockPolicyRejectedBeforePayload = hasReason "unsupported-cargo-lock-policy" (api.plan {
      src = ./fixtures/rust-closures/lock-policy;
    });
    scopedLockPolicyRejected = hasReason "unsupported-cargo-lock-policy" (api.plan {
      src = ./fixtures/rust-closures/lock-policy;
      memberDirs = ["a"];
    });
    memberOrder = basic.plan.members == ["a" "b" "c" "d"];
    directEdges = basic.plan.pathDeps.a == ["b"];
    transitiveClosure = basic.plan.closureDirs.a == ["a" "b" "c"];
    singleton = basic.plan.closureDirs.d == ["d"];
    components = basic.plan.components == [["a" "b" "c"] ["d"]];
    nearestParents = basic.plan.parentCandidates.a == ["b" "c"];
    rootHasNoParent = basic.plan.parentCandidates.c == [];
    deterministic = reordered == basic;
    inheritedRootRelative = inherited.supported && inherited.plan.pathDeps."nested/a" == ["b"];
    inheritedBadOptional = hasReason "invalid-dependency-flag" (inheritedWith {optional = "yes";} {});
    inheritedBadDefaults = hasReason "invalid-dependency-flag" (inheritedWith {"default-features" = [];} {});
    inheritedGoodFlags =
      (inheritedWith {
        optional = true;
        "default-features" = false;
      } {"default-features" = true;}).plan.pathDeps.a
      == ["b"];
    inheritedRootBadOptional = hasReason "invalid-dependency-flag" (inheritedWith {} {optional = "yes";});
    inheritedRootBadDefaults = hasReason "invalid-dependency-flag" (inheritedWith {} {"default-features" = [];});
    inheritedMetadataUnchanged = (inheritedWith {optional = true;} {}).metadata == inherited.metadata;
    conservativeUnion = conservative.supported && conservative.plan.pathDeps.a == ["b" "c" "d"];
    optionalIncluded =
      (withA {
        dependencies.b = {
          path = "../b";
          optional = true;
        };
      }).plan.pathDeps.a
      == ["b"];
    cfgIncluded = (withA {target."cfg(impossible)".dependencies.b.path = "../b";}).plan.pathDeps.a == ["b"];
    targetBuildIncluded = (withA {target."other-target"."build-dependencies".b.path = "../b";}).plan.pathDeps.a == ["b"];
    devIncluded = (withA {"dev-dependencies".d.path = "../d";}).plan.pathDeps.a == ["d"];
    underscoreBuildRejected = hasReason "underscore-dependency-table-unsupported" (withA {
      package = {
        name = "a";
        edition = "2021";
      };
      build_dependencies.b.path = "../b";
    });
    underscoreDevRejected = hasReason "underscore-dependency-table-unsupported" (withA {dev_dependencies.b.path = "../b";});
    underscoreTargetBuildRejected = hasReason "underscore-dependency-table-unsupported" (withA {target."cfg(any())".build_dependencies.b.path = "../b";});
    underscoreTargetDevRejected = hasReason "underscore-dependency-table-unsupported" (withA {target."other-target".dev_dependencies.b.path = "../b";});
    underscoreMixedTablesRejected = hasReason "underscore-dependency-table-unsupported" (withA {
      "build-dependencies".c.path = "../c";
      build_dependencies.b.path = "../b";
    });
    underscoreEmptyTableRejected = hasReason "underscore-dependency-table-unsupported" (withA {dev_dependencies = {};});
    underscoreMalformedTableRejected = hasReason "underscore-dependency-table-unsupported" (withA {build_dependencies = false;});
    underscoreRootRejectedBeforeMembers = hasReason "underscore-dependency-table-unsupported" (evaluate
      (basicRoot // {build_dependencies.b.path = "b";})
      (throw "unsupported root alias must reject before member values"));
    underscoreWorkspaceRejectedBeforeMembers = hasReason "underscore-dependency-table-unsupported" (evaluate
      {workspace = basicRoot.workspace // {dev_dependencies.b.path = "b";};}
      (throw "unsupported workspace alias must reject before member values"));
    underscoreTargetReasonLocation = let
      result = withA {target."cfg(any())".build_dependencies.b.path = "../b";};
    in
      builtins.any (r: r.code == "underscore-dependency-table-unsupported" && r.location == "a.target.cfg(any()).build_dependencies") result.reasons;
    cycleTerminates = cycle.supported && cycle.plan.closureDirs.a == ["a" "b"];
    equalCycleNotParent = cycle.plan.parentCandidates.a == [] && cycle.plan.parentCandidates.b == [];
    cycleParents = cycle.plan.parentCandidates.c == ["a" "b"];
    cycleComponent = cycle.plan.components == [["a" "b" "c"]];
    tieBreakDir = tie.plan.parentCandidates.c == ["a" "b"];
    renameValidated =
      (withA {
        dependencies.alias = {
          path = "../b";
          package = "b";
        };
      }).supported;
    aliasNotPackage = hasReason "path-package-name-mismatch" (withA {dependencies.alias.path = "../b";});
    wrongRename = hasReason "path-package-name-mismatch" (withA {
      dependencies.b = {
        path = "../b";
        package = "not-b";
      };
    });
    missingInheritance = hasReason "missing-workspace-dependency" (withA {dependencies.b.workspace = true;});
    inheritedOverride = hasReason "workspace-dependency-override" (evaluate
      {
        workspace = {
          members = ["a" "b"];
          dependencies.b.path = "b";
        };
      }
      {
        a =
          (pkg "a")
          // {
            dependencies.b = {
              workspace = true;
              path = "../b";
            };
          };
        b = pkg "b";
      });
    inheritedRegistry =
      (evaluate {
          workspace = {
            members = ["a"];
            dependencies.external = "1";
          };
        }
        {a = (pkg "a") // {dependencies.external.workspace = true;};}).supported;
    registryAndGitNotEdges =
      (withA {
        dependencies = {
          serde = "1";
          checkout.git = "https://example.invalid/git";
        };
      }).plan.pathDeps.a
      == [];
    publicationRegistry =
      (withA {
        dependencies.b = {
          path = "../b";
          version = "1";
          registry = "custom";
        };
      }).plan.pathDeps.a
      == ["b"];
    publicationRegistryIndex =
      (withA {
        dependencies.b = {
          path = "../b";
          version = "1";
          "registry-index" = "https://example.invalid/index";
        };
      }).supported;
    inheritedPublicationRegistry =
      (inheritedWith {} {
        version = "1";
        registry = "custom";
      }).plan.pathDeps.a
      == ["b"];
    malformedRegistry = hasReason "invalid-dependency-source" (withA {
      dependencies.b = {
        path = "../b";
        registry = 42;
      };
    });
    malformedVersion = hasReason "invalid-dependency-source" (withA {
      dependencies.b = {
        path = "../b";
        version = [];
      };
    });
    publicationGitConflict = hasReason "conflicting-path-source" (withA {
      dependencies.b = {
        path = "../b";
        version = "1";
        registry = "custom";
        git = "url";
      };
    });
    escaping = hasReason "path-outside-workspace" (withA {dependencies.b.path = "../../b";});
    leaveThenReturn = hasReason "path-outside-workspace" (withA {dependencies.b.path = "../../workspace/b";});
    interiorDotDot = (withA {dependencies.b.path = "../c/../b";}).plan.pathDeps.a == ["b"];
    absolute = hasReason "path-outside-workspace" (withA {dependencies.b.path = "/b";});
    windowsAbsolute = hasReason "path-outside-workspace" (withA {dependencies.b.path = "C:/b";});
    backslash = hasReason "path-outside-workspace" (withA {dependencies.b.path = "..\\b";});
    unknownMember = hasReason "nonmember-path-dependency" (withA {dependencies.external.path = "../external";});
    unusedRootPath = hasReason "nonmember-path-dependency" (evaluate
      (basicRoot
        // {
          workspace = {
            members = basicRoot.workspace.members;
            dependencies.external.path = "external";
          };
        })
      basicMembers);
    patch = hasReason "patch-unsupported" (evaluate (basicRoot // {patch."crates-io".x.path = "x";}) basicMembers);
    memberPatch = hasReason "patch-unsupported" (withA {patch = {};});
    replace = hasReason "replace-unsupported" (evaluate (basicRoot // {replace = {};}) basicMembers);
    globStar = hasReason "member-glob" (evaluate (ws ["crates/*"]) {});
    globQuestion = hasReason "member-glob" (evaluate (ws ["crates/?"]) {});
    globBracket = hasReason "member-glob" (evaluate (ws ["crates/[ab]"]) {});
    excludes = hasReason "workspace-excludes" (evaluate {
      workspace = {
        members = [];
        exclude = ["x"];
      };
    } {});
    nestedMembersRejected = hasReason "overlapping-member-directories" (evaluate (ws ["a" "a/b"]) nestedMembers);
    nestedMemberDependencyRejected =
      hasReason "overlapping-member-directories" (evaluate (ws ["a" "a/b"])
        (nestedMembers // {a = (pkg "a") // {dependencies.b.path = "b";};}));
    nestedMemberOrder = evaluate (ws ["a/b" "a"]) nestedMembers == evaluate (ws ["a" "a/b"]) nestedMembers;
    rootTopologyDoesNotForceMembers = hasReason "overlapping-member-directories" (evaluate
      (ws ["a" "a/b"])
      (throw "invalid root topology must reject before member values"));
    rootTopologyDoesNotForceSelectedManifest = hasReason "root-package-filter-unsupported" (evaluate
      ((ws ["a"]) // pkg "root")
      {a = throw "invalid root package must reject before selected manifest";});
    rootTopologyGlobDoesNotForceMembers = hasReason "member-glob" (evaluate
      (ws ["a" "foreign/*"])
      (throw "invalid root member declarations must reject before member values"));
    filesystemRootOverlapDoesNotReadMembers =
      hasReason "overlapping-member-directories"
      (api.plan {src = ./fixtures/rust-source-scope/root-overlap;});
    similarPrefixNotOverlap =
      (evaluate (ws ["a" "a-b"]) {
        a = pkg "a";
        "a-b" = pkg "b";
      }).supported;
    siblingMembersNotOverlap =
      (evaluate (ws ["a/b" "a/c"]) {
        "a/b" = pkg "b";
        "a/c" = pkg "c";
      }).supported;
    noExplicitMembers = hasReason "explicit-members-required" (evaluate {workspace = {};} {});
    memberEscape = hasReason "member-outside-workspace" (evaluate (ws ["../a"]) {});
    memberNormalization = hasReason "member-not-normalized" (evaluate (ws ["./a"]) {a = pkg "a";});
    missingManifest = hasReason "missing-member-manifest" (evaluate basicRoot (builtins.removeAttrs basicMembers ["b"]));
    undeclaredManifest = hasReason "undeclared-member-manifest" (evaluate (ws []) {a = pkg "a";});
    malformedKey = hasReason "member-key-not-normalized" (evaluate (ws []) {"a/../b" = pkg "b";});
    badInput = hasReason "invalid-input" (evaluate [] []);
    badMemberList = hasReason "explicit-members-required" (evaluate (ws 42) {});
    badMember = hasReason "invalid-member" (evaluate (ws [42]) {});
    badManifest = hasReason "invalid-manifest" (evaluate (ws ["a"]) {a = false;});
    badPackage = hasReason "invalid-member-package" (evaluate (ws ["a"]) {a.package = false;});
    badDependency = hasReason "invalid-dependency" (withA {dependencies.b = false;});
    badOptional = hasReason "invalid-dependency-flag" (withA {
      dependencies.b = {
        path = "../b";
        optional = "yes";
      };
    });
    badDefaults = hasReason "invalid-dependency-flag" (withA {
      dependencies.b = {
        path = "../b";
        "default-features" = [];
      };
    });
    badDependencyTable = hasReason "invalid-dependency-table" (withA {dependencies = [];});
    badTarget = hasReason "invalid-target-table" (withA {target = [];});
    badTargetEntry = hasReason "invalid-target-table" (withA {target.other = false;});
    badPath = hasReason "invalid-path" (withA {dependencies.b.path = 42;});
    badRename = hasReason "invalid-package-name" (withA {
      dependencies.b = {
        path = "../b";
        package = [];
      };
    });
    badWorkspaceFlag = hasReason "invalid-workspace-inheritance" (withA {dependencies.b.workspace = "yes";});
    conflictingSource = hasReason "conflicting-path-source" (withA {
      dependencies.b = {
        path = "../b";
        git = "url";
      };
    });
    nestedWorkspace = hasReason "nested-workspace" (withA {workspace = {};});
    packageWorkspace = hasReason "package-workspace-override" (evaluate (ws ["a"]) {
      a.package = {
        name = "a";
        workspace = "..";
      };
    });
    rootPackage = hasReason "root-package-filter-unsupported" (evaluate (basicRoot // pkg "root") basicMembers);
    implicitRootPackage = hasReason "root-package-filter-unsupported" (evaluate ((ws []) // pkg "root") {});
    explicitDot = hasReason "root-package-filter-unsupported" (evaluate (ws ["."]) {"." = pkg "root";});
    rootMetadata = (evaluate (basicRoot // pkg "root") basicMembers).metadata.rootPackage;
    virtualRootDependencies = hasReason "root-package-dependencies-unsupported" (evaluate (basicRoot // {dependencies.b.path = "b";}) basicMembers);
    externalBuildScript = hasReason "additional-manifest-input" (evaluate (ws ["a"]) {
      a.package = {
        name = "a";
        build = "../script.rs";
      };
    });
    externalLib = hasReason "additional-manifest-input" (withA {lib.path = "../b/src/lib.rs";});
    internalLib = (withA {lib.path = "src/../lib.rs";}).supported;
    externalBin = hasReason "additional-manifest-input" (withA {
      bin = [
        {
          name = "a";
          path = "/external.rs";
        }
      ];
    });
    inheritedReadme = hasReason "additional-workspace-input" (evaluate
      {
        workspace = {
          members = ["a"];
          package.readme = "README.md";
        };
      }
      {
        a.package = {
          name = "a";
          readme.workspace = true;
        };
      });
    defaultMembers = hasReason "workspace-default-members" (evaluate
      {
        workspace = {
          members = ["a"];
          default-members = ["a"];
        };
      } {a = pkg "a";});
    flagsOnly =
      basic.metadata
      == {
        rootPackage = false;
        workspaceDependencies = false;
        patch = false;
        replace = false;
        filesystemChecked = false;
      };
    extraInputs = hasReason "additional-local-inputs" (api.planFromManifests {
      workspace = basicRoot;
      members = basicMembers;
      additionalInputs = [".cargo/config.toml"];
    });
    rootFilesystemRejected = hasReason "root-package-filter-unsupported" rootFsPlan;
    rootFilesystemMetadata = rootFsPlan.metadata.rootPackage && rootFsPlan.metadata.filesystemChecked;
    rootNotReadAsMember = rootFsInputs.members == {};
    rootNotScanned = rootFsInputs.additionalInputs == [] && !builtins.any (r: r.code == "local-cargo-config") rootFsPlan.reasons;
    lockSymlinkRejected = hasReason "symlink-source-path" (api.plan {src = ./fixtures/rust-closures/lock-symlink;});
    lockSymlinkLocation =
      builtins.any (r: r.code == "symlink-source-path" && r.location == "Cargo.lock")
      (api.readWorkspace {src = ./fixtures/rust-closures/lock-symlink;}).additionalInputs;
    nonregularLockRejected = hasReason "nonregular-cargo-lock" (api.plan {src = ./fixtures/rust-closures/lock-directory;});
    regularLockAccepted = (api.plan {src = ./fixtures/rust-closures/lock-regular;}).supported;
    helperDiagnostics = (import ../pkg-helper.nix).rustPlan {src = ./fixtures/rust-closures/regular;} == fixture;
    fixtureParsed = fixture.supported && fixture.plan.closureDirs."nested/a" == ["b" "nested/a"];
    fixtureChecked = fixture.metadata.filesystemChecked;
    readAdapter = (api.readWorkspace {src = ./fixtures/rust-closures/regular;}).members.b.package.name == "actual-b";
    missingInteriorPath = hasReason "missing-dependency-path" (api.plan {src = ./fixtures/rust-closures/missing-path;});
    sourceRootSymlink = hasReason "symlink-source-path" (api.plan {src = ./fixtures/rust-closures/source-link;});
    rootManifestSymlink = hasReason "symlink-source-path" (api.plan {src = ./fixtures/rust-closures/root-symlink;});
    configRejected = hasReason "local-cargo-config" (api.plan {src = ./fixtures/rust-closures/config;});
    memberConfigRejected = hasReason "local-cargo-config" (api.plan {src = ./fixtures/rust-closures/member-config;});
    symlinkRejected = hasReason "symlink-source-path" (api.plan {src = ./fixtures/rust-closures/symlink;});
    cancelledSymlinkRejected = hasReason "symlink-dependency-path" (api.plan {src = ./fixtures/rust-closures/cancelled-symlink;});
  };
  failed = builtins.filter (name: !assertions.${name}) (builtins.attrNames assertions);
in
  assert failed == []; {
    assertionCount = builtins.length (builtins.attrNames assertions);
    passed = true;
  }
