# Agent-facing tooling that follows upstream: MCP servers, browser and desktop
# drivers, and agent workspaces. These units live in `lib/ext/` because the
# repository does not own their shape (no patches, no vendored locks).
# Repo-managed agent tooling (`gimp-mcp`, `mcpvault`) stays registered in
# `pkgs/manifest.nix` and is exposed by `overlays/pkgs.nix` instead.
final: _prev: {
  agent-workspace-linux = final.callPackage ../lib/ext/agent-workspace-linux {};
  bladebro = final.callPackage ../lib/ext/bladebro {};
  computer-use-linux = final.callPackage ../lib/ext/computer-use-linux {};
  mcp-for-blender = final.callPackage ../lib/ext/mcp-for-blender {};
  office-powerpoint-mcp-server = final.callPackage ../lib/ext/office-powerpoint-mcp-server {};
}
