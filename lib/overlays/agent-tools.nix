# Agent-facing tooling that follows upstream: MCP servers, browser and desktop
# drivers, and agent workspaces. These units live in `lib/ext/` because the
# repository does not own their shape (no patches; locks only updater-generated).
# Repo-managed agent tooling stays registered in `pkgs/manifest.nix` and is
# exposed by `lib/overlays/pkgs.nix` instead.
final: _prev: {
  agent-workspace-linux = final.callPackage ../ext/agent-workspace-linux {};
  bladebro = final.callPackage ../ext/bladebro {};
  computer-use-linux = final.callPackage ../ext/computer-use-linux {};
  gimp-mcp = final.callPackage ../ext/gimp-mcp {};
  mcp-for-blender = final.callPackage ../ext/mcp-for-blender {};
  mcpvault = final.callPackage ../ext/mcpvault {};
  office-powerpoint-mcp-server = final.callPackage ../ext/office-powerpoint-mcp-server {};
}
