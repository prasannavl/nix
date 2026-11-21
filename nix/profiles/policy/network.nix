{
  ab,
  lib,
  ...
}: {
  imports = [
    ab.system.modules.networkManaged
    ab.services.fail2banHelper.module
  ];
  services.resolved.settings.Resolve = {
    DNS = lib.mkDefault [
      "1.1.1.1#one.one.one.one"
      "1.0.0.1#one.one.one.one"
      "2606:4700:4700::1111#one.one.one.one"
      "2606:4700:4700::1001#one.one.one.one"
    ];
    FallbackDNS = lib.mkDefault [];
    Domains = lib.mkDefault ["~."];
    DNSOverTLS = lib.mkDefault true;
    DNSSEC = lib.mkDefault true;
  };
}
