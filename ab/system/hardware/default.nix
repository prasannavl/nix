{...}: {
  services = {
    # For SSDs, we want to pass them through VMs to the underlying host
    # for efficient TRIMs.
    fstrim.enable = true;
  };
}
