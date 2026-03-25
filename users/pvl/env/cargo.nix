{
  nixos = {...}: {};

  home = {...}: {
    home.sessionPath = [
      "$HOME/.cargo/bin"
    ];
  };
}
