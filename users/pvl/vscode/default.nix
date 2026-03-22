{
  nixos = _: {};

  home = {pkgs, ...}: {
    programs.vscode = {
      enable = true;
      package = pkgs.vscode-upstream;
      profiles.default = let
        # Keep extensions aligned to the stable release train that nix-vscode-extensions publishes.
        v = pkgs.vscode-upstream.version;
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

          # vscodevim.vim
          yzhang.markdown-all-in-one
          redhat.vscode-yaml
          jnoortheen.nix-ide
          arrterian.nix-env-selector
          rust-lang.rust-analyzer
          fill-labs.dependi
          hashicorp.terraform
          ms-python.python

          github.copilot-chat
          openai.chatgpt
          google.gemini-cli-vscode-ide-companion
          continue.continue
          # kilocode.kilo-code
          # anthropic.claude-code
          # google.geminicodeassist

          golang.go
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
      };
    };
  };
}
