{
  pi-models-discovery = {
    kind = "npm";
    package = "pi-models-discovery";
    owner = "maplezzk";
    repo = "pi-extensions";
    version = "1.7.0";
    rev = "7a3fecaef8ce48f5d1b9426133d5a0c3c99bfd22";
    srcHash = "sha256-GWoz5Onq/7cBcLgv4Y91x81nddM0aeRNEHRFnGt1TVM=";
  };

  pi-session-manager = {
    kind = "npm";
    package = "pi-session-manager";
    version = "0.1.0";
    srcHash = "sha256-fOYQP9MgRiWQPkVqrgpiV4fhUoraqGc14wcINJo6GJU=";
  };

  pi-subagents = {
    kind = "npm";
    package = "@gotgenes/pi-subagents";
    version = "25.0.5";
    srcHash = "sha256-UhB8Lp7vE2PC7UCOvHkypPyWT0BdV70zLj3jR/r/hJo=";
  };

  pi-tps = {
    kind = "npm";
    package = "pi-tps";
    owner = "summertime-wu";
    repo = "pi-tps";
    version = "1.0.1";
    rev = "a769402bb27232a3875b9d9ec2df08a0c85d227c";
    srcHash = "sha256-3NqPujlpb2KRWehdK17k4YCP4G+eLCnP9EWZYM5IAEY=";
  };

  pi-web = {
    kind = "npm";
    package = "@agegr/pi-web";
    owner = "agegr";
    repo = "pi-web";
    version = "0.12.2";
    srcHash = "sha256-+px44RJG0bhVJ/EQXd8oMY2Rn2fkNU3/sXZhiCepp6A=";
    releaseHash = "sha256-3SLxCRZVFYie1Ux73KlGCACFpJt2xaKTXc8eAdxPFy4=";
    npmDepsHash = "sha256-lTmpcxjE+VXOn+DUgKNfjmklEUlPM6FDYrr2JPfBnjg=";
  };

  pi-diff = {
    kind = "npm";
    package = "@heyhuynhgiabuu/pi-diff";
    owner = "buddingnewinsights";
    repo = "pi-diff";
    version = "0.9.3";
    releaseHash = "sha256-T9Kv6h3HCo0LH3zQbPHt/p5AXzrm3F8YHTuKH2EL1qw=";
    npmDepsHash = "sha256-mJxQuoofQ+pqJb05lh8s/s4darGnrT7Or65Z2HqdkJ0=";
  };

  pi-mcp-adapter = {
    kind = "npm";
    package = "pi-mcp-adapter";
    owner = "nicobailon";
    repo = "pi-mcp-adapter";
    version = "7.0.0";
    srcHash = "sha256-LvZ/vyZ6+BjPkMoJUg78oveFoBAJarkQ6+d7RCL8wLk=";
    releaseHash = "sha256-x2qh8hFRg4agNOCyroyAxz/ny3iwCp5x4xsisn/TrKk=";
    npmDepsHash = "sha256-nstiJjuS/3uNTd+kalif334JVuU9iD3J/UK4m2xDDqA=";
  };

  pi-patty-bg-tasks = {
    kind = "npm";
    package = "pi-patty-bg-tasks";
    owner = "patty-io";
    repo = "pi-patty-bg-tasks";
    version = "1.1.6";
    srcHash = "sha256-B8LavEHyGf3vBjDmZ7gBKSJDzE/t1RvVuaYCY0NDqx8=";
  };

  pi-usage = {
    kind = "npm";
    package = "@narumitw/pi-usage";
    owner = "narumiruna";
    repo = "pi-extensions";
    version = "0.68.3";
    srcHash = "sha256-dWiPIYATmftTMRW8jSvTkjNXnNQG4iyTRqAq8YJua5s=";
    depsResolver = "registry";
    deps = {
      "@narumitw/pi-tui-kit" = {
        kind = "npm-dep";
        range = "^0.67.0";
        version = "0.67.0";
        srcHash = "sha256-sivOQPwgmqdZOJa5fwz71i3fjSz0k7zWvZVwJ7FFLYE=";
      };
      "diff" = {
        kind = "npm-dep";
        range = "9.0.0";
        version = "9.0.0";
        srcHash = "sha256-cW9eX7r0oy9cABMNiBQixDcPfGaUxLDRuiWioD7Hqrg=";
      };
      "grok-mermaid" = {
        kind = "npm-dep";
        range = "0.2.3";
        version = "0.2.3";
        srcHash = "sha256-tT9tKcotpywP98aI4H8AJZa6cikj9adGFZpialQ0Dxk=";
      };
      "highlight.js" = {
        kind = "npm-dep";
        range = "11.12.0";
        version = "11.12.0";
        srcHash = "sha256-fcEJdFLzFkMR1rlm9sPVCr6A8YhUgm6+JNlLjMIrHk0=";
      };
    };
  };

  pi-tool = {
    kind = "npm";
    package = "@narumitw/pi-tool";
    owner = "narumiruna";
    repo = "pi-extensions";
    version = "0.4.0";
    srcHash = "sha256-nx77WOA1YgfH6OL1rpWi4d+42yCBbc0XD2E55hquHhg=";
    depsResolver = "registry";
    deps = {
      "@narumitw/pi-tui-kit" = {
        kind = "npm-dep";
        range = "^0.60.0";
        version = "0.60.0";
        srcHash = "sha256-5Ur+CMeoEjI6TGZKnzNnlz87Bz934cLX0YOoFCa6HKA=";
      };
    };
  };

  pi-goal = {
    kind = "npm";
    package = "@narumitw/pi-goal";
    owner = "narumiruna";
    repo = "pi-extensions";
    version = "0.54.13";
    srcHash = "sha256-gC58I5R2J3JfXGhnsI6u4E0TBp8L10G5xDDrojMDRvU=";
    depsResolver = "registry";
    deps = {
      "@narumitw/pi-tui-kit" = {
        kind = "npm-dep";
        range = "^0.59.0";
        version = "0.59.0";
        srcHash = "sha256-dMzOHA7jxKShvU2okzNt7qRNm/5ONa+05ZkcfVTALbI=";
      };
    };
  };

  pi-wait = {
    kind = "npm";
    package = "pi-wait";
    owner = "brettinternet";
    repo = "pi-extensions";
    version = "0.1.5";
    srcHash = "sha256-75Akl6k4aQzGyrH+sRb2fP2vVtSJeTpiyx6JEUdLf1Y=";
  };

  pi-loop = {
    kind = "npm";
    package = "@brettinternet/pi-loop";
    owner = "brettinternet";
    repo = "pi-extensions";
    version = "0.1.8";
    srcHash = "sha256-6lvBJyZGQLvtsKjhd4qxwWo4RqWGU0XhVU1NNLD+noM=";
  };

  pi-until = {
    kind = "npm";
    package = "pi-until";
    owner = "brettinternet";
    repo = "pi-extensions";
    version = "0.1.6";
    srcHash = "sha256-aThK9P/MaGRTNnkU52TvKFCjvT268Olr9k1P9wUbNAE=";
    depsResolver = "registry";
    deps = {
      "xstate" = {
        kind = "npm-dep";
        range = "5.33.3";
        version = "5.33.3";
        srcHash = "sha256-I3ox7IW8PQCyWHi0p4MDo+4up/7Rlst94/jkRpHOoAc=";
      };
    };
  };

  pi-notify = {
    kind = "npm";
    package = "@narumitw/pi-notify";
    owner = "narumiruna";
    repo = "pi-extensions";
    version = "0.4.1";
    srcHash = "sha256-V+RUrT2kN64agmEncL112Zq1bO4ltqMD+PaxlVVNns8=";
    depsResolver = "registry";
    deps = {
      "@narumitw/pi-tui-kit" = {
        kind = "npm-dep";
        range = "^0.65.6";
        version = "0.65.6";
        srcHash = "sha256-bNL0qOxPeNiDFN4jWKkxVpNTK3eh1DHUO3SPXDzm6+s=";
      };
    };
  };

  pi-openai-toolkit = {
    kind = "npm";
    package = "pi-openai-toolkit";
    owner = "awoaCrim";
    repo = "pi-openai-toolkit";
    version = "0.24.1";
    srcHash = "sha256-mZGINLzw3PRBsyoObX9SxnDzL6IOXhSYxG7SbsVjnJk=";
  };

  pi-total-recall = {
    kind = "npm";
    package = "pi-total-recall";
    owner = "samfoy";
    repo = "pi-total-recall";
    version = "1.9.1";
    srcHash = "sha256-qFfpzYav7LzsaZccBCAo/5EYsBXhJdajVwhlqh1dPHQ=";
  };

  rpiv-voice = {
    kind = "npm";
    package = "@juicesharp/rpiv-voice";
    owner = "juicesharp";
    repo = "rpiv-mono";
    version = "2.15.0";
    srcHash = "sha256-710aXXZCYmzkTprH9+4OGuQdGJFGsudH/rmc+NZRzYg=";
    depsResolver = "registry";
    deps = {
      "@decibri/decibri-linux-x64-gnu" = {
        kind = "npm-dep";
        range = "3.4.2";
        version = "3.4.2";
        srcHash = "sha256-lwo+o90s+NoWnciUwDkhMSy3Ix14T8tV4VZ7wzn/X3w=";
      };
      "@juicesharp/rpiv-config" = {
        kind = "npm-dep";
        range = "^2.15.0";
        version = "2.15.0";
        srcHash = "sha256-Z7QC661n6pbbY5J1/KuXqmagYMox6j96PYaX/bg4xRA=";
      };
      "decibri" = {
        kind = "npm-dep";
        range = "^3.4.0";
        version = "3.4.2";
        srcHash = "sha256-tfmbL30sQYBZeQBIpFGpoeVVk4dVDzV6uvjg/wNFIBQ=";
      };
      "sherpa-onnx-linux-x64" = {
        kind = "npm-dep";
        range = "^1.13.8";
        version = "1.13.8";
        srcHash = "sha256-k7U4/iFkNGZyRacNcsI1QFaKAQ+w+HnMeub53T8lC1c=";
      };
      "sherpa-onnx-node" = {
        kind = "npm-dep";
        range = "^1.13.0";
        version = "1.13.8";
        srcHash = "sha256-LMjPL7ng1JvcbJw+ZDzmNkd+LZQz/552U+P9s+8PM00=";
      };
    };
  };

  rpiv-todo = {
    kind = "npm";
    package = "@juicesharp/rpiv-todo";
    owner = "juicesharp";
    repo = "rpiv-mono";
    version = "2.15.0";
    srcHash = "sha256-9/1DJUvVV6o75HCu6mFvRya5+dTFfGm/BPy20xGQvVY=";
    depsResolver = "registry";
    deps = {
      "@juicesharp/rpiv-config" = {
        kind = "npm-dep";
        range = "^2.15.0";
        version = "2.15.0";
        srcHash = "sha256-Z7QC661n6pbbY5J1/KuXqmagYMox6j96PYaX/bg4xRA=";
      };
    };
  };

  rpiv-btw = {
    kind = "npm";
    package = "@juicesharp/rpiv-btw";
    owner = "juicesharp";
    repo = "rpiv-mono";
    version = "2.15.0";
    srcHash = "sha256-42hv077U5//X9KnShuNSql1oo42aHczzQboYWp2BUko=";
  };

  rpiv-advisor = {
    kind = "npm";
    package = "@juicesharp/rpiv-advisor";
    owner = "juicesharp";
    repo = "rpiv-mono";
    version = "2.15.0";
    srcHash = "sha256-AaH67C9qKXKfuMEIOlAUKzV7oXFpIgAmqbYGM45+Et4=";
    depsResolver = "registry";
    deps = {
      "@juicesharp/rpiv-config" = {
        kind = "npm-dep";
        range = "^2.15.0";
        version = "2.15.0";
        srcHash = "sha256-Z7QC661n6pbbY5J1/KuXqmagYMox6j96PYaX/bg4xRA=";
      };
    };
  };

  pi-stamp = {
    kind = "npm";
    package = "@narumitw/pi-stamp";
    owner = "narumiruna";
    repo = "pi-extensions";
    version = "0.53.0";
    srcHash = "sha256-oHgovJqc8Y4BxRyiNP+RXRm7cWFjDchljKzg5jQMjnQ=";
    depsResolver = "registry";
    deps = {
      "@narumitw/pi-tui-kit" = {
        kind = "npm-dep";
        range = "^0.59.0";
        version = "0.59.0";
        srcHash = "sha256-dMzOHA7jxKShvU2okzNt7qRNm/5ONa+05ZkcfVTALbI=";
      };
      "grok-mermaid" = {
        kind = "npm-dep";
        range = "0.2.3";
        version = "0.2.3";
        srcHash = "sha256-tT9tKcotpywP98aI4H8AJZa6cikj9adGFZpialQ0Dxk=";
      };
      "highlight.js" = {
        kind = "npm-dep";
        range = "11.12.0";
        version = "11.12.0";
        srcHash = "sha256-fcEJdFLzFkMR1rlm9sPVCr6A8YhUgm6+JNlLjMIrHk0=";
      };
    };
  };

  pi-anthropic-auth = {
    kind = "npm";
    package = "@gotgenes/pi-anthropic-auth";
    owner = "gotgenes";
    repo = "pi-anthropic-auth";
    version = "3.4.3";
    srcHash = "sha256-EVnHIONBOe/mHvOyAjnznJIK8mU2acavwDVKknv7JPo=";
  };
}
