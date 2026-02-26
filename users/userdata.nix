{
  nixbot = rec {
    username = "nixbot";
    uid = 10000;
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOVbOBRhD/RoCDHVxDGOxrTKcT5AkCBKYlHMU0q1brJP"
    ];
    bastionSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBC+WylBLVXmMjiZ51/5SfT2c4gU729wEL9C7DWarW7e nixbot-bastion-github-actions"
    ];

    # Backward-compatible aliases for modules/scripts still reading singular attrs.
    sshKey = builtins.head sshKeys;
    bastionSshKey = builtins.head bastionSshKeys;
  };
  pvl = {
    username = "pvl";
    uid = 1000;
    name = "Prasanna Loganathar";
    email = "pvl@prasannavl.com";
    sshKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIAAsB0nJcxF0wjuzXK0VTF1jbQbT24C1MM8NesCuwBb";
    hashedPassword = "$y$j9T$9OEq0GBdps2U6P3EwZ2MH0$dTky3GP2ZSSIYGIpdeM8YXBo10LqOJVtycc5XR.ncw3";
  };
}
