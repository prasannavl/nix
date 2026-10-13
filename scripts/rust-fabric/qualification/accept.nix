# Construction is cheap; realization requires separate native approval.
# Private implementation: default.nix supplies its actual constructed handles.
{
  pkgs,
  src,
  qualification,
}: let
  lib = pkgs.lib;
  archivePath = drv: "${drv}/target.tar.zst";
  baseHandles = qualification.baseHandles;
  memberLayer = qualification.consumers.member.passthru.memberLayer;
  allowedArchives = map archivePath (builtins.attrValues baseHandles ++ [memberLayer]);
  # Plain fixture-owned expected bytes are not compiler/base inputs.
  expectedOutput = src + "/expected-output.txt";
  expectedGuard =
    if ((builtins.readDir src)."expected-output.txt" or null) != "regular"
    then throw "rust-g4-qualification: fixture must supply regular expected-output.txt"
    else true;
  quote = lib.escapeShellArg;
  inspections = lib.concatStringsSep "\n" (map (dir: let
    base = baseHandles.${dir};
    parent = base.passthru.rustClosureBaseParent or null;
  in
    "inspect_root ${quote dir} ${quote (archivePath base)} "
    + quote (
      if parent == null
      then ""
      else archivePath parent
    ))
  qualification.memberDirs);
  # Validate synthetic effective-chain metadata, never qualify an artifact.
  # Native checks below measure actual immutable outputs, not this data.
  validArchivePath = value:
    builtins.isString value
    && lib.hasPrefix "/nix/store/" value
    && lib.hasSuffix "/target.tar.zst" value
    && !(lib.hasInfix "/../" value);
  validEntry = value:
    builtins.isString value
    && (let
      parts = lib.splitString "/" value;
      normalized = lib.concatStringsSep "/" (builtins.filter (part:
        part != "" && part != ".")
      parts);
    in
      value
      != ""
      && builtins.stringLength value <= 1024
      && builtins.match "[ -~]*" value != null
      && !lib.hasInfix "\\" value
      && !lib.hasPrefix "/" value
      && builtins.all (part:
        part != ".." && part != ".git" && !lib.hasSuffix ".key" part)
      parts
      && !lib.hasInfix "/data/secrets/" "/${normalized}/");
  fingerprintEntry = value:
    lib.hasInfix "/.fingerprint/" value && !lib.hasSuffix "/" value;
  validateArchiveMetadata = {
    archiveExists ? false,
    archiveBytes ? 0,
    entries ? [],
    chain ? [],
    previousArchive ? null,
    selectedParentArchive ? null,
    previousIsSymlink ? false,
  }:
    archiveExists
    == true
    && builtins.isInt archiveBytes
    && archiveBytes > 0
    && builtins.isList entries
    && entries != []
    && builtins.length entries <= 100000
    && builtins.all validEntry entries
    && builtins.any fingerprintEntry entries
    && builtins.isList chain
    && chain != []
    && builtins.length chain <= 64
    && builtins.all validArchivePath chain
    && builtins.length (lib.unique chain) == builtins.length chain
    && builtins.isBool previousIsSymlink
    && (
      if selectedParentArchive == null
      then previousArchive == null && !previousIsSymlink
      else
        validArchivePath selectedParentArchive
        && previousIsSymlink == true
        && previousArchive == selectedParentArchive
        && builtins.length chain > 1
        && builtins.elemAt chain 1 == selectedParentArchive
    );
  archiveChain =
    pkgs.runCommand "rust-g4-archive-chain-acceptance" {
      nativeBuildInputs = [pkgs.coreutils pkgs.gnutar pkgs.zstd pkgs.gawk];
    } ''
      set -Eeuo pipefail

      allowed_archive() {
        case "$1" in
          ${lib.concatStringsSep "|" (map quote allowedArchives)}) return 0 ;;
          *) echo "archive outside actual qualification handles: $1" >&2; return 1 ;;
        esac
      }

      inspect_root() {
        local name="$1" archive="$2" expected_parent="$3"
        local previous seen="|" depth=0 fingerprints=0 outputs=0 counts
        local fingerprint_count output_count
        if [[ -n "$expected_parent" ]]; then
          [[ -L "$archive.prev" ]]
          [[ "$(readlink "$archive.prev")" == "$expected_parent" ]]
        else
          [[ ! -e "$archive.prev" && ! -L "$archive.prev" ]]
        fi
        while [[ -n "$archive" ]]; do
          (( depth < 64 ))
          [[ "$seen" != *"|$archive|"* ]]
          seen="$seen$archive|"
          allowed_archive "$archive"
          [[ -f "$archive" && -s "$archive" && ! -L "$archive" ]]
          # List names only; never extract archives or read fingerprint payloads.
          # Count/byte/time caps fail closed, including truncated tar pipelines.
          counts="$(LC_ALL=C timeout 30 tar --quoting-style=escape --zstd -tf "$archive" |
            LC_ALL=C awk '
            {
              n++; bytes += length($0) + 1;
              if (n > 100000 || bytes > 8388608 || length($0) > 1024 ||
                  $0 == "" || $0 ~ /[^ -~]/ || index($0, "\\") || $0 ~ /^\//) exit 1;
              # Match the pure component policy, including normalized adjacency.
              count = split($0, parts, "/"); previous = "";
              for (i = 1; i <= count; i++) {
                part = parts[i];
                if (part == ".." || part == ".git" || part ~ /\.key$/) exit 1;
                if (part == "" || part == ".") continue;
                if (previous == "data" && part == "secrets") exit 1;
                previous = part;
              }
              if ($0 ~ /\/\.fingerprint\/.+/ && $0 !~ /\/$/) fingerprints++;
              if ($0 ~ /\/build\/[^/]+\/output$/) outputs++;
            }
            END { print fingerprints+0, outputs+0; }
          ')"
          read -r fingerprint_count output_count <<< "$counts"
          fingerprints=$((fingerprints + fingerprint_count))
          outputs=$((outputs + output_count))
          depth=$((depth + 1))
          previous=""
          if [[ -L "$archive.prev" ]]; then
            previous="$(readlink "$archive.prev")"
            allowed_archive "$previous"
            [[ -f "$previous" && -s "$previous" ]]
          else
            [[ ! -e "$archive.prev" ]]
          fi
          archive="$previous"
        done
        (( fingerprints > 0 ))
        printf '%s\t%d\t%d\t%d\n' "$name" "$depth" "$fingerprints" "$outputs" \
          >> "$out/archive-metadata.tsv"
      }

      main() {
        mkdir -p "$out"
        printf 'member\tarchive_depth\tfingerprint_names\tbuild_output_names\n' \
          > "$out/archive-metadata.tsv"
        ${inspections}
        inspect_root member-layer ${quote (archivePath memberLayer)} \
          ${quote (archivePath qualification.consumers.member.passthru.depsBase)}
        printf '%s\n' 'Observed actual archive existence, metadata names and selected parent links.' \
          'Cargo freshness and resolved units are not proved.' \
          'producer.qualified=false; producer.decision=not_proven' > "$out/scope.txt"
      }

      main
    '';
  semantic = builtins.seq expectedGuard (pkgs.runCommand "rust-g4-semantic-acceptance" {
      nativeBuildInputs = [pkgs.coreutils pkgs.diffutils];
    } ''
      set -Eeuo pipefail

      compare_consumer() {
        local route="$1" binary="$2"
        timeout 10 "$binary" > "$out/$route.stdout"
        cmp ${quote "${expectedOutput}"} "$out/$route.stdout"
      }

      main() {
        mkdir -p "$out"
        ${lib.concatStringsSep "\n" (map (route:
        "compare_consumer ${quote route} "
        + quote (lib.getExe qualification.consumers.${route}))
      ["baseline" "member"])}
        cmp "$out/baseline.stdout" "$out/member.stdout"
        printf '%s\n' 'Exact fixture stdout comparison only; no Cargo freshness claim.' \
          'producer.qualified=false; producer.decision=not_proven' > "$out/scope.txt"
      }

      main
    '');
in {
  validateArchiveMetadata = validateArchiveMetadata;
  acceptanceTargets = {inherit archiveChain semantic;};
  diagnostics = {
    status = "deferred-explicit-approval-required";
    archiveInspection = "bounded-read-only-target-metadata-listing";
    producer = {
      qualified = false;
      decision = "not_proven";
    };
  };
}
