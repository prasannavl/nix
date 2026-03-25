{...}: {
  security.sudo = {
    enable = true;
    configFile = ''
      # Add this line to set timeout to 10 minutes (e.g.)
      Defaults timestamp_timeout=720
    '';
  };
}
