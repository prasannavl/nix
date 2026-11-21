# Language implementation; pkg-helper.nix supplies the shared operations.
{common}: let
  inherit (common) commonAutoExcludes deriveProjectName inferBuildSrc joinWords mkAutoFilesPart mkPackageOpsBundle mkProjectApp projectFmtGlobal wirePassthru;

  biomeExtensions = [
    "*.js"
    "*.jsx"
    "*.mjs"
    "*.cjs"
    "*.ts"
    "*.tsx"
    "*.css"
    "*.html"
  ];

  biomeInputs = pkgs: [
    pkgs.biome
    pkgs.findutils
  ];
in rec {
  biomeFmt = {paths}: "biome format --write ${joinWords paths}";
  biomeFmtCheck = {paths}: "biome check --formatter-enabled=true --linter-enabled=false ${joinWords paths}";
  biomeLint = {paths ? ["."]}: "biome check ${joinWords paths}";
  biomeLintFix = {paths ? ["."]}: "biome check --write ${joinWords paths}";

  projectFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome format --write ${files}";
      writableCopy = true;
    };

  projectLintBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_lint_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check ${files}";
      writableCopy = true;
    };

  projectCheckFmtBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_fmt_check_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check --formatter-enabled=true --linter-enabled=false ${files}";
    };

  projectLintFixBiome = pkgs: {
    roots ? ["."],
    excludes ? commonAutoExcludes,
  }:
    mkAutoFilesPart {
      inputs = biomeInputs pkgs;
      varName = "biome_fix_files";
      inherit roots excludes;
      extensions = biomeExtensions;
      commandBuilder = files: "biome check --write ${files}";
      writableCopy = true;
    };

  mkWebParts = {
    pkgs,
    src,
    pname ? deriveProjectName src,
    fmtParts ? [
      (projectFmtGlobal {})
      (projectFmtBiome pkgs {})
    ],
    fmtCheckParts ? [
      (projectFmtGlobal {})
      (projectCheckFmtBiome pkgs {})
    ],
    lintParts ? [
      (projectLintBiome pkgs {})
    ],
    lintFixParts ? [
      (projectLintFixBiome pkgs {})
    ],
    enableLint ? true,
    enableLintFix ? true,
    lintCommands ? [],
    lintFixCommands ? [],
    devShellPackages ? [
      pkgs.biome
      pkgs.nodejs
      pkgs.deno
    ],
    extraDevShellPackages ? [],
  }:
    mkPackageOpsBundle {
      inherit pkgs src pname;
      devShellPackages = devShellPackages ++ extraDevShellPackages;
      apps =
        {
          fmt = {
            parts = fmtParts;
          };
        }
        // (
          if enableLintFix
          then {
            "lint-fix" = {
              parts = lintFixParts;
              commands = lintFixCommands;
            };
          }
          else {}
        );
      checks =
        {
          fmt = {
            parts = fmtCheckParts;
          };
        }
        // (
          if enableLint
          then {
            lint = {
              parts = lintParts;
              commands = lintCommands;
            };
          }
          else {}
        );
    };

  mkWebDerivation = args @ {
    build,
    src ? inferBuildSrc build,
    ...
  }:
    wirePassthru build (mkWebParts ((builtins.removeAttrs args ["build"]) // {inherit src;}));

  mkStaticWebDerivation = {
    pkgs,
    build,
    src ? inferBuildSrc build,
    pname ? deriveProjectName src,
    devRoot ? "site",
    devPort ? "8080",
    devBind ? "127.0.0.1",
    extraDevShellPackages ? [pkgs.python3],
    extraPassthru ? {},
    enableLint ? true,
    enableLintFix ? true,
    ...
  } @ args: let
    dev = mkProjectApp pkgs {
      name = "${pname}-dev";
      description = "Run the ${pname} static web development server";
      inherit src;
      runtimeInputs = [pkgs.python3];
      text = ''
        root="${devRoot}"
        port="${devPort}"
        bind="${devBind}"

        if [ "$#" -gt 0 ]; then
          root="$1"
          shift
        fi

        cd "$root"
        exec python -m http.server "$port" --bind "$bind" "$@"
      '';
    };
    drv =
      mkWebDerivation
      ((builtins.removeAttrs args [
          "extraDevShellPackages"
          "extraPassthru"
          "devBind"
          "devPort"
          "devRoot"
          "pname"
          "enableLint"
          "enableLintFix"
        ])
        // {
          inherit build pkgs src pname enableLint enableLintFix;
          extraDevShellPackages = extraDevShellPackages;
        });
  in
    wirePassthru drv ({dev = dev;} // extraPassthru);
}
