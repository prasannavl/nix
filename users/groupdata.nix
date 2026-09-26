{
  users,
  accountsLib ? import ../lib/flake/accounts/lib.nix,
  ...
}: {
  users = {
    name = "users";
    users =
      accountsLib.userFilter {
        isActive = true;
        hasMail = true;
        id = true;
      }
      users;
  };
}
