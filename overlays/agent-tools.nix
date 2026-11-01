# Agent-facing tooling that follows upstream: browser and desktop drivers and
# agent workspaces. These units live in `lib/ext/` because the repository does
# not own their shape (no patches, no vendored locks). Repo-managed agent
# tooling stays registered in `pkgs/manifest.nix` and is exposed by
# `overlays/pkgs.nix` instead.
final: _prev: {
  agent-workspace-linux = final.callPackage ../lib/ext/agent-workspace-linux {};
  bladebro = final.callPackage ../lib/ext/bladebro {};
}
