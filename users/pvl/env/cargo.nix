{
  nixos = _: {};

  home = {...}: {
    home.sessionPath = [
      "$HOME/.cargo/bin"
    ];
  };
}
