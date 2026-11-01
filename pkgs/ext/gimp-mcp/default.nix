{
  fetchFromGitHub,
  lib,
  python3Packages,
}: let
  source = (import ./sources.nix).gimp-mcp;
in
  python3Packages.buildPythonApplication {
    pname = source.repo;
    version = source.version;

    src = fetchFromGitHub {
      owner = source.owner;
      repo = source.repo;
      rev = source.rev;
      hash = source.hash;
    };

    pyproject = true;
    build-system = [python3Packages.setuptools];

    # Upstream targets an older mcp SDK than the pinned nixpkgs one.
    patches = [./fix-fastmcp-instructions.patch];

    # `gimp_mcp_server` imports `mcp.server.fastmcp`; the standalone `fastmcp`
    # package is declared upstream as well, so keep both in the closure.
    dependencies = [
      python3Packages.fastmcp
      python3Packages.mcp
    ];

    # The GIMP-side plugin (GIMP 3.2+, `gi.repository.Gimp`) must be copied into
    # GIMP's plug-ins directory by hand; expose it for that step.
    postInstall = ''
      mkdir -p $out/share/gimp-mcp
      cp gimp-mcp-plugin.py GIMP_MCP_PROTOCOL.md $out/share/gimp-mcp/
    '';

    meta = {
      description = "GIMP MCP server for driving a running GIMP 3.2 session";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      # Upstream pyproject says MIT, but the shipped LICENSE is GPL-3.0.
      license = lib.licenses.gpl3Only;
      mainProgram = "gimp-mcp-server";
      platforms = lib.platforms.all;
    };
  }
