{...}: {
  boot.kernel.sysctl = {
    "vm.swappiness" = 5;
  };
}
