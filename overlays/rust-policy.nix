# Abird identity policy: the 24-member native/WASM/desktop union is not qualified.
# Keep per-package Cargo features and native requirements until the Design L
# platform/native-input and cost gates pass. The generic helper and explicit
# per-package useWorkspaceDeps override remain available for isolated fixtures.
_final: _prev: {
  rustWorkspaceDeps = false;
}
