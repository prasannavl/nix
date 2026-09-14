{pkgs ? import <nixpkgs> {}}: let
  pname = "pi-subagents";
  source = (builtins.fromJSON (builtins.readFile ../sources.json)).${pname};
in
  pkgs.buildNpmPackage {
    inherit pname;
    inherit (source) version;

    src = pkgs.fetchFromGitHub {
      owner = "nicobailon";
      repo = "pi-subagents";
      inherit (source) rev;
      hash = source.srcHash;
    };

    inherit (source) npmDepsHash;

    dontNpmBuild = true;

    postInstall = ''
      packageRoot="$out/lib/node_modules/pi-subagents"
      workflows="$packageRoot/docs/workflows.md"

      substituteInPlace "$packageRoot/skills/pi-subagents/SKILL.md" \
        --replace-fail '../../docs/workflows.md' "$workflows"
      substituteInPlace "$packageRoot/skills/pi-subagents/references/execution-controls.md" \
        --replace-fail '../../../docs/workflows.md' "$workflows"
    '';

    meta = {
      description = "Subagent delegation and workflow extension for Pi";
      homepage = "https://github.com/nicobailon/pi-subagents";
      license = pkgs.lib.licenses.mit;
      mainProgram = "pi-subagents";
      platforms = pkgs.lib.platforms.all;
    };
  }
