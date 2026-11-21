_: _final: prev: {
  supergfxctl = prev.supergfxctl.overrideAttrs (old: {
    postInstall =
      (old.postInstall or "")
      + ''
        dbusPolicy=$out/share/dbus-1/system.d/org.supergfxctl.Daemon.conf
        grep -q 'group="sudo"' "$dbusPolicy"
        sed -i '/<policy group="sudo">/,/<\/policy>/d' "$dbusPolicy"
      '';
  });
}
