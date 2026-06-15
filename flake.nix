{
  description = "NixOS Config";

  inputs = {
    systems.url = "github:nix-systems/default";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    # Nixpkgs channels.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    nixpkgs-next.url = "github:nixos/nixpkgs/nixos-26.05";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Source inputs used by overlays.
    sway-git = {
      url = "github:swaywm/sway?ref=master";
      flake = false;
    };
    wlroots-git = {
      url = "git+https://gitlab.freedesktop.org/wlroots/wlroots?ref=master";
      flake = false;
    };
    xdg-desktop-portal-wlr-git = {
      url = "github:emersion/xdg-desktop-portal-wlr?ref=master";
      flake = false;
    };
    xdg-desktop-portal-git = {
      url = "github:flatpak/xdg-desktop-portal?ref=main";
      flake = false;
    };

    # Inputs that follow the selected host profile.
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager-next = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        systems.follows = "systems";
      };
    };
    agenix-next = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs-next";
        home-manager.follows = "home-manager-next";
        systems.follows = "systems";
      };
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko-next = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
    vscode-ext = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-ext-next = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
    antigravity = {
      url = "github:jacopone/antigravity-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    antigravity-next = {
      url = "github:jacopone/antigravity-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-next";
        flake-utils.follows = "flake-utils";
      };
    };
    p7-borders = {
      url = "github:prasannavl/p7-borders-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-borders-next = {
      url = "github:prasannavl/p7-borders-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
    p7-cmds = {
      url = "github:prasannavl/p7-cmds-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-cmds-next = {
      url = "github:prasannavl/p7-cmds-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell?ref=legacy-v4";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        noctalia-qs = {
          url = "github:noctalia-dev/noctalia-qs";
          inputs = {
            systems.follows = "systems";
            treefmt-nix = {
              follows = "treefmt-nix";
              inputs.nixpkgs.follows = "nixpkgs";
            };
          };
        };
      };
    };
    noctalia-next = {
      url = "github:noctalia-dev/noctalia-shell?ref=legacy-v4";
      inputs = {
        nixpkgs.follows = "nixpkgs-next";
        noctalia-qs = {
          url = "github:noctalia-dev/noctalia-qs";
          inputs = {
            systems.follows = "systems";
            treefmt-nix = {
              follows = "treefmt-nix-next";
              inputs.nixpkgs.follows = "nixpkgs-next";
            };
          };
        };
      };
    };

    # Root package/tooling inputs.
    nixos-hardware.url = "github:nixos/nixos-hardware";
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
        treefmt-nix.follows = "treefmt-nix";
      };
    };
    llm-agents-next = {
      url = "github:numtide/llm-agents.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs-next";
        systems.follows = "systems";
        treefmt-nix.follows = "treefmt-nix-next";
      };
    };
    nix-alien = {
      url = "github:thiagokokada/nix-alien";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    crane.url = "github:ipetkov/crane";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix-next = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs-next";
    };
  };

  outputs = inputs:
    (import ./lib/flake/root.nix {inputs = inputs;}).outputs;
}
