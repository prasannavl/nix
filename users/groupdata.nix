{
  users,
  accountsLib ? (import ../ab).stack.accounts,
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
