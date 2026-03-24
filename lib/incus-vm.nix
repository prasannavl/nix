{
  hostName,
  tailscaleKey ? hostName,
}: {
  config,
  lib,
  ...
}:
{
  systemd.tmpfiles.rules = [
    # The state disk is mounted from the host at 0750 for security; fix
    # the in-container /var/lib to the standard 0755 so non-root services
    # (e.g. nixbot) can traverse it.
    "d /var/lib 0755 root root -"
    "d /var/lib/machine 0700 root root -"
  ];

  services.openssh.hostKeys = [
    {
      path = "/var/lib/machine/ssh_host_ed25519_key";
      type = "ed25519";
    }
    {
      path = "/var/lib/machine/ssh_host_rsa_key";
      type = "rsa";
      bits = 4096;
    }
  ];
}
// (
  let
    k =
      if tailscaleKey == null || tailscaleKey == ""
      then null
      else ../data/secrets + "/tailscale/${tailscaleKey}.key.age";
  in
    lib.mkIf (k != null && builtins.pathExists k) {
      age.secrets.tailscale-auth-key = {
        file = builtins.path {
          path = k;
          name = "tailscale-${tailscaleKey}-auth-key.age";
        };
      };

      services.tailscale = {
        authKeyFile = config.age.secrets.tailscale-auth-key.path;
        authKeyParameters = {
          ephemeral = false;
          preauthorized = true;
        };
        extraUpFlags = [
          "--advertise-tags=tag:vm"
        ];
      };
    }
)
