{
  nixos = {...}: {};

  home = {
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
    piCodexLimit = pkgs.callPackage ../../../lib/ext/pi/pi-codex-limit {};
    piProcesses = pkgs.callPackage ../../../lib/ext/pi/pi-processes {};
    piMcpAdapter = pkgs.callPackage ../../../lib/ext/pi/pi-mcp-adapter {};
    piUsage = pkgs.callPackage ../../../lib/ext/pi/pi-usage {};
    piOpenaiToolkit = pkgs.callPackage ../../../lib/ext/pi/pi-openai-toolkit {};
    piTotalRecall = pkgs.callPackage ../../../lib/ext/pi/pi-total-recall {};
    rpivVoice = pkgs.callPackage ../../../lib/ext/pi/rpiv-voice {};
    rpivAskUserQuestion = pkgs.callPackage ../../../lib/ext/pi/rpiv-ask-user-question {};
    rpivTodo = pkgs.callPackage ../../../lib/ext/pi/rpiv-todo {};
    rpivBtw = pkgs.callPackage ../../../lib/ext/pi/rpiv-btw {};
    rpivAdvisor = pkgs.callPackage ../../../lib/ext/pi/rpiv-advisor {};
    piStamp = pkgs.callPackage ../../../lib/ext/pi/pi-stamp {};
    bladebro = pkgs.callPackage ../../../pkgs/ext/bladebro {};
    piModelsDiscoveryRoot = "${piModelsDiscovery}/share/pi/packages/pi-models-discovery";
    piSessionManagerRoot = "${piSessionManager}/share/pi/packages/pi-session-manager";
    piSubagentsRoot = "${piSubagents}/lib/node_modules/@gotgenes/pi-subagents";
    piTpsRoot = "${piTps}/share/pi/packages/pi-tps";
    piDiffRoot = "${piDiff}/lib/node_modules/@heyhuynhgiabuu/pi-diff";
    piCodexLimitRoot = "${piCodexLimit}/share/pi/packages/pi-codex-limit";
    piProcessesRoot = "${piProcesses}/share/pi/packages/pi-processes";
    piUsageRoot = "${piUsage}/share/pi/packages/pi-usage";
    piOpenaiToolkitRoot = "${piOpenaiToolkit}/share/pi/packages/pi-openai-toolkit";
    piTotalRecallRoot = "${piTotalRecall}/share/pi/packages/pi-total-recall";
    rpivVoiceRoot = "${rpivVoice}/share/pi/packages/rpiv-voice";
    rpivAskUserQuestionRoot = "${rpivAskUserQuestion}/share/pi/packages/rpiv-ask-user-question";
    rpivTodoRoot = "${rpivTodo}/share/pi/packages/rpiv-todo";
    rpivBtwRoot = "${rpivBtw}/share/pi/packages/rpiv-btw";
    rpivAdvisorRoot = "${rpivAdvisor}/share/pi/packages/rpiv-advisor";
    piStampRoot = "${piStamp}/share/pi/packages/pi-stamp";
    piMcpAdapterRoot = "${piMcpAdapter}/lib/node_modules/pi-mcp-adapter";
    bladebroRoot = "${bladebro}/share/pi/packages/bladebro";
    piDiffConfig = {disabledTools = ["apply_patch"];};
    # Playwright's browser closure is ~2 GiB, so keep the MCP server on the
    # graphical hosts and off the headless container profiles. The adapter
    # reads the standard shared MCP file as its user-global server source and
    # keeps its own writable overrides in mcp-adapter.json.
    playwrightEnabled = !osConfig.boot.isContainer;
    mcpConfig = {
      mcpServers = pkgs.lib.optionalAttrs playwrightEnabled {
        playwright = {
          command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
          args = ["--headless" "--isolated"];
        };
      };
    };
  in {
    home.packages =
      [pkgs.unstable.pi-coding-agent piWeb bladebro]
      ++ pkgs.lib.optional playwrightEnabled pkgs.playwright-mcp;

    home.file = {
      ".pi/agent/extensions/bladebro".source = bladebroRoot;
      ".pi/agent/extensions/pi-codex-limit".source = piCodexLimitRoot;
      ".pi/agent/extensions/pi-diff".source = piDiffRoot;
      ".pi/agent/extensions/pi-extensions-i18n".source = "${piModelsDiscoveryRoot}/node_modules/pi-extensions-i18n";
      ".pi/agent/extensions/pi-models-discovery/index.ts".source = "${piModelsDiscoveryRoot}/index.ts";
      ".pi/agent/extensions/pi-models-discovery/locales".source = "${piModelsDiscoveryRoot}/locales";
      ".pi/agent/extensions/pi-models-discovery/node_modules".source = "${piModelsDiscoveryRoot}/node_modules";
      ".pi/agent/extensions/pi-models-discovery/package.json".source = "${piModelsDiscoveryRoot}/package.json";
      ".pi/agent/extensions/pi-models-discovery/src".source = "${piModelsDiscoveryRoot}/src";
      ".pi/agent/extensions/pi-mcp-adapter".source = piMcpAdapterRoot;
      # pi-processes ships three extensions through its package manifest, so the
      # whole package directory is linked; its node_modules sits beside them.
      ".pi/agent/extensions/pi-processes".source = piProcessesRoot;
      ".pi/agent/extensions/pi-usage".source = piUsageRoot;
      ".pi/agent/extensions/pi-openai-toolkit".source = piOpenaiToolkitRoot;
      ".pi/agent/extensions/pi-total-recall".source = piTotalRecallRoot;
      ".pi/agent/extensions/rpiv-voice".source = rpivVoiceRoot;
      ".pi/agent/extensions/rpiv-ask-user-question".source = rpivAskUserQuestionRoot;
      ".pi/agent/extensions/rpiv-todo".source = rpivTodoRoot;
      ".pi/agent/extensions/rpiv-btw".source = rpivBtwRoot;
      ".pi/agent/extensions/rpiv-advisor".source = rpivAdvisorRoot;
      ".pi/agent/extensions/pi-stamp".source = piStampRoot;
      ".pi/agent/extensions/pi-session-manager.ts".source = "${piSessionManagerRoot}/extensions/session-manager.ts";
      # @gotgenes/pi-subagents ships only the runtime extension. Unlike the
      # previous nicobailon/pi-subagents package it provides no skills or
      # prompt templates, so none are linked below.
      ".pi/agent/extensions/pi-subagents".source = piSubagentsRoot;
      ".pi/agent/extensions/pi-tps.ts".source = "${piTpsRoot}/extensions/pi-tps.ts";

      # pi-diff can register write/edit/apply_patch. Keep agents on Pi's
      # write/read tools by turning off its patch tool.
      ".pi/agent/pi-diff.json".text = builtins.toJSON piDiffConfig;

      # Shared MCP server declarations for Pi's MCP adapter (and other hosts).
      ".config/mcp/mcp.json" = pkgs.lib.mkIf playwrightEnabled {
        text = builtins.toJSON mcpConfig;
      };

      ".pi/agent/skills/pi-models-discovery/SKILL.md".source = "${piModelsDiscoveryRoot}/SKILL.md";
      ".pi/agent/skills/pi-processes".source = "${piProcessesRoot}/skills/pi-processes";
      # pi-total-recall's manifest points its skill at the bundled
      # pi-session-search copy.
      ".pi/agent/skills/session-history".source = "${piTotalRecallRoot}/node_modules/pi-session-search/skills/session-history";
      ".pi/agent/skills/mcp-scripting".source = "${piMcpAdapterRoot}/skills/mcp-scripting";
    };
  };
}
