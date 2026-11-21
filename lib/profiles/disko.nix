{ab, ...}: {
  imports = [
    (ab.system.storage.diskoModule {
      overridePathForHost = hostName: ../../hosts + "/${hostName}/installer-overrides.nix";
    })
  ];
}
