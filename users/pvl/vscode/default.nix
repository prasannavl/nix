{
  nixos = {...}: {};

  home = {pkgs, ...}: let
    shiftEnterCsiU = builtins.fromJSON ''"\u001b[13;2u"'';
    vscodePackage = pkgs.vscode-upstream.override {
      commandLineArgs = "--password-store=gnome-libsecret";
    };
  in {
    programs.vscode = {
      enable = true;
      package = vscodePackage;
      mutableExtensionsDir = false;
      profiles.default = let
        # Keep extensions aligned to the stable release train that nix-vscode-extensions publishes.
        v = vscodePackage.version;
        e = pkgs.nix-vscode-extensions.forVSCodeVersion v;
        r = e.vscode-marketplace-release;
      in {
        extensions = with r; [
          ms-vscode-remote.remote-ssh
          ms-vscode-remote.remote-ssh-edit
          ms-vscode-remote.remote-containers
          ms-vscode.remote-explorer
          ms-azuretools.vscode-containers
          ms-vscode.hexeditor
          ms-vscode.cpptools-extension-pack
          ms-python.python

          ms-azuretools.vscode-containers
          ms-ossdata.vscode-pgsql
          github.vscode-pull-request-github
          # github.copilot-chat

          # vscodevim.vim
          # yzhang.markdown-all-in-one
          redhat.vscode-yaml
          jnoortheen.nix-ide
          mkhl.direnv
          rust-lang.rust-analyzer
          fill-labs.dependi
          hashicorp.terraform
          golang.go

          openai.chatgpt
          kilocode.kilo-code
          # anthropic.claude-code
          # google.gemini-cli-vscode-ide-companion
          # google.geminicodeassist
          # continue.continue

          denoland.vscode-deno
          alexcvzz.vscode-sqlite
          johnpapa.vscode-peacock
          kdl-org.kdl
          bierner.markdown-mermaid
          reduckted.vscode-gitweblinks
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
          {
            key = "alt+x";
            command = "workbench.action.toggleMaximizedPanel";
            when = "panelAlignment == 'center'";
          }
          {
            key = "shift+enter";
            command = "workbench.action.terminal.sendSequence";
            when = "terminalFocus";
            args.text = shiftEnterCsiU;
          }
        ];
      };
    };
  };
}
