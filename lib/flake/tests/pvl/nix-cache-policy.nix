{pkgs}: let
  lib = pkgs.lib;
  module = import ../../../../hosts/pvl-x2/incus.nix {
    inherit lib;
    config = {};
    inputs.self.nixosImages.incus-lxc-base = "/fixture/image";
  };
  nest = module.services.incus-manager.abird-platform.instances.abird-nest;
  devices = nest.devices;
  rules = module.networking.nftables.tables.incusManagedFabricPolicy.content;
  contains = text: lib.hasInfix text rules;
  rulesFile = pkgs.writeText "pvl-fabric-rules.nft" rules;
  caches = (import ../../../../config).nix;
  local = (import ../../nix-cache-policy.nix).forHost {
    policy = caches;
    host = "pvl-x2";
  };
in {
  pvl-nix-cache-policy = assert builtins.all (a: a.assertion) module.assertions;
  assert devices.parent-cache-ipv4.type == "proxy";
  assert devices.parent-cache-ipv4.extraProperties
  == {
    bind = "instance";
    connect = "tcp:127.0.0.1:5000";
    listen = "tcp:10.10.0.10:5000";
  };
  assert !(devices ? parent-cache-ipv6);
  assert (nest.reconcilePolicy or "auto") == "auto";
  assert local.substituters == [];
  assert builtins.length (builtins.filter (line: lib.hasInfix "dport 5000 accept" line && lib.hasInfix "-> abird-platform" line) (lib.splitString "\n" rules)) == 2;
  assert contains "ip saddr 10.10.0.80 ip daddr 10.10.30.0/24 tcp dport 22 accept";
  assert contains "ip6 saddr fd42:ab1d:ab1d:0::80 ip6 daddr fd42:ab1d:ab1d:30::/64 tcp dport 22 accept";
  assert contains "ip saddr 10.10.0.80 ip daddr 10.10.20.20 tcp dport 22 accept";
  assert contains "ip6 saddr fd42:ab1d:ab1d:0::80 ip6 daddr fd42:36e5:81cf:b409::20 tcp dport 22 accept";
  assert contains "ip saddr 10.10.0.80 ip daddr 10.10.0.10 tcp dport 5000 accept";
  assert contains "ip6 saddr fd42:ab1d:ab1d:0::80 ip6 daddr fd42:ab1d:ab1d:0::10 tcp dport 5000 accept";
  assert contains "ip daddr 10.10.0.80 tcp dport { 22, 5000 } accept";
  assert contains "ip6 daddr fd42:ab1d:ab1d:0::80 tcp dport { 22, 5000 } accept";
  assert contains ''drop comment "deny abird-platform -> host"'';
  assert contains ''drop comment "deny abird-gondor -> host"'';
  assert contains ''drop comment "deny abird-platform -> default"'';
  assert !(contains "ip daddr 10.10.30.80 tcp dport 5000 accept");
    pkgs.runCommand "pvl-nix-cache-policy-test" {nativeBuildInputs = [pkgs.python3];} ''
      python - ${rulesFile} <<'PY'
      import collections
      import re
      import sys

      actual = []
      for line in open(sys.argv[1]):
          label = re.search(r'accept comment "allow (abird[^ ]*) -> (abird[^\"]*|default)"', line)
          if not label:
              continue
          sources = re.findall(r'\b(ip6?) saddr ([^ ]+)', line)
          destinations = re.findall(r'\b(ip6?) daddr ([^ !=]+)', line)
          family, destination = destinations[-1]
          protocol, ports = re.search(r'(tcp|udp) dport (.*?) accept', line).groups()
          actual.append((*label.groups(), family, sources[-1][1] if sources else None,
                         destination, protocol, tuple(map(int, re.findall(r'\d+', ports)))))

      def addr(family, subnet, host):
          if family == 'ip':
              return f'10.10.{subnet}.{host}' if host else f'10.10.{subnet}.0/24'
          return f'fd42:ab1d:ab1d:{subnet}::{host}' if host else f'fd42:ab1d:ab1d:{subnet}::/64'

      expected = []
      for family in ('ip', 'ip6'):
          ci, nest = addr(family, 0, 80), addr(family, 0, 10)
          for source in ('abird', 'abird-gondor', 'abird-dev'):
              expected.append((source, 'abird-platform', family,
                               addr(family, 30, 0) if source == 'abird-gondor' else None,
                               ci, 'tcp', (22, 5000)))
          expected.append(('abird-gondor', 'abird-platform', family, addr(family, 30, 20), nest, 'tcp', (18444,)))
          for destination, subnet in (('abird', 100), ('abird-gondor', 30), ('abird-dev', 220)):
              expected.append(('abird-platform', destination, family, ci, addr(family, subnet, 0), 'tcp', (22,)))
          expected.append(('abird-platform', 'abird-dev', family, nest, addr(family, 220, 0), 'tcp', (22,)))
          expected.append(('abird-platform', 'abird-platform', family, ci, nest, 'tcp', (5000,)))
          for protocol in ('tcp', 'udp'):
              expected.append(('abird-platform', 'abird-gondor', family, None, addr(family, 30, 20), protocol, (53,)))
          parent = '10.10.20.20' if family == 'ip' else 'fd42:36e5:81cf:b409::20'
          expected.append(('abird-platform', 'default', family, ci, parent, 'tcp', (22,)))
      assert collections.Counter(actual) == collections.Counter(expected), (actual, expected)
      print('Complete dual-family fabric admission matrix matches')
      PY
      touch "$out"
    '';
}
