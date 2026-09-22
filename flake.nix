{
  description = "NixOS Config";

  inputs = {
    systems.url = "github:nix-systems/default";

    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };

    # Nixpkgs channels.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
    unstable.url = "github:nixos/nixpkgs/nixos-unstable";

    # Inputs that follow the selected host profile.
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        systems.follows = "systems";
      };
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    vscode-ext = {
      url = "github:nix-community/nix-vscode-extensions";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    antigravity = {
      url = "github:jacopone/antigravity-nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    p7-borders = {
      url = "github:prasannavl/p7-borders-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    p7-cmds = {
      url = "github:prasannavl/p7-cmds-shell-extension";
      inputs.nixpkgs.follows = "nixpkgs";
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

    # Root package/tooling inputs.
    nixos-hardware = {
      url = "github:nixos/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    llm-agents = {
      url = "github:numtide/llm-agents.nix";
      inputs = {
        systems.follows = "systems";
        treefmt-nix.follows = "treefmt-nix";
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
  };

  outputs = inputs:
    (import ./lib/flake/root.nix {
      inherit inputs;
      # Repository composition manifest: every repository-specific fact about
      # the shared flake library is declared here and injected as arguments
      # (see .agents/docs/design-patterns/shared-test-areas.md).
      repoChecksFn = import ./lib/flake/repo-checks.nix;
      repoModules = import ./lib/stacks/modules.nix;
      repoRegistry = (import ./hosts/nixbot.nix).config.registries;
      # The full table is required: this assignment replaces the shared
      # default wholesale, so omitting an entry drops it from the profile.
      flakeProfileInputNames.default = {
        nixpkgs = "nixpkgs";
        homeManager = "home-manager";
        agenix = "agenix";
        disko = "disko";
        vscodeExt = "vscode-ext";
        antigravity = "antigravity";
        p7Borders = "p7-borders";
        p7Cmds = "p7-cmds";
        noctalia = "noctalia";
        llmAgents = "llm-agents";
      };
    }).outputs;
}
