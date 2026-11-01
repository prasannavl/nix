{
  fetchurl,
  lib,
  python3Packages,
}: let
  source = (import ./sources.nix).office-powerpoint-mcp-server;
in
  python3Packages.buildPythonApplication {
    pname = source.package;
    version = source.version;

    src = fetchurl {
      url = source.url;
      hash = source.hash;
    };

    pyproject = true;
    build-system = [python3Packages.hatchling];

    dependencies = [
      python3Packages.fonttools
      python3Packages.mcp
      python3Packages.pillow
      python3Packages.python-pptx
    ];

    meta = {
      description = "MCP server for creating and editing PowerPoint decks";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "ppt_mcp_server";
      platforms = lib.platforms.all;
    };
  }
