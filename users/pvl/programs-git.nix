{userdata, ...}: {
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = userdata.name;
        email = userdata.email;
        signingKey = userdata.sshKey;
      };
      commit.gpgSign = true;
      gpg.format = "ssh";
      core.autocrlf = "input";

      grep = {
        extendRegexp = true;
        lineNumber = true;
      };

      merge.conflictstyle = "diff3";
      push.autoSetupRemote = true;

      alias = {
        l = "log --oneline";
        ll = "log --pretty=format:\"%h%x09%an%x09%ad%x09%s\"";
      };
    };

    lfs.enable = true;
    ignores = [
      ".DS_Store"
      "result"
    ];
  };
}
