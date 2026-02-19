{
  nixos = {...}: {};

  home = {
    ...
  }: {
    programs.fzf.enable = true;
  };
}
