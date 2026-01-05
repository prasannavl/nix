{ config, pkgs, ... }:
{
  programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };
  programs.seahorse.enable = true;
  programs.firefox.enable = true;
  
  programs.vscode = {
    enable = true;
    extensions = with pkgs.vscode-extensions; [
      github.copilot
      github.copilot-chat
      # openai.chatgpt
      vscodevim.vim
      yzhang.markdown-all-in-one
      jnoortheen.nix-ide
      arrterian.nix-env-selector
    ];
  };
  
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [];
}
