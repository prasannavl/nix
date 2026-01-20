{...}: {
  imports = [
    ./desktop-gnome.nix
    ../programs/vscode.nix
    ../programs/incus.nix
    ../virtualization.nix
  ];
}
