{
  config,
  pkgs,
  ...
}: {
  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
  programs.seahorse.enable = true;
  programs.firefox.enable = true;

  programs.neovim = {
    enable = true;
    defaultEditor = true;
  };

  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      ms-vscode-remote.remote-ssh
      ms-vscode-remote.remote-ssh-edit
      ms-vscode-remote.remote-containers
      ms-vscode.remote-explorer
      ms-azuretools.vscode-containers
      ms-vscode.hexeditor
      ms-vscode.cpptools-extension-pack

      vscodevim.vim
      yzhang.markdown-all-in-one
      jnoortheen.nix-ide
      arrterian.nix-env-selector

      github.copilot
      github.copilot-chat
      pkgs.vscode-marketplace.openai.chatgpt
      pkgs.vscode-marketplace.continue.continue
      kilocode.kilo-code
      pkgs.vscode-marketplace.saoudrizwan.claude-dev
      pkgs.vscode-marketplace.warm3snow.vscode-ollama
    ];
  };

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [];
}
