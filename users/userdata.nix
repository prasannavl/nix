{
  nixbot = rec {
    username = "nixbot";
    uid = 10000;
    sshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILcebdSP8tXYbp+vX0VM/cBFFh8sjLQOcf1futIV8sWD nixbot-deploy-2026q1"
    ];
    bastionSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF221ghIGV2YzknYaDxSeo0LAD+8tNd4xUz0UMwsUdsc nixbot-bastion-github-actions-2026q1"
    ];
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
