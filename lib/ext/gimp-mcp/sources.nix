{
  gimp-mcp = {
    # Release tags pair the MCP server with its GIMP plugin. No package-local
    # updater, so the generic reporter tracks tags read-only.
    kind = "github-tags";
    owner = "gimp-mcp";
    repo = "gimp-mcp";
    tagPrefix = "v";
    version = "0.6.0";
    rev = "f25a74a5ced0586adb49d64692f4f465a391404c";
    hash = "sha256-CW/9zrJCRI46f6q9XGEl3ijhzM7+y0/kJTisO+BrHeA=";
  };
}
