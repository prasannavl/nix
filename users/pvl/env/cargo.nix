{
  nixos = _: {};

  home = _: {
    home.sessionPath = [
      "$HOME/.cargo/bin"
    ];
  };
}
