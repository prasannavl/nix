let
  joinWords = parts:
    builtins.concatStringsSep " " (builtins.filter (part: part != "") parts);

  joinLines = lines:
    builtins.concatStringsSep "\n" (builtins.filter (line: line != "") lines);

  exportEnvWith = serialize: env:
    joinLines (builtins.attrValues (builtins.mapAttrs (name: value: "export ${name}=${serialize value}") env));

  # Keep old shell expansion semantics on compatibility paths only. Projected
  # discovery values are literals, including dollar signs and single quotes.
  exportEnv = exportEnvWith builtins.toJSON;
  exportLiteralEnv = exportEnvWith (value: "'${builtins.replaceStrings ["'"] ["'\\''"] value}'");

  repoRoot = builtins.toString ../..;

  stripPrefix = prefix: str: let
    prefixLen = builtins.stringLength prefix;
  in
    if builtins.substring 0 prefixLen str == prefix
    then builtins.substring prefixLen (builtins.stringLength str - prefixLen) str
    else str;

  deriveProjectPath = src:
    stripPrefix "${repoRoot}/" (builtins.toString src);

  deriveProjectName = src:
    builtins.baseNameOf (builtins.toString src);

  isDerivation = value:
    builtins.isAttrs value
    && (value.type or null) == "derivation";

  shellWords = parts:
    builtins.concatStringsSep " " (map builtins.toJSON parts);

  binPath = inputs:
    builtins.concatStringsSep ":" (map (input: "${input}/bin") inputs);

  attrIf = condition: name: value:
    if condition
    then
      builtins.listToAttrs [
        {
          name = name;
          value = value;
        }
      ]
    else {};

  hasPrefix = prefix: str: let
    prefixLen = builtins.stringLength prefix;
  in
    builtins.substring 0 prefixLen str == prefix;

  shellArrayRef = varName:
    builtins.concatStringsSep "" [
      "\"\${"
      varName
      "[@]}\""
    ];

  commonAutoExcludes = [
    "./.git"
    "./.direnv"
    "./result"
    "./node_modules"
    "./dist"
    "./build"
    "./coverage"
    "./.next"
    "./target"
    "./.venv"
    "./venv"
  ];

  buildFindSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }: let
    pruneExpr =
      if excludes == []
      then ""
      else
        "\\( "
        + builtins.concatStringsSep " -o " (map (path: "-path ${builtins.toJSON path}") excludes)
        + " \\) -prune -o ";
    nameExpr =
      builtins.concatStringsSep " -o " (map (ext: "-name ${builtins.toJSON ext}") extensions);
  in ''
    mapfile -d $'\0' -t ${varName} < <(
      find ${shellWords roots} ${pruneExpr}-type f \( ${nameExpr} \) -print0
    )
  '';

  buildAutoFilesSnippet = {
    varName,
    roots ? ["."],
    extensions,
    excludes ? [],
  }: let
    extCase =
      builtins.concatStringsSep "\n"
      (map (ext:
        builtins.replaceStrings ["*"] [""] ''
          ${ext})
            auto_files+=("$path")
            ;;
        '')
      extensions);
    excludeCase =
      if excludes == []
      then ""
      else
        builtins.concatStringsSep "\n"
        (map (path: "${path}|${path}/*) continue ;;") excludes);
    findSnippet = buildFindSnippet {
      inherit varName roots extensions excludes;
    };
  in ''
    auto_files=()
    if git rev-parse --show-toplevel >/dev/null 2>&1; then
      while IFS= read -r -d $'\0' path; do
        case "$path" in
          ${excludeCase}
        esac
        case "$path" in
          ${extCase}
        esac
      done < <(git ls-files -z --cached --others --exclude-standard -- ${shellWords roots})
      ${varName}=("''${auto_files[@]}")
    else
      ${findSnippet}
    fi
  '';

  mkCheckFn = build: args:
    build.overrideAttrs (old: let
      extraNativeBuildInputs = args.nativeBuildInputs or [];
    in {
      pname = "${old.pname}-${args.name}";
      nativeBuildInputs =
        (builtins.filter
          (input: !(builtins.elem input (args.removeNativeBuildInputs or [])))
          (old.nativeBuildInputs or []))
        ++ extraNativeBuildInputs;
      nativeCheckInputs =
        if builtins.hasAttr "nativeCheckInputs" args
        then args.nativeCheckInputs
        else if builtins.hasAttr "removeNativeBuildInputs" args
        then []
        else old.nativeCheckInputs or [];
      buildPhase = joinLines [
        (
          if extraNativeBuildInputs == []
          then ""
          else "export PATH=${builtins.toJSON (binPath extraNativeBuildInputs)}:$PATH"
        )
        (args.preBuildPhase or "")
        (
          if old ? buildAndTestSubdir && old.buildAndTestSubdir != null
          then "cd ${builtins.toJSON old.buildAndTestSubdir}"
          else ""
        )
        args.buildPhase
      ];
      installPhase = "touch $out";
      doCheck = false;
      dontInstall = false;
    });

  common = rec {
    emptyParts = {
      inputs = [];
      env = {};
      repoFmtPaths = [];
      commands = [];
      writableCopy = false;
    };

    mergeParts = parts:
      builtins.foldl'
      (acc: part: {
        inputs = acc.inputs ++ (part.inputs or []);
        env = acc.env // (part.env or {});
        repoFmtPaths =
          acc.repoFmtPaths
          ++ (part.repoFmtPaths or []);
        commands = acc.commands ++ (part.commands or []);
        writableCopy = acc.writableCopy || (part.writableCopy or false);
      })
      emptyParts
      parts;

    mkCheck = mkCheckFn;

    mkChecks = build: checks:
      builtins.mapAttrs (name: args:
        if name == "build"
        then build
        else mkCheckFn build ({name = name;} // args))
      checks;

    alejandraFmt = {paths}: "alejandra ${joinWords paths}";
    alejandraCheck = {paths}: "alejandra --check ${joinWords paths}";

    denoFmt = {paths}: "deno fmt ${joinWords paths}";
    denoFmtCheck = {paths}: "deno fmt --check ${joinWords paths}";

    repoFmtRuntimeInputs = pkgs: [
      pkgs.treefmt
      pkgs.alejandra
      pkgs.deno
      pkgs.opentofu
      pkgs.shfmt
    ];

    repoFmtAppCommand = {paths}: "treefmt --quiet --on-unmatched=debug --config-file \"$repo_root/treefmt.toml\" --tree-root \"$repo_root\" ${joinWords paths}";

    repoFmtCheckCommand = {paths}: "treefmt --quiet --on-unmatched=debug --fail-on-change --config-file ${../../treefmt.toml} --tree-root . ${joinWords paths}";

    repoFmtCheckEnv = env:
      {
        HOME = "$TMPDIR/home";
        XDG_CACHE_HOME = "$TMPDIR/.cache";
      }
      // env;

    projectFmtGlobal = {paths ? ["."]}: {
      repoFmtPaths = paths;
      writableCopy = true;
    };

    mkAutoFilesPart = {
      inputs,
      varName,
      extensions,
      commandBuilder,
      roots ? ["."],
      excludes ? commonAutoExcludes,
      writableCopy ? false,
    }: let
      part = {
        inherit inputs;
        commands = [
          (buildAutoFilesSnippet {
            inherit varName roots excludes extensions;
          })
          ''
            if [ "''${#${varName}[@]}" -gt 0 ]; then
              ${commandBuilder (shellArrayRef varName)}
            fi
          ''
        ];
      };
    in
      if writableCopy
      then part // {writableCopy = true;}
      else part;

    mkStdApp = pkgs: {
      kind,
      src,
      pname ? deriveProjectName src,
      projectPath ? deriveProjectPath src,
      description ?
        if kind == "fmt"
        then "Format ${pname}"
        else if kind == "lint-fix"
        then "Apply lint fixes for ${pname}"
        else if kind == "dev"
        then "Run the ${pname} development workflow"
        else "${pname} ${kind}",
      parts ? [],
      runtimeInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
    }:
      mkProjectCommandsApp pkgs {
        name = "${pname}-${kind}";
        description = description;
        src = src;
        projectPath = projectPath;
        parts = parts;
        runtimeInputs = runtimeInputs;
        env = env;
        repoFmtPaths = repoFmtPaths;
        commands = commands;
      };

    mkStdCheck = pkgs: {
      kind,
      src,
      pname ? deriveProjectName src,
      parts ? [],
      nativeBuildInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
    }:
      mkProjectCommandsCheck pkgs {
        name = "${pname}-${kind}";
        src = src;
        parts = parts;
        nativeBuildInputs = nativeBuildInputs;
        env = env;
        repoFmtPaths = repoFmtPaths;
        commands = commands;
      };

    resolveProjectOp = pkgs: {
      parts ? [],
      extraInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
      forCheck ? false,
    }: let
      mergedParts = mergeParts (
        parts
        ++ [
          {
            inputs = extraInputs;
            inherit env repoFmtPaths commands;
          }
        ]
      );
      needsRepoFmt = mergedParts.repoFmtPaths != [];
      effectiveEnv =
        if forCheck && needsRepoFmt
        then repoFmtCheckEnv mergedParts.env
        else mergedParts.env;
      commandPrefix =
        if !needsRepoFmt
        then []
        else if forCheck
        then [
          ''mkdir -p "$HOME" "$XDG_CACHE_HOME"''
          (repoFmtCheckCommand {
            paths = mergedParts.repoFmtPaths;
          })
        ]
        else [
          (repoFmtAppCommand {
            paths = mergedParts.repoFmtPaths;
          })
        ];
    in {
      runtimeInputs =
        mergedParts.inputs
        ++ (
          if needsRepoFmt
          then repoFmtRuntimeInputs pkgs
          else []
        );
      envScript = exportEnv effectiveEnv;
      command = joinLines (commandPrefix ++ mergedParts.commands);
      writableCopy = mergedParts.writableCopy;
    };

    mkProjectAppOp = pkgs: {
      src ? null,
      projectPath ?
        if src != null
        then deriveProjectPath src
        else throw "mkProjectAppOp requires projectPath or src",
      parts ? [],
      runtimeInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
    }: let
      resolved = resolveProjectOp pkgs {
        inherit parts env repoFmtPaths commands;
        extraInputs = runtimeInputs;
      };
    in {
      path = projectPath;
      inherit (resolved) runtimeInputs envScript command;
    };

    mkProjectCheckOp = pkgs: {
      src,
      projectPath ? deriveProjectPath src,
      parts ? [],
      nativeBuildInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
    }: let
      resolved = resolveProjectOp pkgs {
        inherit parts env repoFmtPaths commands;
        extraInputs = nativeBuildInputs;
        forCheck = true;
      };
    in {
      path = projectPath;
      inherit (resolved) runtimeInputs envScript command;
    };

    mkStdAppOp = pkgs: {
      src,
      projectPath ? deriveProjectPath src,
      parts ? [],
      runtimeInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
      ...
    }:
      mkProjectAppOp pkgs {
        inherit src projectPath parts runtimeInputs env repoFmtPaths commands;
      };

    mkStdCheckOp = pkgs: {
      src,
      projectPath ? deriveProjectPath src,
      parts ? [],
      nativeBuildInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands ? [],
      ...
    }:
      mkProjectCheckOp pkgs {
        inherit src projectPath parts nativeBuildInputs env repoFmtPaths commands;
      };

    stripPkgOp = spec:
      if spec == null
      then null
      else builtins.removeAttrs spec ["runtimeInputs"];

    isSupportedOnCurrentSystem = pkgs: input: let
      resolved = builtins.tryEval input;
    in
      if !resolved.success
      then false
      else if !builtins.isAttrs resolved.value
      then true
      else if !(builtins.hasAttr "meta" resolved.value && builtins.hasAttr "platforms" resolved.value.meta)
      then true
      else pkgs.lib.meta.availableOn pkgs.stdenv.hostPlatform resolved.value;

    collectPkgOpInputs = pkgOps: let
      appInputs = builtins.concatLists (
        map (
          name: let
            spec = (pkgOps.apps or {}).${name};
          in
            if spec == null
            then []
            else spec.runtimeInputs
        ) (builtins.attrNames (pkgOps.apps or {}))
      );
      checkInputs = builtins.concatLists (
        map (
          name: let
            spec = (pkgOps.checks or {}).${name};
          in
            if spec == null
            then []
            else spec.runtimeInputs
        ) (builtins.attrNames (pkgOps.checks or {}))
      );
    in
      builtins.filter (item: item != null) (
        appInputs ++ checkInputs
      );

    pkgOpsManifest = pkgs: packageSet: {
      packages = builtins.filter (entry: entry != null) (
        map (
          name: let
            packageEval = builtins.tryEval (packageSet.${name} or null);
            drv = packageEval.value;
            pkgOpsEval = builtins.tryEval (
              if
                packageEval.success
                && isSupportedOnCurrentSystem pkgs drv
                && builtins.isAttrs drv
                && builtins.hasAttr "passthru" drv
              then (drv.passthru.pkgOps or null)
              else null
            );
            pkgOps = pkgOpsEval.value;
          in
            if
              !packageEval.success
              || !pkgOpsEval.success
              || pkgOps == null
            then null
            else {
              inherit name;
              path = pkgOps.path;
              apps = builtins.mapAttrs (_: stripPkgOp) (pkgOps.apps or {});
              checks = builtins.mapAttrs (_: stripPkgOp) (pkgOps.checks or {});
            }
        ) (builtins.attrNames packageSet)
      );
    };

    pkgOpsRuntimeInputs = pkgs: packageSet:
      builtins.concatLists (
        map (
          name: let
            packageEval = builtins.tryEval (packageSet.${name} or null);
            drv = packageEval.value;
            pkgOpsEval = builtins.tryEval (
              if
                packageEval.success
                && isSupportedOnCurrentSystem pkgs drv
                && builtins.isAttrs drv
                && builtins.hasAttr "passthru" drv
              then (drv.passthru.pkgOps or null)
              else null
            );
            pkgOps = pkgOpsEval.value;
          in
            if
              !packageEval.success
              || !pkgOpsEval.success
              || pkgOps == null
            then []
            else collectPkgOpInputs pkgOps
        ) (builtins.attrNames packageSet)
      );

    mkPackageOpsBundle = {
      pkgs,
      src,
      pname ? deriveProjectName src,
      projectPath ? deriveProjectPath src,
      apps ? {},
      checks ? {},
      devShellPackages ? null,
    }: let
      path = projectPath;
      appDrvs = builtins.mapAttrs (kind: spec:
        mkStdApp pkgs ({
            inherit kind src pname projectPath;
          }
          // spec))
      apps;
      checkDrvs = builtins.mapAttrs (kind: spec:
        mkStdCheck pkgs ({
            inherit kind src pname;
          }
          // spec))
      checks;
      pkgAppOps = builtins.mapAttrs (kind: spec:
        mkStdAppOp pkgs ({
            inherit kind src projectPath;
          }
          // spec))
      apps;
      pkgCheckOps = builtins.mapAttrs (kind: spec:
        mkStdCheckOp pkgs ({
            inherit kind src projectPath;
          }
          // spec))
      checks;
    in
      appDrvs
      // {
        checks = checkDrvs;
        pkgOps = {
          inherit path;
          apps = pkgAppOps;
          checks = pkgCheckOps;
        };
      }
      // (
        if devShellPackages == null
        then {}
        else {
          devShell = pkgs.mkShell {
            packages = devShellPackages;
          };
        }
      );

    mkProjectApp = pkgs: {
      name,
      description,
      src ? null,
      projectPath ?
        if src != null
        then deriveProjectPath src
        else throw "mkProjectApp requires projectPath or src",
      runtimeInputs ? [],
      text,
    }:
      pkgs.writeShellApplication {
        name = name;
        meta = {
          description = description;
          mainProgram = name;
        };
        runtimeInputs = [pkgs.git] ++ runtimeInputs;
        text =
          ''
            repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
            if [ -n "$repo_root" ] && [ -d "$repo_root/${projectPath}" ]; then
              cd "$repo_root/${projectPath}"
            elif [ -d "$PWD/${projectPath}" ]; then
              cd "$PWD/${projectPath}"
            elif [ -f "$PWD/flake.nix" ] || [ -f "$PWD/default.nix" ]; then
              :
            else
              printf '%s\n' "Run this from the repo root or from ${projectPath}." >&2
              exit 1
            fi
          ''
          + "\n"
          + text;
      };

    mkProjectCommandsApp = pkgs: {
      name,
      description,
      src ? null,
      projectPath ?
        if src != null
        then deriveProjectPath src
        else throw "mkProjectCommandsApp requires projectPath or src",
      parts ? [],
      runtimeInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands,
    }: let
      resolved = resolveProjectOp pkgs {
        inherit parts env repoFmtPaths commands;
        extraInputs = runtimeInputs;
      };
    in
      mkProjectApp pkgs {
        inherit name description src projectPath;
        runtimeInputs = resolved.runtimeInputs;
        text = joinLines [resolved.envScript resolved.command];
      };

    mkProjectCheck = pkgs: {
      name,
      src,
      nativeBuildInputs ? [],
      text,
    }:
      pkgs.runCommand name {
        nativeBuildInputs = nativeBuildInputs;
      } ''
        set -euo pipefail
        cd ${src}
        ${text}
        touch "$out"
      '';

    mkProjectCommandsCheck = pkgs: {
      name,
      src,
      parts ? [],
      nativeBuildInputs ? [],
      env ? {},
      repoFmtPaths ? [],
      commands,
    }: let
      resolved = resolveProjectOp pkgs {
        inherit parts env repoFmtPaths commands;
        extraInputs = nativeBuildInputs;
        forCheck = true;
      };
    in
      mkProjectCheck pkgs {
        inherit name src;
        nativeBuildInputs = resolved.runtimeInputs;
        text =
          if resolved.writableCopy
          then ''
            tmp_tree="$TMPDIR/project-check"
            cp -r . "$tmp_tree"
            chmod -R u+w "$tmp_tree"
            cd "$tmp_tree"
            ${resolved.envScript}
            ${resolved.command}
          ''
          else joinLines [resolved.envScript resolved.command];
      };

    collectNestedFlakeExtras = field: values:
      builtins.foldl'
      (acc: value:
        if builtins.isAttrs value && builtins.hasAttr field value
        then acc // (builtins.getAttr field value)
        else acc)
      {}
      values;

    wirePassthru = drv: extra: let
      extraValues = builtins.attrValues extra;
      nestedFlakeExtraPackages = collectNestedFlakeExtras "flakeExtraPackages" extraValues;
      nestedFlakeExtraApps = collectNestedFlakeExtras "flakeExtraApps" extraValues;
      nestedFlakeExtraChecks = collectNestedFlakeExtras "flakeExtraChecks" extraValues;
      nestedFlakeExtraNixosModules = collectNestedFlakeExtras "flakeExtraNixosModules" extraValues;
    in
      drv.overrideAttrs (old: let
        passthru = old.passthru or {};
      in {
        passthru =
          passthru
          // extra
          // (attrIf (nestedFlakeExtraPackages != {} || passthru ? flakeExtraPackages || extra ? flakeExtraPackages) "flakeExtraPackages" (
            (passthru.flakeExtraPackages or {})
            // nestedFlakeExtraPackages
            // (extra.flakeExtraPackages or {})
          ))
          // (attrIf (nestedFlakeExtraApps != {} || passthru ? flakeExtraApps || extra ? flakeExtraApps) "flakeExtraApps" (
            (passthru.flakeExtraApps or {})
            // nestedFlakeExtraApps
            // (extra.flakeExtraApps or {})
          ))
          // (attrIf (nestedFlakeExtraChecks != {} || passthru ? flakeExtraChecks || extra ? flakeExtraChecks) "flakeExtraChecks" (
            (passthru.flakeExtraChecks or {})
            // nestedFlakeExtraChecks
            // (extra.flakeExtraChecks or {})
          ))
          // (attrIf (nestedFlakeExtraNixosModules != {} || passthru ? flakeExtraNixosModules || extra ? flakeExtraNixosModules) "flakeExtraNixosModules" (
            (passthru.flakeExtraNixosModules or {})
            // nestedFlakeExtraNixosModules
            // (extra.flakeExtraNixosModules or {})
          ));
      });

    inferBuildSrc = build:
      if builtins.hasAttr "src" build
      then build.src
      else throw "pkg-helper: build derivation must expose `src` or the helper call must pass `src` explicitly";

    mkAggregateDerivation = {
      pkgs,
      src,
      pname ? deriveProjectName src,
      buildPaths ? [],
      emptyName ? "${pname}-empty",
      fmtParts ? [
        (projectFmtGlobal {})
      ],
      extraPassthru ? {},
      extraPackages ? {},
      extraApps ? {},
    }: let
      build =
        if buildPaths == []
        then
          pkgs.runCommand emptyName {} ''
            mkdir -p "$out"
          ''
        else
          pkgs.symlinkJoin {
            name = "${pname}-build";
            paths = buildPaths;
          };
      bundle = mkPackageOpsBundle {
        inherit pkgs src pname;
        apps = {
          fmt = {
            parts = fmtParts;
          };
        };
        checks = {
          fmt = {
            parts = fmtParts;
          };
        };
        devShellPackages = null;
      };
    in
      wirePassthru build ({
          build = build;
          inherit (bundle) fmt pkgOps checks;
          flakeExtraPackages = extraPackages;
          flakeExtraApps = extraApps;
        }
        // extraPassthru);

    mkPackageApp = pkgs: pkg: {
      type = "app";
      program = pkgs.lib.getExe pkg;
      inherit (pkg) meta;
    };

    mkNixosModuleAttrs = {
      build,
      extraModules ? {},
      resolveModule ? passthru:
        if builtins.hasAttr "nixosModule" passthru
        then
          if builtins.isAttrs passthru.nixosModule && builtins.hasAttr "__boundModuleFactory" passthru.nixosModule
          then passthru.nixosModule.__boundModuleFactory build
          else if builtins.isFunction passthru.nixosModule
          then passthru.nixosModule
          else passthru.nixosModule
        else null,
    }: let
      passthru = build.passthru or {};
      resolvedModule = resolveModule passthru;
    in
      (attrIf (resolvedModule != null) "default" resolvedModule)
      // (attrIf (resolvedModule != null) build.pname resolvedModule)
      // (passthru.flakeExtraNixosModules or {})
      // extraModules;

    mkStdFlakeOutputs = {
      pkgs,
      build,
      checks ?
        if builtins.hasAttr "checks" build
        then build.checks
        else {},
      defaultApp ? null,
      devShell ?
        if builtins.hasAttr "devShell" build
        then build.devShell
        else null,
      extraPackages ? {},
      extraApps ? {},
      extraChecks ? {},
      extraNixosModules ? {},
    }: let
      passthru = build.passthru or {};
      passthruExtraPackages = passthru.flakeExtraPackages or {};
      passthruExtraApps = passthru.flakeExtraApps or {};
      nixosModuleAttrs = mkNixosModuleAttrs {
        inherit build;
        extraModules = extraNixosModules;
      };
      hasMainProgram = pkg:
        builtins.hasAttr "meta" pkg
        && builtins.isAttrs pkg.meta
        && builtins.hasAttr "mainProgram" pkg.meta;
      runPkg =
        if builtins.hasAttr "run" build
        then build.run
        else build;
      effectiveDefaultApp =
        if defaultApp != null
        then defaultApp
        else if hasMainProgram runPkg
        then "run"
        else if builtins.hasAttr "dev" build
        then "dev"
        else null;
      packageAttrs =
        {
          default = build;
          build = build;
          run = runPkg;
        }
        // (attrIf (builtins.hasAttr "dev" build) "dev" build.dev)
        // (attrIf (builtins.hasAttr "fmt" build) "fmt" build.fmt)
        // (attrIf (builtins.hasAttr "lint-fix" build) "lint-fix" build."lint-fix")
        // passthruExtraPackages
        // extraPackages;
      appAttrs =
        (attrIf (effectiveDefaultApp != null) "default" (
          mkPackageApp pkgs (
            if effectiveDefaultApp == "run"
            then runPkg
            else build.${effectiveDefaultApp}
          )
        ))
        // (attrIf (hasMainProgram runPkg) "run" (mkPackageApp pkgs runPkg))
        // (attrIf (builtins.hasAttr "dev" build) "dev" (mkPackageApp pkgs build.dev))
        // (attrIf (builtins.hasAttr "fmt" build) "fmt" (mkPackageApp pkgs build.fmt))
        // (attrIf (builtins.hasAttr "lint-fix" build) "lint-fix" (mkPackageApp pkgs build."lint-fix"))
        // passthruExtraApps
        // extraApps;
      devShellAttrs =
        if devShell == null
        then {}
        else {
          devShells.default = devShell;
        };
    in
      {
        packages = packageAttrs;
        apps = appAttrs;
        checks = {build = build;} // checks // extraChecks;
      }
      // (attrIf (nixosModuleAttrs != {}) "nixosModules" nixosModuleAttrs)
      // devShellAttrs;
  };

  languageContext = common // {inherit attrIf commonAutoExcludes deriveProjectName deriveProjectPath exportEnv exportLiteralEnv hasPrefix isDerivation joinLines joinWords shellWords stripPrefix;};
  rust = import ./rust {
    common = languageContext;
    pkgHelper = helper;
  };
  go = import ./go {common = languageContext;};
  python = import ./python {common = languageContext;};
  nodejs = import ./nodejs {common = languageContext;};
  shell = import ./shell {common = languageContext;};

  # A new language must not silently replace another language's public API.
  helper = builtins.foldl' (acc: language:
    assert builtins.intersectAttrs acc language == {};
      acc // language)
  common [rust go python nodejs shell];
in
  helper
