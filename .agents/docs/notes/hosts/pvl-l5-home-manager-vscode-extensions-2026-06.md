# Home Manager VS Code extensions ownership conflict

On 2026-06-26, deploying a staged VS Code Home Manager change failed on `pvl-x2`
and then caused `pvl-l5` rollback failures. The staged change in
`users/pvl/vscode/default.nix` set:

```nix
programs.vscode.mutableExtensionsDir = false;
```

That makes Home Manager own the top-level `home.file.".vscode/extensions"` path
from the generated extension store path. Its evaluated `force` is `false`.

## pvl-x2 failure

`pvl-x2` still had an existing mutable `/home/pvl/.vscode/extensions` directory,
so Home Manager failed during `checkLinkTargets`:

```text
Set 'force = true' on the related file options to forcefully overwrite the files below. eg. 'xdg.configFile."mimeapps.list".force = true'
Existing file '/home/pvl/.vscode/extensions' would be clobbered
```

The `mimeapps.list` text was only Home Manager's example. The current host
evaluations have both mime-apps force flags enabled:

```nix
home-manager.users.pvl.xdg.configFile."mimeapps.list".force = true;
home-manager.users.pvl.xdg.dataFile."applications/mimeapps.list".force = true;
```

## pvl-l5 rollback failure

`pvl-l5` initially switched into the new generation successfully and replaced
`/home/pvl/.vscode/extensions` with a symlink to the generated Home Manager
extension tree:

```text
/home/pvl/.vscode/extensions -> /nix/store/...-home-manager-files/.vscode/extensions
```

After `pvl-x2` failed, nixbot rolled `pvl-l5` back to the previous generation.
That rollback generation still expected to manage per-extension links under
`~/.vscode/extensions`. Because the parent path was now a symlink into
`/nix/store`, link creation followed the symlink and failed on the read-only
store:

```text
ln: failed to create symbolic link '/home/pvl/.vscode/extensions/golang.go': Read-only file system
```

## Interpretation

This is an ownership-shape migration, not a missing mime-apps force setting. The
staged `mutableExtensionsDir = false` change flips VS Code extensions from a
mutable directory with per-extension links to a top-level immutable symlink.

That shape change is not rollback-safe across hosts unless the migration also
handles existing mutable directories on every target and handles rollback from
the top-level symlink back to the old per-extension layout.

For future failures, check the `Existing file ...` line first; the preceding
`mimeapps.list` path may be just an example, not the file that needs attention.

## Local desktop versus Remote SSH extensions

On 2026-07-24, `pvl-l5` evaluated 26 extension entries under
`programs.vscode.profiles.default.extensions`, representing 25 unique extensions
because `ms-azuretools.vscode-containers` appears twice. Home Manager had
populated the immutable `/home/pvl/.vscode/extensions` tree, and the local
desktop VS Code was actively running extensions from it.

A concurrent Remote SSH session still reported no installed extensions. Remote
SSH uses `/home/pvl/.vscode-server/extensions`, not the desktop
`/home/pvl/.vscode/extensions` tree; its `extensions.json` was empty. The Home
Manager declaration therefore fully owns the local desktop installation but does
not provision the separate VS Code Server extension host.

Future remote provisioning should distinguish client/UI extensions from
workspace extensions. Suitable approaches include declaring
`remote.SSH.defaultExtensions` on the connecting client or introducing an
explicit remote-server extension-management boundary; do not assume the local
immutable extension tree is consumed by VS Code Server.
