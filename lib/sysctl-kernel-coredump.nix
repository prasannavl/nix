{...}: {
  boot.kernel.sysctl = {
    # core dumps
    "kernel.core_uses_pid" = 1;
  };
}
