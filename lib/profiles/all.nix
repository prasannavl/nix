{...}: {
  imports = [
    ./core.nix
    ./desktop-gnome.nix
    ../gpg.nix
    ../incus.nix
    ../neovim.nix
    ../virtualization.nix
    ../nix-ld.nix
    ../vscode.nix
  ];

  programs.mtr.enable = true;
  programs.seahorse.enable = true;
  programs.firefox.enable = true;
}
