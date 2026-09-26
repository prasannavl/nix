{
  nixos = {...}: {};

  home = {pkgs, ...}: let
    piModelsDiscovery = pkgs.callPackage ../../../lib/ext/pi/pi-models-discovery {
      i18nDefaultLocale = "en-US";
    };
    piSessionManager = pkgs.callPackage ../../../lib/ext/pi/pi-session-manager {};
    piSubagents = pkgs.callPackage ../../../lib/ext/pi/pi-subagents {};
    piTps = pkgs.callPackage ../../../lib/ext/pi/pi-tps {};
    piWeb = pkgs.callPackage ../../../lib/ext/pi/pi-web {};
    piDiff = pkgs.callPackage ../../../lib/ext/pi/pi-diff {};
    piCodexLimit = pkgs.callPackage ../../../lib/ext/pi/pi-codex-limit {};
    revdiff = pkgs.callPackage ../../../lib/ext/revdiff {};
    revdiffPi = pkgs.callPackage ../../../lib/ext/revdiff/pi.nix {};
    piModelsDiscoveryRoot = "${piModelsDiscovery}/share/pi/packages/pi-models-discovery";
    piSessionManagerRoot = "${piSessionManager}/share/pi/packages/pi-session-manager";
    piSubagentsRoot = "${piSubagents}/lib/node_modules/pi-subagents";
    piTpsRoot = "${piTps}/share/pi/packages/pi-tps";
    piDiffRoot = "${piDiff}/lib/node_modules/@heyhuynhgiabuu/pi-diff";
    piCodexLimitRoot = "${piCodexLimit}/share/pi/packages/pi-codex-limit";
    revdiffPiRoot = "${revdiffPi}/share/pi/packages/revdiff-pi";
    subagentPrompts = [
      "council"
      "gather-context-and-clarify"
      "parallel-cleanup"
      "parallel-research"
      "parallel-review"
      "review-loop"
    ];
  in {
    home.packages = [pkgs.unstable.pi-coding-agent piWeb revdiff];

    home.file =
      {
        ".pi/agent/extensions/pi-codex-limit".source = piCodexLimitRoot;
        ".pi/agent/extensions/pi-diff".source = piDiffRoot;
        ".pi/agent/extensions/pi-extensions-i18n".source = "${piModelsDiscoveryRoot}/node_modules/pi-extensions-i18n";
        ".pi/agent/extensions/pi-models-discovery/index.ts".source = "${piModelsDiscoveryRoot}/index.ts";
        ".pi/agent/extensions/pi-models-discovery/locales".source = "${piModelsDiscoveryRoot}/locales";
        ".pi/agent/extensions/pi-models-discovery/node_modules".source = "${piModelsDiscoveryRoot}/node_modules";
        ".pi/agent/extensions/pi-models-discovery/package.json".source = "${piModelsDiscoveryRoot}/package.json";
        ".pi/agent/extensions/pi-models-discovery/src".source = "${piModelsDiscoveryRoot}/src";
        ".pi/agent/extensions/pi-revdiff".source = revdiffPiRoot;
        ".pi/agent/extensions/pi-session-manager.ts".source = "${piSessionManagerRoot}/extensions/session-manager.ts";
        ".pi/agent/extensions/pi-subagents".source = piSubagentsRoot;
        ".pi/agent/extensions/pi-tps.ts".source = "${piTpsRoot}/extensions/pi-tps.ts";

        ".pi/agent/skills/pi-models-discovery/SKILL.md".source = "${piModelsDiscoveryRoot}/SKILL.md";
        ".pi/agent/skills/council-mode".source = "${piSubagentsRoot}/skills/council-mode";
        ".pi/agent/skills/pi-subagents".source = "${piSubagentsRoot}/skills/pi-subagents";
        ".pi/agent/skills/revdiff".source = "${revdiffPiRoot}/plugins/pi/skills/revdiff";
      }
      // builtins.listToAttrs (map (name: {
          name = ".pi/agent/prompts/${name}.md";
          value.source = "${piSubagentsRoot}/prompts/${name}.md";
        })
        subagentPrompts);
  };
}
