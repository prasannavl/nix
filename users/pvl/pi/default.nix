{
  nixos = {...}: {};

  home = {
    config,
    pkgs,
    osConfig,
    ...
  }: let
    piModelsDiscovery = pkgs.callPackage ../../../lib/ext/pi/pi-models-discovery {
      i18nDefaultLocale = "en-US";
    };
    piSessionManager = pkgs.callPackage ../../../lib/ext/pi/pi-session-manager {};
    piSubagents = pkgs.callPackage ../../../lib/ext/pi/pi-subagents {};
    piTps = pkgs.callPackage ../../../lib/ext/pi/pi-tps {};
    piWeb = pkgs.callPackage ../../../lib/ext/pi/pi-web {};
    piDiff = pkgs.callPackage ../../../lib/ext/pi/pi-diff {};
    piMcpAdapter = pkgs.callPackage ../../../lib/ext/pi/pi-mcp-adapter {};
    piPattyBgTasks = pkgs.callPackage ../../../lib/ext/pi/pi-patty-bg-tasks {};
    piUsage = pkgs.callPackage ../../../lib/ext/pi/pi-usage {};
    piTool = pkgs.callPackage ../../../lib/ext/pi/pi-tool {};
    piGoal = pkgs.callPackage ../../../lib/ext/pi/pi-goal {};
    piWait = pkgs.callPackage ../../../lib/ext/pi/pi-wait {};
    piLoop = pkgs.callPackage ../../../lib/ext/pi/pi-loop {};
    piUntil = pkgs.callPackage ../../../lib/ext/pi/pi-until {};
    piNotify = pkgs.callPackage ../../../lib/ext/pi/pi-notify {};
    piOpenaiToolkit = pkgs.callPackage ../../../lib/ext/pi/pi-openai-toolkit {};
    piTotalRecall = pkgs.callPackage ../../../lib/ext/pi/pi-total-recall {};
    rpivVoice = pkgs.callPackage ../../../lib/ext/pi/rpiv-voice {};
    rpivTodo = pkgs.callPackage ../../../lib/ext/pi/rpiv-todo {};
    rpivBtw = pkgs.callPackage ../../../lib/ext/pi/rpiv-btw {};
    rpivAdvisor = pkgs.callPackage ../../../lib/ext/pi/rpiv-advisor {};
    piStamp = pkgs.callPackage ../../../lib/ext/pi/pi-stamp {};
    piAnthropicAuth = pkgs.callPackage ../../../lib/ext/pi/pi-anthropic-auth {};
    piToolManager = pkgs.callPackage ../../../lib/ext/pi/pi-tool-manager {};
    bladebro = pkgs.bladebro;
    computerUseLinux = pkgs.computer-use-linux;
    gimpMcp = pkgs.gimp-mcp;
    mcpForBlender = pkgs.mcp-for-blender;
    mcpvault = pkgs.mcpvault;
    officePowerpoint = pkgs.office-powerpoint-mcp-server;
    rmGuard = pkgs.writeShellApplication {
      name = "rm";
      runtimeInputs = [pkgs.coreutils pkgs.findutils];
      text = builtins.readFile ./rm-guard/rm.sh;
    };
    piModelsDiscoveryRoot = "${piModelsDiscovery}/share/pi/packages/pi-models-discovery";
    piSessionManagerRoot = "${piSessionManager}/share/pi/packages/pi-session-manager";
    piSubagentsRoot = "${piSubagents}/lib/node_modules/@gotgenes/pi-subagents";
    piTpsRoot = "${piTps}/share/pi/packages/pi-tps";
    piDiffRoot = "${piDiff}/lib/node_modules/@heyhuynhgiabuu/pi-diff";
    piPattyBgTasksRoot = "${piPattyBgTasks}/share/pi/packages/pi-patty-bg-tasks";
    piUsageRoot = "${piUsage}/share/pi/packages/pi-usage";
    piToolRoot = "${piTool}/share/pi/packages/pi-tool";
    piGoalRoot = "${piGoal}/share/pi/packages/pi-goal";
    piWaitRoot = "${piWait}/share/pi/packages/pi-wait";
    piLoopRoot = "${piLoop}/share/pi/packages/pi-loop";
    piUntilRoot = "${piUntil}/share/pi/packages/pi-until";
    piNotifyRoot = "${piNotify}/share/pi/packages/pi-notify";
    piOpenaiToolkitRoot = "${piOpenaiToolkit}/share/pi/packages/pi-openai-toolkit";
    piTotalRecallRoot = "${piTotalRecall}/share/pi/packages/pi-total-recall";
    rpivVoiceRoot = "${rpivVoice}/share/pi/packages/rpiv-voice";
    rpivTodoRoot = "${rpivTodo}/share/pi/packages/rpiv-todo";
    rpivBtwRoot = "${rpivBtw}/share/pi/packages/rpiv-btw";
    rpivAdvisorRoot = "${rpivAdvisor}/share/pi/packages/rpiv-advisor";
    piStampRoot = "${piStamp}/share/pi/packages/pi-stamp";
    piAnthropicAuthRoot = "${piAnthropicAuth}/share/pi/packages/pi-anthropic-auth";
    piToolManagerRoot = "${piToolManager}/share/pi/packages/pi-tool-manager";
    piMcpAdapterRoot = "${piMcpAdapter}/lib/node_modules/pi-mcp-adapter";
    bladebroRoot = "${bladebro}/share/pi/packages/bladebro";
    piDiffConfig = {disabledTools = ["apply_patch"];};
    # The desktop MCP servers drive a live Blender/GIMP/session, so they stay on
    # the graphical hosts and off the headless container profiles. Playwright
    # runs `--headless`, so it needs no session and is declared everywhere; its
    # ~2.3 GiB browser closure is accepted on the container profiles too. The
    # adapter reads the standard shared MCP file as its user-global server
    # source and keeps its own writable overrides in mcp-adapter.json.
    graphicalHost = !osConfig.boot.isContainer;
    # Obsidian vault read/written by mcpvault; Obsidian itself need not run.
    obsidianVault = "${config.home.homeDirectory}/notes";
    mcpConfig = {
      mcpServers =
        {
          obsidian = {
            command = "${mcpvault}/bin/mcpvault";
            args = [obsidianVault];
          };
          playwright = {
            command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
            args = ["--headless" "--isolated"];
          };
          powerpoint = {
            command = "${officePowerpoint}/bin/ppt_mcp_server";
          };
        }
        // pkgs.lib.optionalAttrs graphicalHost {
          blender = {
            command = "${mcpForBlender}/bin/mcp-for-blender";
          };
          gimp = {
            command = "${gimpMcp}/bin/gimp-mcp-server";
          };
          computer-use-linux = {
            command = "${computerUseLinux}/bin/computer-use-linux";
            args = ["mcp"];
            # One process per session: AT-SPI element indices stay valid across
            # calls, so keep the server alive instead of idling it out.
            lifecycle = "lazy-keep-alive";
          };
        };
    };
  in {
    home.packages =
      [
        pkgs.unstable.pi-coding-agent
        piWeb
        bladebro
        mcpvault
        officePowerpoint
        pkgs.playwright-mcp
      ]
      ++ pkgs.lib.optionals graphicalHost [
        computerUseLinux
        gimpMcp
        mcpForBlender
      ];

    home.file = {
      ".pi/agent/extensions/bladebro".source = bladebroRoot;
      ".pi/agent/extensions/pi-diff".source = piDiffRoot;
      ".pi/agent/extensions/pi-extensions-i18n".source = "${piModelsDiscoveryRoot}/node_modules/pi-extensions-i18n";
      ".pi/agent/extensions/pi-models-discovery/index.ts".source = "${piModelsDiscoveryRoot}/index.ts";
      ".pi/agent/extensions/pi-models-discovery/locales".source = "${piModelsDiscoveryRoot}/locales";
      ".pi/agent/extensions/pi-models-discovery/node_modules".source = "${piModelsDiscoveryRoot}/node_modules";
      ".pi/agent/extensions/pi-models-discovery/package.json".source = "${piModelsDiscoveryRoot}/package.json";
      ".pi/agent/extensions/pi-models-discovery/src".source = "${piModelsDiscoveryRoot}/src";
      ".pi/agent/extensions/pi-mcp-adapter".source = piMcpAdapterRoot;
      ".pi/agent/extensions/pi-patty-bg-tasks".source = piPattyBgTasksRoot;
      ".pi/agent/extensions/pi-usage".source = piUsageRoot;
      ".pi/agent/extensions/pi-tool".source = piToolRoot;
      ".pi/agent/extensions/pi-goal".source = piGoalRoot;
      ".pi/agent/extensions/pi-wait".source = piWaitRoot;
      ".pi/agent/extensions/pi-loop".source = piLoopRoot;
      ".pi/agent/extensions/pi-until".source = piUntilRoot;
      ".pi/agent/extensions/pi-notify".source = piNotifyRoot;
      ".pi/agent/extensions/pi-openai-toolkit".source = piOpenaiToolkitRoot;
      ".pi/agent/extensions/pi-total-recall".source = piTotalRecallRoot;
      ".pi/agent/extensions/rpiv-voice".source = rpivVoiceRoot;
      ".pi/agent/extensions/rpiv-todo".source = rpivTodoRoot;
      ".pi/agent/extensions/rpiv-btw".source = rpivBtwRoot;
      ".pi/agent/extensions/rpiv-advisor".source = rpivAdvisorRoot;
      ".pi/agent/extensions/pi-stamp".source = piStampRoot;
      ".pi/agent/extensions/pi-anthropic-auth".source = piAnthropicAuthRoot;
      ".pi/agent/extensions/pi-tool-manager".source = piToolManagerRoot;
      ".pi/agent/extensions/pi-session-manager.ts".source = "${piSessionManagerRoot}/extensions/session-manager.ts";
      # @gotgenes/pi-subagents ships only the runtime extension. Unlike the
      # previous nicobailon/pi-subagents package it provides no skills or
      # prompt templates, so none are linked below.
      ".pi/agent/extensions/pi-subagents".source = piSubagentsRoot;
      ".pi/agent/extensions/pi-tps.ts".source = "${piTpsRoot}/extensions/pi-tps.ts";
      # Agent shells: refuse recursive rm of repositories, cwd, $HOME, /.
      ".pi/agent/extensions/rm-guard.ts".source = pkgs.replaceVars ./rm-guard/index.ts {
        rmGuardBin = "${rmGuard}/bin";
      };

      # pi-diff can register write/edit/apply_patch. Keep agents on Pi's
      # write/read tools by turning off its patch tool.
      ".pi/agent/pi-diff.json".text = builtins.toJSON piDiffConfig;

      # Shared MCP server declarations for Pi's MCP adapter (and other hosts).
      ".config/mcp/mcp.json".text = builtins.toJSON mcpConfig;

      ".pi/agent/skills/pi-models-discovery/SKILL.md".source = "${piModelsDiscoveryRoot}/SKILL.md";
      # pi-total-recall's manifest points its skill at the bundled
      # pi-session-search copy.
      ".pi/agent/skills/session-history".source = "${piTotalRecallRoot}/node_modules/pi-session-search/skills/session-history";
      ".pi/agent/skills/mcp-scripting".source = "${piMcpAdapterRoot}/skills/mcp-scripting";
    };
  };
}
