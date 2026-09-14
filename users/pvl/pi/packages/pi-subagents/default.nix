{pkgs ? import <nixpkgs> {}}:
pkgs.buildNpmPackage {
  pname = "pi-subagents";
  version = "0.67.0";

  src = pkgs.fetchFromGitHub {
    owner = "nicobailon";
    repo = "pi-subagents";
    rev = "aa75b3353836f7868898e3bd58234d21eaff1463";
    hash = "sha256-XXqK6RnalPPxoOkW+RY81xRzOnB2VYfoFP47pGcHzEI=";
  };

  npmDepsHash = "sha256-Bto6gZcATd4R2ilK4fYlYzfiVaToLxR/6uCPSPqTuuI=";

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
