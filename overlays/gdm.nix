_: _final: prev: {
  gdm = prev.gdm.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        if grep -q '#define REGISTER_SESSION_TIMEOUT 10' common/gdm-common.h; then
          substituteInPlace common/gdm-common.h \
            --replace-fail '#define REGISTER_SESSION_TIMEOUT 10' '#define REGISTER_SESSION_TIMEOUT 3'
        elif grep -q '#define REGISTER_DISPLAY_TIMEOUT 10' common/gdm-common.h; then
          substituteInPlace common/gdm-common.h \
            --replace-fail '#define REGISTER_DISPLAY_TIMEOUT 10' '#define REGISTER_DISPLAY_TIMEOUT 3'
        else
          echo "Could not find GDM register timeout constant to patch" >&2
          exit 1
        fi
      '';
  });
}
