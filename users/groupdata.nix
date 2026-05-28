{
  users,
  userLib ? import ../lib/flake/stack/user-data-lib.nix,
  ...
}: {
  users = {
    name = "users";
    users =
      userLib.userFilter {
        isActive = true;
        hasMail = true;
        id = true;
      }
      users;
  };
}
