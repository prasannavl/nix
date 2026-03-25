{...}: {
  # Allow parent-host management over the Incus bridge while keeping
  # service exposure explicit at the guest boundary.
  networking.firewall.trustedInterfaces = ["incusbr0"];
}
