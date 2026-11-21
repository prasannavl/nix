{
  fetchurl,
  lib,
  python3Packages,
}: let
  source = (import ./sources.nix).mcp-for-blender;
in
  python3Packages.buildPythonApplication {
    pname = source.package;
    version = source.version;

    src = fetchurl {
      url = source.url;
      hash = source.hash;
    };

    pyproject = true;
    build-system = [python3Packages.setuptools];

    dependencies = [
      python3Packages.httpx
      python3Packages.mcp
    ];

    # The Blender addon ships inside the wheel (`blender_mcp/bundled/addon.py`)
    # and is installed into Blender by `mcp-for-blender setup`.

    meta = {
      description = "Blender integration MCP server (third-party, unofficial)";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.mit;
      mainProgram = "mcp-for-blender";
      platforms = lib.platforms.all;
    };
  }
