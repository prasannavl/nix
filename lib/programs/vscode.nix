{pkgs, ...}: {
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

      github.copilot-chat
      pkgs.vscode-marketplace.openai.chatgpt
      pkgs.vscode-marketplace.continue.continue
    ];
  };
}
