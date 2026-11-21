{ab, ...}: {
  imports = [ab.system.modules.sudo];
  security.sudo.configFile = "Defaults timestamp_timeout=720";
}
