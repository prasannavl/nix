{pkgs}:
pkgs.runCommand "lint-root-flake-test" {
  nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.git pkgs.gnused pkgs.jq];
} ''
  sed '$d' ${../../scripts/lint.sh} > lint-functions.sh
  source ./lint-functions.sh
  REPO_ROOT="$PWD/repo"
  mkdir "$REPO_ROOT"
  trace="$PWD/trace"
  nix() {
    case "$1 $2" in
      'flake metadata')
        [ "$failure" != metadata ] || return 17
        printf '%s\n' '{"locked":{"type":"git","url":"file:///fixture/repo","narHash":"sha256-fixture","dirtyRev":"fixture-dirty","__final":true}}'
        ;;
      'eval --json')
        [ "$failure" != indexes ] || return 18
        printf '%s\n' '{"hosts":["alpha","line\nbreak"],"checkSystems":["test-a","test-b"]}'
        ;;
      'flake check')
        [ "$3" = --all-systems ] || return 21
        [ "$4" = --no-build ] || return 21
        local dir="$5" selection
        selection="$(jq -c . "$dir/selection.json")" || return 21
        grep -F 'inputs.repository.narHash = "sha256-fixture";' "$dir/flake.nix" || return 21
        ! grep -E 'inputs.repository.(dirtyRev|__final)' "$dir/flake.nix" || return 21
        printf '%s\n' "$selection" >> "$trace"
        [ "$selection" != "$failure" ] || return 19
        ;;
      *) return 20 ;;
    esac
  }
  for failure in none metadata indexes '{"host":"alpha"}' '{"system":"test-a"}' null; do
    : > "$trace"
    if run_full_root_flake_check --no-build; then
      status=0
    else
      status=$?
    fi
    case "$failure" in
      none)
        [ "$status" = 0 ]
        jq -e -s '. == [{"host":"alpha"},{"host":"line\nbreak"},{"system":"test-a"},{"system":"test-b"},null]' "$trace"
        ;;
      metadata) [ "$status" = 17 ]; [ ! -s "$trace" ] ;;
      indexes) [ "$status" = 18 ]; [ ! -s "$trace" ] ;;
      '{"host":"alpha"}') [ "$status" = 19 ]; [ "$(wc -l < "$trace")" = 1 ] ;;
      '{"system":"test-a"}') [ "$status" = 19 ]; [ "$(wc -l < "$trace")" = 3 ] ;;
      null) [ "$status" = 19 ]; [ "$(wc -l < "$trace")" = 5 ] ;;
    esac
    [ -z "$(find "$REPO_ROOT/tmp" -mindepth 1 -print -quit)" ]
  done

  foreign="$PWD/foreign"
  git init --quiet --template= "$foreign"
  printf 'sentinel\n' > "$foreign/sentinel"
  printf 'foreign flake\n' > "$foreign/flake.nix"
  printf 'foreign selection\n' > "$foreign/selection.json"
  git -C "$foreign" add sentinel
  cp "$foreign/.git/index" foreign-index
  cp "$foreign/.git/index" expected-index
  cp "$foreign/.git/config" expected-config
  export GIT_DIR="$foreign/.git" GIT_COMMON_DIR="$foreign/.git" GIT_WORK_TREE="$foreign"
  export GIT_INDEX_FILE="$PWD/foreign-index" GIT_OBJECT_DIRECTORY="$foreign/.git/objects"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0="$foreign"
  failure=none
  : > "$trace"
  run_full_root_flake_check --no-build
  cmp expected-index foreign-index
  cmp expected-index "$foreign/.git/index"
  cmp expected-config "$foreign/.git/config"
  [ "$GIT_DIR" = "$foreign/.git" ]
  [ "$GIT_INDEX_FILE" = "$PWD/foreign-index" ]
  [ "$GIT_CONFIG_COUNT" = 1 ]
  jq -e -s 'length == 5' "$trace"
  [ -z "$(find "$REPO_ROOT/tmp" -mindepth 1 -print -quit)" ]
  touch "$out"
''
