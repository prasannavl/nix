{
  addressBases = {
    ipv4 = "10.10";
    ipv6 = "fd42:ab1d:ab1d";
  };

  fabrics = {
    abird-platform = 0;
    abird-gondor = 30;
    abird = 100;
    abird-dev = 220;
  };

  endpoints = {
    nest = 10;
    proxy = 20;
    ci = 80;
  };

  access = {
    abird-to-platform-ci = {
      from.fabrics = ["abird" "abird-gondor"];
      to = {
        fabric = "abird-platform";
        endpoint = "ci";
      };
      tcp = [22 5000];
    };
    abird-dev-to-platform-ci = {
      from.fabrics = ["abird-dev"];
      to = {
        fabric = "abird-platform";
        endpoint = "ci";
      };
      tcp = [22 5000];
    };
    platform-to-gondor-proxy-dns = {
      from.fabrics = ["abird-platform"];
      to = {
        fabric = "abird-gondor";
        endpoint = "proxy";
      };
      tcp = [53];
      udp = [53];
    };
    platform-to-gondor-ci-cache = {
      from.fabrics = ["abird-platform"];
      to = {
        fabric = "abird-gondor";
        endpoint = "ci";
      };
      tcp = [5000];
    };
    gondor-proxy-to-platform-nest-oauth-bridge = {
      from = {
        fabrics = ["abird-gondor"];
        endpoint = "proxy";
      };
      to = {
        fabric = "abird-platform";
        endpoint = "nest";
      };
      tcp = [18444];
    };
    platform-nest-to-abird-dev-ssh = {
      from = {
        fabrics = ["abird-platform"];
        endpoint = "nest";
      };
      to.fabric = "abird-dev";
      tcp = [22];
    };
  };
}
