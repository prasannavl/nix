{...}: {
  security.sudo = {
    enable = true;
    configFile = ''
      # 12-hour sudo timeout (value is minutes).
      Defaults timestamp_timeout=720
    '';
  };
}
