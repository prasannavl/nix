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
        extensions = with r; [
          ms-vscode-remote.remote-ssh
          ms-vscode-remote.remote-ssh-edit
          ms-vscode-remote.remote-containers
          ms-vscode.remote-explorer
          ms-azuretools.vscode-containers
          ms-vscode.hexeditor
          ms-vscode.cpptools-extension-pack
          ms-python.python

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
        extensionIds =
          map (extension: extension.vscodeExtUniqueId) extensions;
        profileSettings = {
          "workbench.startupEditor" = "none";
          "workbench.colorTheme" = "Dark Modern";
          "editor.wordWrap" = "bounded";
          "editor.wordWrapColumn" = 120;
          "diffEditor.ignoreTrimWhitespace" = false;
          "git.autofetch" = true;
          "git.detectWorktrees" = true;
          "terminal.integrated.allowInUntrustedWorkspace" = true;
          "terminal.integrated.defaultLocation" = "editor";
          "terminal.integrated.gpuAcceleration" = "off";
          "terminal.integrated.initialHint" = false;
          "chatgpt.followUpQueueMode" = "steer";
          "chat.viewSessions.orientation" = "stacked";
          "kilo-code.new.agentWorkStyle" = "autonomous";
          "kilo-code.new.showTaskTimeline" = true;
          "kilo-code.new.autoApprove.enabled" = true;
          "remote.SSH.defaultExtensions" = extensionIds;
        };
        pvlProfile = pkgs.vscode-utils.buildVscodeExtension {
          pname = "pvl-profile";
          version = "1.0.0";
          vscodeExtPublisher = "pvl";
          vscodeExtName = "profile";
          vscodeExtUniqueId = "pvl.profile";
          sourceRoot = "package.json";
          src = pkgs.writeTextDir "package.json" (builtins.toJSON {
            name = "profile";
            displayName = "pvl-profile";
            description = "pvl-profile defaults.";
            version = "1.0.0";
            publisher = "pvl";
            engines.vscode = "^${v}";
            extensionKind = ["ui"];
            categories = ["Other"];
            contributes.configurationDefaults = profileSettings;
          });
        };
      in {
        extensions = extensions ++ [pvlProfile];

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
