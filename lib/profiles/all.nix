{...}: {
  imports = [
    ./desktop-gnome.nix
    ../virtualization.nix
    ../neovim.nix
    ../vscode.nix
    ../incus.nix
  ];
}
