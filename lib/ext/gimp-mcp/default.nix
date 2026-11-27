{
  fetchFromGitHub,
  lib,
  unstable,
}: let
  source = (import ./sources.nix).gimp-mcp;
  # Upstream requires the 1.x MCP SDK (`mcp>=1.28.1,<2`); unstable keeps that
  # line as `mcp_1` alongside the 2.x default.
  python3Packages = unstable.python3Packages;
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
    dependencies = [python3Packages.mcp_1];
    pythonImportsCheck = ["gimp_mcp_server"];

    # The GIMP-side plugin (GIMP 3.2+, `gi.repository.Gimp`) runs under GIMP's
    # Python. `gimp-mcp-server install-plugin` copies the packaged module; the
    # share/ copy is for manual installs. Mode 0644 keeps patchShebangs off its
    # `/usr/bin/env python3` line.
    postInstall = ''
      install -Dm0644 -t $out/share/gimp-mcp gimp-mcp-plugin.py GIMP_MCP_PROTOCOL.md
    '';

    meta = {
      description = "GIMP MCP server for driving a running GIMP 3.2 session";
      homepage = "https://github.com/${source.owner}/${source.repo}";
      license = lib.licenses.gpl3Plus;
      mainProgram = "gimp-mcp-server";
      platforms = lib.platforms.all;
    };
  }
