{
  nixos = {...}: {};

  home = {pkgs, ...}: {
    programs.vscode = {
      enable = true;
      profiles.default = {
        extensions = with pkgs.vscode-extensions; [
          ms-vscode-remote.remote-ssh
          ms-vscode-remote.remote-ssh-edit
          ms-vscode-remote.remote-containers
          ms-vscode.remote-explorer
          ms-azuretools.vscode-containers
          ms-vscode.hexeditor
          ms-vscode.cpptools-extension-pack

          # vscodevim.vim
          yzhang.markdown-all-in-one
          redhat.vscode-yaml
          jnoortheen.nix-ide
          arrterian.nix-env-selector
          rust-lang.rust-analyzer
          fill-labs.dependi

          github.copilot-chat
          pkgs.vscode-marketplace.openai.chatgpt
          pkgs.vscode-marketplace.continue.continue
        ];

        keybindings = [
          {
            key = "alt+left";
            command = "workbench.action.navigateBack";
            when = "canNavigateBack";
          }
          {
            key = "ctrl+alt+-";
            command = "-workbench.action.navigateBack";
            when = "canNavigateBack";
          }
          {
            key = "alt+right";
            command = "workbench.action.navigateForward";
            when = "canNavigateForward";
          }
          {
            key = "ctrl+shift+-";
            command = "-workbench.action.navigateForward";
            when = "canNavigateForward";
          }
        ];

        userSettings = {
          "editor.wordWrap" = "bounded";
          "window.commandCenter" = false;
          "window.autoDetectColorScheme" = true;
          "github.copilot.nextEditSuggestions.enabled" = true;
          "containers.containerClient" = "com.microsoft.visualstudio.containers.podman";
          "containers.orchestratorClient" =
            "com.microsoft.visualstudio.orchestrators.podmancompose";
          "workbench.startupEditor" = "none";
          "continue.enableNextEdit" = true;
          "continue.enableQuickActions" = true;
          "nixEnvSelector" = {
            "suggestion" = false;
            "nixEnvSelector.useFlakes" = true;
          };
          "nix" = {
            "enableLanguageServer" = true;
            "serverPath" = "nixd";
            "serverSettings" = {
              "nixd" = {
                "formatting" = {
                  "command" = ["alejandra"];
                };
              };
            };
          };
          "rust-analyzer.cargo.sysrootSrc" = "${pkgs.rustPlatform.rustLibSrc}";
        };
      };
    };
  };
}
