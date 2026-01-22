{lib, ...}: {
  programs.gnupg.agent = {
    enable = true;
    # This may be disabled if using gcr-ssh-agent.
    enableSSHSupport = lib.mkDefault true;
  };
}
