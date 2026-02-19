let
  m = import ./modules.nix;
in
import ../default.nix {
  modules = m.core ++ m.dev;
}
