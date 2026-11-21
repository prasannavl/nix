# Agent-facing tooling that follows upstream: MCP servers, browser and desktop
# drivers, and agent workspaces. These units live in `lib/ext/` because the
# repository does not own their shape (no patches, no vendored locks).
# Repo-managed agent tooling (`gimp-mcp`, `mcpvault`) stays registered in
# `pkgs/manifest.nix` and is exposed by `lib/overlays/pkgs.nix` instead.
final: _prev: {
  agent-workspace-linux = final.callPackage ../ext/agent-workspace-linux {};
  bladebro = final.callPackage ../ext/bladebro {};
  computer-use-linux = final.callPackage ../ext/computer-use-linux {};
  mcp-for-blender = final.callPackage ../ext/mcp-for-blender {};
  office-powerpoint-mcp-server = final.callPackage ../ext/office-powerpoint-mcp-server {};
}
