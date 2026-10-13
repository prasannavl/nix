# A real setup-hook registration: its output is written after the postInstall
# variable. Used only by the bounded native-context shell regression fixture.
# stdenv (or the isolated fixture driver) supplies out.
# shellcheck disable=SC2154
writeRustKnownArtifact() {
  case "${RUST_TEST_ARTIFACT:-clean}" in
    clean) ;;
    target) mkdir -p "$out/target" ;;
    target.tar.zst) touch "$out/target.tar.zst" ;;
    target.tar.zst.prev) ln -s missing "$out/target.tar.zst.prev" ;;
    *) return 1 ;;
  esac
}

postInstallHooks+=(writeRustKnownArtifact)
