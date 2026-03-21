#!/usr/bin/env bash
set -Eeuo pipefail

##### Nixbot Deploy #####

RUNTIME_SHELL_FLAG="${NIXBOT_DEPLOY_IN_NIX_SHELL:-0}"

readonly -a NIXBOT_RUNTIME_INSTALLABLES=(
  nixpkgs#age
  nixpkgs#git
  nixpkgs#jq
  nixpkgs#nixos-rebuild
  nixpkgs#openssh
  nixpkgs#opentofu
)
readonly -a NIXBOT_RUNTIME_COMMANDS=(
  nix
  age
  git
  jq
  nixos-rebuild
  ssh
  scp
  ssh-keygen
  tofu
)

usage() {
  cat <<'USAGE'
Usage:
  scripts/nixbot-deploy.sh [--ensure-deps] [--sha <commit>] [--hosts "host1,host2|all"] [--action all|build|deploy|tf|tf-dns|tf-platform|tf-apps|check-bootstrap] [--goal <goal>] [--build-host <local|target|host>] [--build-jobs <n>] [--deploy-jobs <n>] [--force] [--bootstrap] [--bastion-first] [--dry] [--no-rollback] [--prefix-host-logs] [--log-format <auto|gh|plain>] [--user <name>] [--ssh-key <path>] [--known-hosts <contents>] [--config <path>] [--age-key-file <path>] [--discover-keys[=auto|on|off]] [--repo-url <url>] [--repo-path <path>] [--use-repo-script] [--bastion-check-ssh-key-path <path>] [--bastion-trigger] [--bastion-host <host>] [--bastion-user <user>] [--bastion-ssh-key <key-content>] [--bastion-known-hosts <known-hosts-content>]
  scripts/nixbot-deploy.sh tofu <tofu-args...>

Core Workflow Options:
  --action         all|build|deploy|tf|tf-dns|tf-platform|tf-apps|check-bootstrap (default: all)
  --hosts          Comma/space-separated host list, or `all` (default: all)
  --goal           switch|boot|test|dry-activate (default: switch, deploy only)
  --build-jobs     Number of hosts to build in parallel (default: 1)
  --deploy-jobs    Number of hosts to deploy in parallel within a dependency wave (default: 1)
  --sha            Optional commit to checkout before running deploy workflow

Deploy Target/Auth Options:
  --user           Default deploy user override
  --ssh-key        SSH key path for deploy target auth (must be .age when explicitly set)
  --known-hosts    known_hosts override for all hosts
  --build-host     local|target|<ssh-host> (default: local)
  --config         Nix deploy config path (default: hosts/nixbot.nix)
  --age-key-file   Age/SSH identity file used for decrypting *.age secrets
  --discover-keys  Discover fallback decrypt identities (auto|on|off; default:
                   auto, which disables discovery when --age-key-file/AGE_KEY_FILE
                   is set explicitly)

Behavior Options:
  --ensure-deps    Re-exec into the runtime shell, verify required tools exist,
                   and exit without performing deploy work
  --force          Deploy even when built path matches remote /run/current-system
  --bastion-first  Prioritize bastion host first for build and deploy when selected
  --dry            Print deploy command instead of executing deploy step
  --no-rollback    Disable rollback of successful hosts when any deploy fails
  --prefix-host-logs Always prefix host log lines, even for single-job phases
  --log-format     auto|gh|plain (default: auto)

Bootstrap/Forced-Command Options:
  --bootstrap      Always use bootstrap user/key path for deploy/snapshot/rollback SSH target selection
  --bastion-check-ssh-key-path .age key path override for forced-command bootstrap checks

Remote Trigger Options:
  --bastion-trigger Trigger this script remotely on bastion via SSH and exit
  --bastion-host   Bastion hostname/IP used by --bastion-trigger (default: pvl-x2)
  --bastion-user   Bastion user used by --bastion-trigger (default: nixbot)
  --bastion-ssh-key Optional SSH private key content used by --bastion-trigger
  --bastion-known-hosts Optional known_hosts content used by --bastion-trigger

Repo Options:
  --repo-url       Repo URL used when a managed repo root must be cloned
  --repo-path      Persistent repo root used to sync origin/master and create per-run worktrees
  --use-repo-script Re-exec from the worktree copy of this script after worktree
                    setup; remains opt-in for intentionally executing fetched
                    script code

Environment (Core):
  DEPLOY_ACTION               Same as --action
  DEPLOY_HOSTS                Same as --hosts
  DEPLOY_GOAL                 Same as --goal
  DEPLOY_BUILD_JOBS           Same as --build-jobs
  DEPLOY_JOBS                 Same as --deploy-jobs
  DEPLOY_SHA                  Same as --sha

Environment (Deploy Target/Auth):
  DEPLOY_USER                 Same as --user
  DEPLOY_SSH_KEY              Same as --ssh-key
  DEPLOY_SSH_KNOWN_HOSTS      Same as --known-hosts
  DEPLOY_BUILD_HOST           Same as --build-host
  DEPLOY_CONFIG               Same as --config
  AGE_KEY_FILE                Same as --age-key-file

Environment (Behavior):
  DEPLOY_FORCE                Same as --force (bool: 1/0, true/false, yes/no)
  DEPLOY_BASTION_FIRST        Same as --bastion-first (bool)
  DEPLOY_DRY                  Same as --dry (bool)
  DEPLOY_NO_ROLLBACK          Same as --no-rollback (bool)
  DEPLOY_PREFIX_HOST_LOGS     Same as --prefix-host-logs (bool)
  DEPLOY_LOG_FORMAT           Same as --log-format
  DEPLOY_DISCOVER_KEYS        Same as --discover-keys (auto|on|off)

Environment (Bootstrap/Forced-Command):
  DEPLOY_BOOTSTRAP            Same as --bootstrap (bool)
  DEPLOY_BASTION_SSH_KEY_PATH Same as --bastion-check-ssh-key-path

Environment (Remote Trigger):
  DEPLOY_BASTION_TRIGGER      Same as --bastion-trigger (bool)
  DEPLOY_BASTION_HOST         Same as --bastion-host
  DEPLOY_BASTION_USER         Same as --bastion-user
  DEPLOY_BASTION_SSH_KEY      Same as --bastion-ssh-key
  DEPLOY_BASTION_KNOWN_HOSTS  Same as --bastion-known-hosts

Environment (Repo):
  DEPLOY_REPO_URL             Same as --repo-url
  DEPLOY_REPO_PATH            Same as --repo-path
  DEPLOY_USE_REPO_SCRIPT      Same as --use-repo-script (bool)

Environment (Terraform actions):
  R2_ACCOUNT_ID               Cloudflare account ID used for the shared R2 backend endpoint
  R2_STATE_BUCKET             R2 bucket name for Terraform state
  R2_ACCESS_KEY_ID            R2 access key ID
  R2_SECRET_ACCESS_KEY        R2 secret access key
  R2_STATE_KEY                Optional state object key override
  DEPLOY_TF_DIR               Optional single-project override; must match the requested phase suffix
  CLOUDFLARE_API_TOKEN        Provider-specific Cloudflare API token, required by Cloudflare projects

Runtime:
  The script always re-execs inside `nix shell` to provide a consistent
  toolchain: age, git, jq, nixos-rebuild, openssh, and opentofu.

Local tofu wrapper:
  `scripts/nixbot-deploy.sh tofu ...` runs Terraform locally via OpenTofu in the same runtime shell.
  For recognized tf/<provider>-<phase> projects (via -chdir or current directory),
  it auto-loads backend/provider runtime secrets and may append decrypted
  `-var-file` inputs for variable-aware commands (plan/apply/destroy/import/console)
  when no explicit `-var`/`-var-file` flags are provided.
  This wrapper mode is intentionally local-only and is not supported via bastion trigger.
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

##### Init Vars #####

resolve_ssh_tty_stdin_path() {
  if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
    printf '/dev/tty\n'
  else
    printf '/dev/null\n'
  fi
}

init_vars() {
  HOSTS_RAW="${DEPLOY_HOSTS:-all}"
  ACTION="${DEPLOY_ACTION:-all}"
  ENSURE_DEPS_ONLY=0
  HOST_ACTION=""
  GOAL="${DEPLOY_GOAL:-switch}"
  BUILD_HOST="${DEPLOY_BUILD_HOST:-local}"
  BUILD_JOBS="${DEPLOY_BUILD_JOBS:-1}"
  DEPLOY_PARALLEL_JOBS="${DEPLOY_JOBS:-1}"
  DEPLOY_IF_CHANGED=1
  TF_IF_CHANGED=1
  FORCE_REQUESTED=0
  FORCE_BOOTSTRAP_PATH=0
  PRIORITIZE_BASTION_FIRST=0
  DRY_RUN=0
  ROLLBACK_ON_FAILURE=1
  FORCE_PREFIX_HOST_LOGS=0
  PREFIX_HOST_LOGS_EXPLICIT=0
  LOG_FORMAT="${DEPLOY_LOG_FORMAT:-${NIXBOT_LOG_FORMAT:-auto}}"
  DEPLOY_CONFIG_PATH="${DEPLOY_CONFIG:-hosts/nixbot.nix}"
  SHA="${DEPLOY_SHA:-}"
  BASTION_TRIGGER=0
  BASTION_TRIGGER_HOST="${DEPLOY_BASTION_HOST:-pvl-x2}"
  BASTION_TRIGGER_USER="${DEPLOY_BASTION_USER:-nixbot}"
  BASTION_TRIGGER_SSH_KEY="${DEPLOY_BASTION_SSH_KEY:-}"
  BASTION_TRIGGER_KNOWN_HOSTS="${DEPLOY_BASTION_KNOWN_HOSTS:-}"
  BASTION_TRIGGER_SSH_OPTS=()
  AGE_DECRYPT_IDENTITY_FILE="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
  AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=0
  [ -n "${AGE_KEY_FILE:-}" ] && AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=1
  DISCOVER_DECRYPT_KEYS_MODE="${DEPLOY_DISCOVER_KEYS:-auto}"
  REEXEC_FROM_REPO=0
  REPO_PATH_EXPLICIT=0
  TF_WORK_DIR="${DEPLOY_TF_DIR:-}"
  TF_CHANGE_BASE_REF=""
  _NIXBOT_LOG_GROUP_DEPTH=0
  _NIXBOT_LOG_GROUP_SCOPE=""

  clear_run_summary_state

  DEPLOY_USER_OVERRIDE="${DEPLOY_USER:-}"
  DEPLOY_KEY_PATH_OVERRIDE="${DEPLOY_SSH_KEY:-}"
  DEPLOY_KNOWN_HOSTS_OVERRIDE="${DEPLOY_SSH_KNOWN_HOSTS:-}"
  DEPLOY_BASTION_KEY_PATH_OVERRIDE="${DEPLOY_BASTION_SSH_KEY_PATH:-}"
  DEPLOY_KEY_OVERRIDE_EXPLICIT=0

  set_discover_keys_mode "${DISCOVER_DECRYPT_KEYS_MODE}"

  if [ -n "${DEPLOY_SSH_KEY:-}" ]; then
    DEPLOY_KEY_OVERRIDE_EXPLICIT=1
  fi

  if parse_bool_env "${DEPLOY_FORCE:-0}"; then
    enable_force_mode
  fi
  if parse_bool_env "${DEPLOY_BASTION_FIRST:-0}"; then
    PRIORITIZE_BASTION_FIRST=1
  fi
  if parse_bool_env "${DEPLOY_BOOTSTRAP:-0}"; then
    FORCE_BOOTSTRAP_PATH=1
  fi
  if parse_bool_env "${DEPLOY_DRY:-0}"; then
    enable_dry_run_mode
  fi
  if parse_bool_env "${DEPLOY_NO_ROLLBACK:-0}"; then
    ROLLBACK_ON_FAILURE=0
  fi
  if [ -n "${DEPLOY_PREFIX_HOST_LOGS:-}" ]; then
    if parse_bool_env "${DEPLOY_PREFIX_HOST_LOGS}"; then
      set_prefix_host_logs_mode 1
    else
      set_prefix_host_logs_mode 0
    fi
  fi
  if parse_bool_env "${DEPLOY_BASTION_TRIGGER:-0}"; then
    BASTION_TRIGGER=1
  fi
  if parse_bool_env "${DEPLOY_USE_REPO_SCRIPT:-0}"; then
    REEXEC_FROM_REPO=1
  fi


  DEPLOY_DEFAULT_USER="root"
  DEPLOY_DEFAULT_KEY_PATH=""
  DEPLOY_DEFAULT_KNOWN_HOSTS=""
  DEPLOY_DEFAULT_BOOTSTRAP_KEY=""
  DEPLOY_DEFAULT_BOOTSTRAP_USER="root"
  DEPLOY_DEFAULT_BOOTSTRAP_KEY_PATH=""
  DEPLOY_DEFAULT_AGE_IDENTITY_KEY=""
  DEPLOY_HOSTS_JSON='{}'

  DEPLOY_TMP_DIR=""
  DEPLOY_CONFIG_DIR=""
  BOOTSTRAP_READY_NODES=""
  ROLLBACK_OK_HOSTS=()
  ROLLBACK_FAILED_HOSTS=()

  BASTION_TRIGGER_KEY_PATH="data/secrets/bastion/nixbot-bastion-ssh.key.age"
  REMOTE_NIXBOT_BASE="/var/lib/nixbot"
  REMOTE_NIXBOT_SSH_DIR="${REMOTE_NIXBOT_BASE}/.ssh"
  REMOTE_NIXBOT_AGE_DIR="${REMOTE_NIXBOT_BASE}/.age"
  REMOTE_NIXBOT_DEPLOY_SCRIPT="${REMOTE_NIXBOT_BASE}/nixbot-deploy.sh"
  REMOTE_NIXBOT_PRIMARY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519"
  REMOTE_NIXBOT_LEGACY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519_legacy"
  REMOTE_NIXBOT_AGE_IDENTITY="${REMOTE_NIXBOT_AGE_DIR}/identity"
  REMOTE_CURRENT_SYSTEM_PATH="/run/current-system"
  DEPLOY_TMP_DIR_PREFIX="/dev/shm/nixbot-deploy."
  BASTION_KNOWN_HOSTS_PREFIX="bastion-known-hosts"
  NODE_KNOWN_HOSTS_PREFIX="known_hosts"
  TMP_SECRETS_DIR=""
  TMP_SSH_DIR=""
  TMP_TF_ARTIFACT_DIR=""
  REPO_DEPLOY_SCRIPT_REL="scripts/nixbot-deploy.sh"
  REMOTE_BOOTSTRAP_KEY_TMP_PREFIX="/tmp/nixbot-bootstrap-key."
  REMOTE_AGE_IDENTITY_TMP_PREFIX="/tmp/nixbot-age-identity."
  TF_CLOUDFLARE_API_TOKEN_PATH="data/secrets/cloudflare/api-token.key.age"
  TF_R2_ACCOUNT_ID_PATH="data/secrets/cloudflare/r2-account-id.key.age"
  TF_R2_STATE_BUCKET_PATH="data/secrets/cloudflare/r2-state-bucket.key.age"
  TF_R2_ACCESS_KEY_ID_PATH="data/secrets/cloudflare/r2-access-key-id.key.age"
  TF_R2_SECRET_ACCESS_KEY_PATH="data/secrets/cloudflare/r2-secret-access-key.key.age"
  TF_SECRETS_DIR="data/secrets/tf"

  # `REPO_ROOT` is the long-lived source mirror. Runs never execute from it
  # directly; they materialize `REPO_WORKTREE_ROOT` and switch into that tree.
  REPO_BASE="${REMOTE_NIXBOT_BASE}"
  REPO_ROOT="${NIXBOT_REPO_ROOT:-${DEPLOY_REPO_PATH:-${REPO_BASE}/nix}}"
  REPO_WORKTREE_ROOT="${NIXBOT_REPO_WORKTREE_ROOT:-}"
  REPO_ROOT_LOCK_DIR=""
  REPO_ROOT_MANAGED=1
  REPO_URL="${DEPLOY_REPO_URL:-ssh://git@github.com/prasannavl/nix.git}"
  REPO_SSH_KEY_PATH="${REMOTE_NIXBOT_PRIMARY_KEY}"
  REPO_GIT_SSH_COMMAND="ssh -i ${REPO_SSH_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

  clear_prepared_deploy_context

  normalize_host_action
}

##### Core Helpers #####

set_env_from_file_if_unset() {
  local var_name="$1"
  local file_path="$2"
  local value=""

  if [ -n "${!var_name:-}" ] || [ ! -f "${file_path}" ]; then
    return
  fi

  value="$(<"${file_path}")"
  if [ -z "${value}" ]; then
    return
  fi

  printf -v "${var_name}" '%s' "${value}"
  export "${var_name?}"
}

parse_bool_env() {
  local raw="${1:-}"
  case "${raw}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    ""|0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) die "Unsupported boolean value: ${raw}" ;;
  esac
}

is_signal_exit_status() {
  case "${1:-}" in
    130|143)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# Sets OPTVAL and OPTSHIFT for --flag/--flag=value argument pairs.
take_optval() {
  case "$1" in
    *=*)
      OPTVAL="${1#*=}"
      OPTSHIFT=1
      ;;
    *)
      [ "$#" -ge 2 ] || die "Missing value for $1"
      OPTVAL="$2"
      OPTSHIFT=2
      ;;
  esac
}

enable_force_mode() {
  DEPLOY_IF_CHANGED=0
  TF_IF_CHANGED=0
  FORCE_REQUESTED=1
}

enable_dry_run_mode() {
  DRY_RUN=1
  DEPLOY_IF_CHANGED=0
}

set_prefix_host_logs_mode() {
  local enabled="$1"
  PREFIX_HOST_LOGS_EXPLICIT=1
  FORCE_PREFIX_HOST_LOGS="${enabled}"
}

set_log_format_mode() {
  case "$1" in
    github-actions)
      LOG_FORMAT="gh"
      ;;
    *)
      LOG_FORMAT="$1"
      ;;
  esac
}

is_github_actions_log_mode() {
  case "${LOG_FORMAT}" in
    gh|github-actions)
      return 0
      ;;
    auto)
      [ "${GITHUB_ACTIONS:-false}" = "true" ]
      return
      ;;
    plain)
      return 1
      ;;
    *)
      die "Unsupported --log-format: ${LOG_FORMAT}"
      ;;
  esac
}

set_discover_keys_mode() {
  case "$1" in
    auto|on|off)
      DISCOVER_DECRYPT_KEYS_MODE="$1"
      ;;
    *)
      die "Unsupported --discover-keys: $1"
      ;;
  esac
}

should_discover_decrypt_keys() {
  case "${DISCOVER_DECRYPT_KEYS_MODE}" in
    on)
      return 0
      ;;
    off)
      return 1
      ;;
    auto)
      [ "${AGE_DECRYPT_IDENTITY_FILE_EXPLICIT}" -eq 0 ]
      return
      ;;
    *)
      die "Unsupported discover-keys mode: ${DISCOVER_DECRYPT_KEYS_MODE}"
      ;;
  esac
}

emit_age_decrypt_identity_candidates() {
  {
    printf '%s\n' "${AGE_DECRYPT_IDENTITY_FILE}"
    if should_discover_decrypt_keys; then
      printf '%s\n' "${REMOTE_NIXBOT_PRIMARY_KEY}"
      printf '%s\n' "${REMOTE_NIXBOT_AGE_IDENTITY}"
    fi
  } | awk 'NF && !seen[$0]++'
}


normalize_host_action() {
  HOST_ACTION="$(resolved_host_action "${ACTION}")"
}

action_is_supported() {
  case "${1:-}" in
    all|build|deploy|tf|tf-dns|tf-platform|tf-apps|check-bootstrap) return 0 ;;
    *) return 1 ;;
  esac
}

action_is_tf_only() {
  case "${1:-}" in
    tf|tf-dns|tf-platform|tf-apps) return 0 ;;
    *) return 1 ;;
  esac
}

resolved_host_action() {
  case "${1:-}" in
    all) printf 'deploy\n' ;;
    *) printf '%s\n' "${1:-}" ;;
  esac
}

emit_normalized_hosts() {
  local raw="$1"

  printf '%s' "${raw}" \
    | tr ', ' '\n' \
    | sed '/^$/d' \
    | awk '!seen[$0]++'
}

normalize_hosts_input() {
  local raw="$1"
  if [ "${raw}" = "all" ]; then
    printf 'all\n'
    return
  fi

  emit_normalized_hosts "${raw}" | paste -sd, -
}

json_array_to_bash_array() {
  local json="$1"
  # shellcheck disable=SC2034
  local -n out_array_ref="$2"

  # shellcheck disable=SC2034
  mapfile -t out_array_ref < <(jq -r '.[]' <<<"${json}")
}

json_array_to_bash_set() {
  local json="$1"
  # shellcheck disable=SC2178
  local -n out_set_ref="$2"
  local item=""

  # shellcheck disable=SC2034
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    out_set_ref["${item}"]=1
  done < <(jq -r '.[]' <<<"${json}")
}

##### Argument Parsing #####

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --ensure-deps)        ENSURE_DEPS_ONLY=1; shift ;;
      --sha|--sha=*)        take_optval "$@"; SHA="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --hosts|--hosts=*)    take_optval "$@"; HOSTS_RAW="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --action|--action=*)  take_optval "$@"; ACTION="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --goal|--goal=*)      take_optval "$@"; GOAL="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --build-host|--build-host=*)
        take_optval "$@"; BUILD_HOST="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --build-jobs|--build-jobs=*)
        take_optval "$@"; BUILD_JOBS="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --deploy-jobs|--deploy-jobs=*)
        take_optval "$@"; DEPLOY_PARALLEL_JOBS="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --force)              enable_force_mode; shift ;;
      --bootstrap)          FORCE_BOOTSTRAP_PATH=1; shift ;;
      --bastion-first)      PRIORITIZE_BASTION_FIRST=1; shift ;;
      --dry)                enable_dry_run_mode; shift ;;
      --no-rollback)        ROLLBACK_ON_FAILURE=0; shift ;;
      --prefix-host-logs)   set_prefix_host_logs_mode 1; shift ;;
      --log-format|--log-format=*)
        take_optval "$@"; set_log_format_mode "${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --user|--user=*)      take_optval "$@"; DEPLOY_USER_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --ssh-key|--ssh-key=*)
        take_optval "$@"; DEPLOY_KEY_PATH_OVERRIDE="${OPTVAL}"; DEPLOY_KEY_OVERRIDE_EXPLICIT=1; shift "${OPTSHIFT}" ;;
      --known-hosts|--known-hosts=*)
        take_optval "$@"; DEPLOY_KNOWN_HOSTS_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --config|--config=*)  take_optval "$@"; DEPLOY_CONFIG_PATH="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --age-key-file|--age-key-file=*)
        take_optval "$@"; AGE_DECRYPT_IDENTITY_FILE="${OPTVAL}"; AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=1; shift "${OPTSHIFT}" ;;
      --discover-keys)      set_discover_keys_mode on; shift ;;
      --no-discover-keys)   set_discover_keys_mode off; shift ;;
      --discover-keys=*)
        take_optval "$@"; set_discover_keys_mode "${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --repo-url|--repo-url=*)
        take_optval "$@"; REPO_URL="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --repo-path|--repo-path=*)
        take_optval "$@"; REPO_ROOT="${OPTVAL}"; REPO_PATH_EXPLICIT=1; shift "${OPTSHIFT}" ;;
      --use-repo-script)    REEXEC_FROM_REPO=1; shift ;;
      --bastion-check-ssh-key-path|--bastion-check-ssh-key-path=*)
        take_optval "$@"; DEPLOY_BASTION_KEY_PATH_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --bastion-trigger)    BASTION_TRIGGER=1; shift ;;
      --bastion-host|--bastion-host=*)
        take_optval "$@"; BASTION_TRIGGER_HOST="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --bastion-user|--bastion-user=*)
        take_optval "$@"; BASTION_TRIGGER_USER="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --bastion-ssh-key|--bastion-ssh-key=*)
        take_optval "$@"; BASTION_TRIGGER_SSH_KEY="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --bastion-known-hosts|--bastion-known-hosts=*)
        take_optval "$@"; BASTION_TRIGGER_KNOWN_HOSTS="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      -h|--help)            usage; exit 0 ;;
      *)                    usage; die "Unknown argument: $1" ;;
    esac
  done

  [ -n "${HOSTS_RAW}" ] || die "--hosts cannot be empty"

  action_is_supported "${ACTION}" || die "Unsupported --action: ${ACTION}"
  normalize_host_action

  case "${GOAL}" in
    switch|boot|test|dry-activate) ;;
    *) die "Unsupported --goal: ${GOAL}" ;;
  esac

  case "${BUILD_HOST}" in
    local|target) ;;
    "") die "Unsupported --build-host: empty value" ;;
    *) ;;
  esac

  [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --build-jobs: ${BUILD_JOBS} (must be a positive integer)"
  [[ "${DEPLOY_PARALLEL_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --deploy-jobs: ${DEPLOY_PARALLEL_JOBS} (must be a positive integer)"
  case "${LOG_FORMAT}" in
    auto|gh|github-actions|plain) ;;
    *) die "Unsupported --log-format: ${LOG_FORMAT}" ;;
  esac
  if [ "${PREFIX_HOST_LOGS_EXPLICIT}" -eq 0 ] && { [ "${BUILD_JOBS}" -gt 1 ] || [ "${DEPLOY_PARALLEL_JOBS}" -gt 1 ]; }; then
    FORCE_PREFIX_HOST_LOGS=1
  fi
  if [ -n "${SHA}" ] && ! [[ "${SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
    die "Unsupported --sha: ${SHA}"
  fi

  if [ "${BASTION_TRIGGER}" -eq 1 ]; then
    [ -n "${BASTION_TRIGGER_HOST}" ] || die "--bastion-host value is required"
    [ -n "${BASTION_TRIGGER_USER}" ] || die "--bastion-user value is required"
  fi
}

cleanup() {
  terminate_background_jobs
  log_group_end_all
  cleanup_repo_worktree
  if [ -n "${REPO_ROOT_LOCK_DIR}" ]; then
    release_repo_root_lock
  fi
  if [ -n "${DEPLOY_TMP_DIR}" ] && [ -d "${DEPLOY_TMP_DIR}" ]; then
    rm -rf "${DEPLOY_TMP_DIR}"
  fi
}

terminate_background_jobs() {
  local -a job_pids=()

  mapfile -t job_pids < <(jobs -pr 2>/dev/null || true)
  [ "${#job_pids[@]}" -gt 0 ] || return 0

  kill "${job_pids[@]}" >/dev/null 2>&1 || true
  wait "${job_pids[@]}" >/dev/null 2>&1 || true
}

ensure_tmp_dir() {
  if [ -n "${DEPLOY_TMP_DIR}" ]; then
    return
  fi
  if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
    DEPLOY_TMP_DIR="$(mktemp -d "${DEPLOY_TMP_DIR_PREFIX}XXXXXX")"
  else
    DEPLOY_TMP_DIR="$(mktemp -d)"
  fi

  # Keep sensitive temp material grouped by purpose so cleanup, debugging, and
  # future retention policies can treat secrets, SSH state, and TF artifacts
  # consistently.
  TMP_SECRETS_DIR="${DEPLOY_TMP_DIR}/secrets"
  TMP_SSH_DIR="${DEPLOY_TMP_DIR}/ssh"
  TMP_TF_ARTIFACT_DIR="$(phase_artifact_dir_path "${DEPLOY_TMP_DIR}" "tf")"
  mkdir -p "${TMP_SECRETS_DIR}" "${TMP_SSH_DIR}"
  ensure_phase_runtime_dirs "${DEPLOY_TMP_DIR}" tf
}

tmp_runtime_dir_path() {
  local area="$1"

  ensure_tmp_dir
  case "${area}" in
    secrets) printf '%s\n' "${TMP_SECRETS_DIR}" ;;
    ssh) printf '%s\n' "${TMP_SSH_DIR}" ;;
    tf) printf '%s\n' "${TMP_TF_ARTIFACT_DIR}" ;;
    *)
      die "Unsupported temp runtime area: ${area}"
      ;;
  esac
}

tmp_runtime_mktemp() {
  local area="$1"
  local pattern="$2"

  mktemp "$(tmp_runtime_dir_path "${area}")/${pattern}"
}

mktemp_repo_worktree_parent_dir() {
  if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
    mktemp -d "/dev/shm/nixbot-worktree.XXXXXX"
  else
    mktemp -d
  fi
}

cleanup_stale_runtime_dirs() {
  local path=""

  [ -d "/dev/shm" ] || return 0

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    rm -rf "${path}" || true
  done < <(
    find /dev/shm -maxdepth 1 -mindepth 1 -type d \
      \( -name 'nixbot-deploy.*' -o -name 'nixbot-worktree.*' \) \
      -mtime +3 -print 2>/dev/null
  )
}

##### Repo Workspace #####

repo_worktree_file_path() {
  local relative_path="$1"

  printf '%s/%s\n' "${REPO_WORKTREE_ROOT%/}" "${relative_path}"
}

repo_worktree_script_path() {
  repo_worktree_file_path "${REPO_DEPLOY_SCRIPT_REL}"
}

cleanup_repo_worktree() {
  if [ -z "${REPO_WORKTREE_ROOT}" ] || [ -z "${REPO_ROOT}" ]; then
    return 0
  fi

  acquire_repo_root_lock
  if [ -d "${REPO_WORKTREE_ROOT}" ]; then
    case "$(pwd -P 2>/dev/null || true)" in
      "${REPO_WORKTREE_ROOT}"|"${REPO_WORKTREE_ROOT}/"*)
        cd /
        ;;
    esac
    git -C "${REPO_ROOT}" worktree remove --force "${REPO_WORKTREE_ROOT}" >/dev/null 2>&1 || rm -rf "${REPO_WORKTREE_ROOT}"
    rmdir "$(dirname "${REPO_WORKTREE_ROOT}")" >/dev/null 2>&1 || true
    git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  fi
  release_repo_root_lock
}

configure_bastion_trigger_ssh_opts() {
  local key_file known_hosts_file scanned_known_hosts default_bastion_key_path

  BASTION_TRIGGER_SSH_OPTS=()

  ensure_tmp_dir

  if [ -z "${BASTION_TRIGGER_SSH_KEY}" ]; then
    default_bastion_key_path="${BASTION_TRIGGER_KEY_PATH}"
    if key_file="$(resolve_runtime_key_file "${default_bastion_key_path}" 1)" && [ -f "${key_file}" ]; then
      BASTION_TRIGGER_SSH_KEY="$(<"${key_file}")"
    else
      BASTION_TRIGGER_SSH_KEY=""
    fi
  fi

  if [ -n "${BASTION_TRIGGER_SSH_KEY}" ]; then
    key_file="$(tmp_runtime_mktemp ssh "bastion-key.XXXXXX")"
    printf '%s\n' "${BASTION_TRIGGER_SSH_KEY}" > "${key_file}"
    chmod 600 "${key_file}"
    BASTION_TRIGGER_SSH_OPTS+=(-i "${key_file}" -o IdentitiesOnly=yes)
  fi

  if [ -n "${BASTION_TRIGGER_KNOWN_HOSTS}" ]; then
    scanned_known_hosts="${BASTION_TRIGGER_KNOWN_HOSTS}"
  else
    scanned_known_hosts="$(ssh-keyscan -H "${BASTION_TRIGGER_HOST}" 2>/dev/null || true)"
    [ -n "${scanned_known_hosts}" ] || die "Could not determine bastion host key for ${BASTION_TRIGGER_HOST}. Pass --bastion-known-hosts/DEPLOY_BASTION_KNOWN_HOSTS or ensure ssh-keyscan can reach the bastion."
  fi

  known_hosts_file="$(tmp_runtime_mktemp ssh "${BASTION_KNOWN_HOSTS_PREFIX}.XXXXXX")"
  printf '%s\n' "${scanned_known_hosts}" > "${known_hosts_file}"
  chmod 600 "${known_hosts_file}"
  BASTION_TRIGGER_SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="${known_hosts_file}")
}

run_bastion_trigger() {
  local trigger_sha trigger_hosts
  local remote_command

  trigger_sha="${SHA}"
  if [ -z "${trigger_sha}" ]; then
    trigger_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  fi
  [ -n "${trigger_sha}" ] || die "Could not resolve local HEAD; pass --sha/DEPLOY_SHA explicitly"
  [[ "${trigger_sha}" =~ ^[0-9a-f]{7,40}$ ]] || die "Unsupported --sha: ${trigger_sha}"

  action_is_supported "${ACTION}" || die "Unsupported --action for --bastion-trigger: ${ACTION}"

  trigger_hosts="$(normalize_hosts_input "${HOSTS_RAW}")"
  [ -n "${trigger_hosts}" ] || die "No valid hosts after normalization"

  configure_bastion_trigger_ssh_opts

  log_section "Phase: Remote Trigger"
  echo "Bastion: ${BASTION_TRIGGER_USER}@${BASTION_TRIGGER_HOST}" >&2
  echo "Action: ${ACTION}" >&2
  echo "Hosts: ${trigger_hosts}" >&2
  echo "SHA: ${trigger_sha}" >&2
  # Intentionally forward only the bastion-safe subset here. The remote side is
  # expected to use its repo-local defaults/config for everything else so local
  # operator overrides do not silently reshape bastion execution.
  remote_command="--sha ${trigger_sha} --hosts ${trigger_hosts} --action ${ACTION}"
  if [ "${LOG_FORMAT}" != "auto" ]; then
    remote_command="${remote_command} --log-format ${LOG_FORMAT}"
  elif is_github_actions_log_mode; then
    remote_command="${remote_command} --log-format gh"
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    remote_command="${remote_command} --dry"
    echo "Dry run: true" >&2
  fi
  if [ "${FORCE_REQUESTED}" -eq 1 ]; then
    remote_command="${remote_command} --force"
    echo "Force: true" >&2
  fi

  log_group_end
  ssh "${BASTION_TRIGGER_SSH_OPTS[@]}" -- "${BASTION_TRIGGER_USER}@${BASTION_TRIGGER_HOST}" \
    "${remote_command}"
}

require_cmds() {
  local missing=0 cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      echo "Required command not found: ${cmd}" >&2
      missing=1
    fi
  done
  [ "${missing}" -eq 0 ] || exit 1
}

is_deploy_style_action() {
  [ "${HOST_ACTION}" = "deploy" ]
}

is_host_build_only_action() {
  [ "${HOST_ACTION}" = "build" ]
}

is_bootstrap_check_action() {
  [ "${ACTION}" = "check-bootstrap" ]
}

# Resolve the source repo root exactly once. Local clean repo runs reuse the
# current checkout as the mirror; bastion/explicit `--repo-path` runs use the
# managed mirror path instead.
resolve_repo_root() {
  local current_repo_root=""

  if [ -n "${NIXBOT_REPO_WORKTREE_ROOT:-}" ]; then
    REPO_WORKTREE_ROOT="${NIXBOT_REPO_WORKTREE_ROOT}"
  fi

  if [ -n "${REPO_WORKTREE_ROOT}" ] || [ "${REPO_PATH_EXPLICIT}" -eq 1 ] || [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    return
  fi

  current_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "${current_repo_root}" ]; then
    REPO_ROOT="${current_repo_root}"
    REPO_ROOT_MANAGED=0
  fi
}

# The source mirror is shared across runs, so only fetch/reset/worktree metadata
# updates happen under this short lock. The actual deploy work happens after the
# worktree is created and the lock is released.
acquire_repo_root_lock() {
  local git_dir="" lock_root=""

  [ -n "${REPO_ROOT}" ] || return 0
  if [ -n "${REPO_ROOT_LOCK_DIR}" ] && [ -d "${REPO_ROOT_LOCK_DIR}" ]; then
    return 0
  fi

  git_dir="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
  [ -n "${git_dir}" ] || return 0
  if [[ "${git_dir}" != /* ]]; then
    git_dir="${REPO_ROOT%/}/${git_dir}"
  fi
  lock_root="${git_dir%/}/nixbot-worktree.lock"

  while ! mkdir "${lock_root}" 2>/dev/null; do
    sleep 0.2
  done

  printf '%s\n' "$$" > "${lock_root}/pid"
  REPO_ROOT_LOCK_DIR="${lock_root}"
}

release_repo_root_lock() {
  if [ -n "${REPO_ROOT_LOCK_DIR}" ] && [ -d "${REPO_ROOT_LOCK_DIR}" ]; then
    rm -rf "${REPO_ROOT_LOCK_DIR}"
  fi
  REPO_ROOT_LOCK_DIR=""
}

ensure_repo_root_exists() {
  mkdir -p "$(dirname "${REPO_ROOT}")"

  if [ -d "${REPO_ROOT}/.git" ]; then
    return
  fi

  if [ -f "${REPO_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="${REPO_GIT_SSH_COMMAND}" git clone "${REPO_URL}" "${REPO_ROOT}"
  else
    git clone "${REPO_URL}" "${REPO_ROOT}"
  fi
}

ensure_clean_repo_root() {
  local status_output=""

  status_output="$(git -C "${REPO_ROOT}" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  [ -z "${status_output}" ] || die "Repo root is dirty; nixbot deploys committed state only: ${REPO_ROOT}"
}

fetch_repo_root_origin() {
  if [ -f "${REPO_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="${REPO_GIT_SSH_COMMAND}" git -C "${REPO_ROOT}" fetch --prune origin
  else
    git -C "${REPO_ROOT}" fetch --prune origin
  fi
}

sync_managed_repo_root() {
  local remote_default_ref=""

  fetch_repo_root_origin

  remote_default_ref="$(git -C "${REPO_ROOT}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  if [ -z "${remote_default_ref}" ]; then
    remote_default_ref="origin/master"
  fi

  git -C "${REPO_ROOT}" checkout -B master "${remote_default_ref}" >/dev/null 2>&1

  TF_CHANGE_BASE_REF="$(git -C "${REPO_ROOT}" rev-parse --verify "refs/remotes/${remote_default_ref}" 2>/dev/null || true)"
  if [ -z "${TF_CHANGE_BASE_REF}" ]; then
    TF_CHANGE_BASE_REF="$(git -C "${REPO_ROOT}" rev-parse --verify refs/remotes/origin/master 2>/dev/null || true)"
  fi
}

resolve_repo_worktree_target_ref() {
  if [ -n "${SHA}" ]; then
    printf '%s\n' "${SHA}"
    return 0
  fi

  if [ "${REPO_ROOT_MANAGED}" -eq 1 ]; then
    printf 'master\n'
    return 0
  fi

  git -C "${REPO_ROOT}" rev-parse --verify HEAD
}

# Prepare an isolated execution tree for this run. This is what allows
# concurrent PR dry-runs without mutating the shared source mirror.
prepare_repo_worktree() {
  local worktree_parent="" target_ref=""

  resolve_repo_root
  [ -n "${REPO_WORKTREE_ROOT}" ] && return 0

  acquire_repo_root_lock
  ensure_repo_root_exists
  ensure_clean_repo_root

  if [ "${REPO_ROOT_MANAGED}" -eq 1 ]; then
    sync_managed_repo_root
  else
    fetch_repo_root_origin >/dev/null 2>&1 || true
    TF_CHANGE_BASE_REF="$(git -C "${REPO_ROOT}" rev-parse --verify refs/remotes/origin/master 2>/dev/null || true)"
  fi

  target_ref="$(resolve_repo_worktree_target_ref)"
  git -C "${REPO_ROOT}" rev-parse --verify "${target_ref}^{commit}" >/dev/null 2>&1 || die "Requested repo target not available: ${target_ref}"

  worktree_parent="$(mktemp_repo_worktree_parent_dir)"
  REPO_WORKTREE_ROOT="${worktree_parent}/repo"
  git -C "${REPO_ROOT}" worktree add --detach "${REPO_WORKTREE_ROOT}" "${target_ref}" >/dev/null
  git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  release_repo_root_lock

  [ -f "$(repo_worktree_script_path)" ] || die "deploy script missing in repo worktree: $(repo_worktree_script_path)"
  cd "${REPO_WORKTREE_ROOT}"
}

reexec_repo_script_if_needed() {
  local current_script repo_script current_resolved repo_resolved
  local -a request_args=("$@")

  [ "${REEXEC_FROM_REPO}" -eq 1 ] || return 0
  [ "${NIXBOT_REEXECED_FROM_REPO:-0}" != "1" ] || return 0

  current_script="${BASH_SOURCE[0]:-$0}"
  repo_script="$(repo_worktree_script_path)"

  [ -f "${repo_script}" ] || die "Repo deploy script missing after checkout: ${repo_script}"

  current_resolved="$(readlink -f "${current_script}" 2>/dev/null || printf '%s\n' "${current_script}")"
  repo_resolved="$(readlink -f "${repo_script}" 2>/dev/null || printf '%s\n' "${repo_script}")"

  if [ "${current_resolved}" = "${repo_resolved}" ]; then
    return 0
  fi

  log_section "Phase: Repo Re-exec"
  echo "Re-executing deploy from worktree repo script:" >&2
  echo "${repo_script}" >&2
  exec env NIXBOT_REEXECED_FROM_REPO=1 NIXBOT_REPO_ROOT="${REPO_ROOT}" NIXBOT_REPO_WORKTREE_ROOT="${REPO_WORKTREE_ROOT}" bash "${repo_script}" "${request_args[@]}"
}

##### Config / Secrets #####

load_deploy_config_json() {
  local path="$1"
  [ -f "${path}" ] || die "Deploy config not found: ${path}"
  nix eval --json --file "${path}"
}

init_deploy_settings() {
  local config_json="$1"

  DEPLOY_CONFIG_DIR="$(cd "$(dirname "${DEPLOY_CONFIG_PATH}")" && pwd -P)"

  DEPLOY_DEFAULT_USER="$(jq -r '.defaults.user // "root"' <<<"${config_json}")"
  DEPLOY_DEFAULT_KEY_PATH="$(jq -r '.defaults.key // ""' <<<"${config_json}")"
  DEPLOY_DEFAULT_KNOWN_HOSTS="$(jq -r '.defaults.knownHosts // ""' <<<"${config_json}")"
  DEPLOY_DEFAULT_BOOTSTRAP_KEY="$(jq -r '.defaults.bootstrapKey // ""' <<<"${config_json}")"
  DEPLOY_DEFAULT_BOOTSTRAP_USER="$(jq -r '.defaults.bootstrapUser // "root"' <<<"${config_json}")"
  DEPLOY_DEFAULT_BOOTSTRAP_KEY_PATH="$(jq -r '.defaults.bootstrapKeyPath // ""' <<<"${config_json}")"
  DEPLOY_DEFAULT_AGE_IDENTITY_KEY="$(jq -r '.defaults.ageIdentityKey // ""' <<<"${config_json}")"
  DEPLOY_HOSTS_JSON="$(jq -c '.hosts // {}' <<<"${config_json}")"

  if [ -n "${DEPLOY_USER_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_USER="${DEPLOY_USER_OVERRIDE}"
  fi

  if [ -n "${DEPLOY_KEY_PATH_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_KEY_PATH="${DEPLOY_KEY_PATH_OVERRIDE}"
  elif [ -n "${DEPLOY_USER_OVERRIDE}" ]; then
    # If user override is set but key override is not, avoid forcing default key.
    DEPLOY_DEFAULT_KEY_PATH=""
  fi

  if [ -n "${DEPLOY_KNOWN_HOSTS_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_KNOWN_HOSTS="${DEPLOY_KNOWN_HOSTS_OVERRIDE}"
  fi
}

resolve_key_source_path() {
  local key_path="$1"

  if [ -z "${key_path}" ]; then
    printf '\n'
    return
  fi

  if [[ "${key_path}" = /* ]]; then
    printf '%s\n' "${key_path}"
    return
  fi

  if [ -f "${key_path}" ]; then
    printf '%s\n' "${key_path}"
    return
  fi

  if [ -f "${DEPLOY_CONFIG_DIR}/${key_path}" ]; then
    printf '%s/%s\n' "${DEPLOY_CONFIG_DIR}" "${key_path}"
    return
  fi

  if [ -f "${DEPLOY_CONFIG_DIR}/../${key_path}" ]; then
    printf '%s/../%s\n' "${DEPLOY_CONFIG_DIR}" "${key_path}"
    return
  fi

  printf '%s/%s\n' "${DEPLOY_CONFIG_DIR}" "${key_path}"
}

resolve_runtime_key_file() {
  local key_path="$1"
  local require_age="${2:-0}"
  local src_path out_file decrypt_identity age_stderr_file decrypt_errors_file
  local candidate_count=0
  local readable_candidate_count=0

  src_path="$(resolve_key_source_path "${key_path}")"
  if [ ! -f "${src_path}" ]; then
    printf '%s\n' "${src_path}"
    return
  fi

  if [ "${require_age}" -eq 1 ] && [[ "${src_path}" != *.age ]]; then
    echo "Provided key path must point to an .age file: ${key_path} (resolved: ${src_path})" >&2
    return 1
  fi

  if [[ "${src_path}" = *.age ]]; then
    require_cmds age
    ensure_tmp_dir
    out_file="$(tmp_runtime_mktemp secrets "key.XXXXXX")"
    decrypt_errors_file="$(tmp_runtime_mktemp secrets "age-errors.XXXXXX")"
    while IFS= read -r decrypt_identity; do
      [ -n "${decrypt_identity}" ] || continue
      candidate_count=$((candidate_count + 1))
      if [ ! -f "${decrypt_identity}" ]; then
        echo "Skipping missing decrypt identity: ${decrypt_identity} for ${src_path}" >&2
        continue
      fi
      readable_candidate_count=$((readable_candidate_count + 1))
      age_stderr_file="$(tmp_runtime_mktemp secrets "age-stderr.XXXXXX")"
      echo "Trying decrypt identity: ${decrypt_identity} for ${src_path}" >&2
      if age --decrypt -i "${decrypt_identity}" -o "${out_file}" "${src_path}" 2>"${age_stderr_file}"; then
        chmod 600 "${out_file}"
        echo "Using decrypt identity: ${decrypt_identity} for ${src_path}" >&2
        rm -f "${age_stderr_file}" "${decrypt_errors_file}"
        printf '%s\n' "${out_file}"
        return
      fi
      {
        printf 'Failed decrypt identity: %s for %s\n' "${decrypt_identity}" "${src_path}"
        cat "${age_stderr_file}"
      } >>"${decrypt_errors_file}"
      rm -f "${age_stderr_file}" "${out_file}"
      out_file="$(tmp_runtime_mktemp secrets "key.XXXXXX")"
    done < <(emit_age_decrypt_identity_candidates)
    if [ "${candidate_count}" -eq 0 ]; then
      echo "No decrypt identity candidates configured for ${src_path}" >&2
    elif [ "${readable_candidate_count}" -eq 0 ]; then
      echo "No decrypt identity files found for ${src_path}" >&2
    else
      echo "Unable to decrypt ${src_path} with the available identities" >&2
      if [ -s "${decrypt_errors_file}" ]; then
        cat "${decrypt_errors_file}" >&2
      fi
    fi
    [ ! -f "${out_file}" ] || rm -f "${out_file}"
    [ ! -f "${decrypt_errors_file}" ] || rm -f "${decrypt_errors_file}"
    return 1
  fi

  printf '%s\n' "${src_path}"
}

load_all_hosts_json() {
  nix flake show --json --no-write-lock-file 2>/dev/null | jq -c '.nixosConfigurations | keys'
}

##### Host Selection #####

select_hosts_json() {
  local all_hosts_json="$1"

  if [ "${HOSTS_RAW}" = "all" ]; then
    printf '%s\n' "${all_hosts_json}"
    return
  fi

  emit_normalized_hosts "${HOSTS_RAW}" \
    | jq -R . \
    | jq -s .
}

host_dependencies_for() {
  local node="$1"

  jq -r --arg h "${node}" '.[$h].deps // [] | .[]' <<<"${DEPLOY_HOSTS_JSON}"
}

expand_selected_hosts_json() {
  local selected_json="$1"
  local all_hosts_json="$2"
  local node dep
  local -a queue=()
  local -a expanded_hosts=()
  declare -A all_host_set=()
  declare -A seen_host_set=()

  json_array_to_bash_set "${all_hosts_json}" all_host_set
  json_array_to_bash_array "${selected_json}" queue

  while [ "${#queue[@]}" -gt 0 ]; do
    node="${queue[0]}"
    queue=("${queue[@]:1}")

    [ -n "${node}" ] || continue
    [ -n "${all_host_set["${node}"]+x}" ] || die "Unknown host requested: ${node}"
    if [ -n "${seen_host_set["${node}"]+x}" ]; then
      continue
    fi

    seen_host_set["${node}"]=1
    expanded_hosts+=("${node}")

    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      if [ -z "${all_host_set["${dep}"]+x}" ]; then
        die "Unknown dependency declared for ${node}: ${dep}"
      fi
      if [ -z "${seen_host_set["${dep}"]+x}" ]; then
        queue+=("${dep}")
      fi
    done < <(host_dependencies_for "${node}")
  done

  jq -cn '$ARGS.positional' --args "${expanded_hosts[@]}"
}

order_selected_hosts_json() {
  local selected_json="$1"
  local all_hosts_json="$2"
  local node dep progress
  local bastion_host="${BASTION_TRIGGER_HOST}"
  local -a selected_hosts=()
  local -a ordered_hosts=()
  local -a deps=()
  declare -A all_host_set=()
  declare -A selected_host_set=()
  declare -A emitted_host_set=()
  declare -A indegree=()
  declare -A dependents=()

  json_array_to_bash_array "${selected_json}" selected_hosts
  json_array_to_bash_set "${all_hosts_json}" all_host_set

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    selected_host_set["${node}"]=1
    indegree["${node}"]=0
  done

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    mapfile -t deps < <(host_dependencies_for "${node}")
    for dep in "${deps[@]}"; do
      [ -n "${dep}" ] || continue
      if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
        continue
      fi
      if [ -z "${all_host_set["${dep}"]+x}" ]; then
        die "Unknown dependency declared for ${node}: ${dep}"
      fi
      if [ -n "${selected_host_set["${dep}"]+x}" ]; then
        indegree["${node}"]=$((indegree["${node}"] + 1))
        dependents["${dep}"]+="${node}"$'\n'
      fi
    done
  done

  if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ -n "${selected_host_set["${bastion_host}"]+x}" ]; then
    emitted_host_set["${bastion_host}"]=1
    ordered_hosts+=("${bastion_host}")
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      indegree["${dep}"]=$((indegree["${dep}"] - 1))
    done <<<"${dependents["${bastion_host}"]:-}"
  fi

  while [ "${#ordered_hosts[@]}" -lt "${#selected_hosts[@]}" ]; do
    progress=0
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      if [ -n "${emitted_host_set["${node}"]+x}" ]; then
        continue
      fi
      if [ "${indegree["${node}"]}" -ne 0 ]; then
        continue
      fi

      emitted_host_set["${node}"]=1
      ordered_hosts+=("${node}")
      progress=1

      while IFS= read -r dep; do
        [ -n "${dep}" ] || continue
        indegree["${dep}"]=$((indegree["${dep}"] - 1))
      done <<<"${dependents["${node}"]:-}"
    done

    if [ "${progress}" -eq 0 ]; then
      local -a cycle_hosts=()
      for node in "${selected_hosts[@]}"; do
        [ -n "${node}" ] || continue
        if [ -z "${emitted_host_set["${node}"]+x}" ]; then
          cycle_hosts+=("${node}")
        fi
      done
      die "Host dependency cycle detected among: ${cycle_hosts[*]}"
    fi
  done

  jq -cn '$ARGS.positional' --args "${ordered_hosts[@]}"
}

selected_host_levels_json() {
  local selected_json="$1"
  local node dep dep_level node_level max_level level
  local bastion_host="${BASTION_TRIGGER_HOST}"
  local -a selected_hosts=()
  declare -A selected_host_set=()
  declare -A host_level=()

  json_array_to_bash_array "${selected_json}" selected_hosts
  json_array_to_bash_set "${selected_json}" selected_host_set

  max_level=0
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
      host_level["${node}"]=0
      continue
    fi
    node_level=0
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      if [ -n "${selected_host_set["${dep}"]+x}" ]; then
        dep_level="${host_level["${dep}"]:-}"
        [ -n "${dep_level}" ] || die "Dependency level missing for ${node}: ${dep}"
        if [ $((dep_level + 1)) -gt "${node_level}" ]; then
          node_level=$((dep_level + 1))
        fi
      fi
    done < <(host_dependencies_for "${node}")

    if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ -n "${selected_host_set["${bastion_host}"]+x}" ] && [ "${node_level}" -lt 1 ]; then
      node_level=1
    fi

    host_level["${node}"]="${node_level}"
    if [ "${node_level}" -gt "${max_level}" ]; then
      max_level="${node_level}"
    fi
  done

  {
    for ((level=0; level<=max_level; level++)); do
      for node in "${selected_hosts[@]}"; do
        [ -n "${node}" ] || continue
        if [ "${host_level["${node}"]}" -eq "${level}" ]; then
          printf '%s\t%s\n' "${level}" "${node}"
        fi
      done
    done
  } | jq -Rn '
    reduce inputs as $line ({};
      ($line | split("\t")) as $parts
      | .[$parts[0]] = (.[$parts[0]] // []) + [$parts[1]]
    )
    | to_entries
    | sort_by(.key | tonumber)
    | map(.value)
  '
}

validate_selected_hosts() {
  local selected_json="$1"
  local all_hosts_json="$2"
  local invalid

  invalid="$(jq -n --argjson selected "${selected_json}" --argjson all "${all_hosts_json}" '$selected - $all')"

  if [ "$(jq 'length' <<<"${invalid}")" -gt 0 ]; then
    die "Unknown hosts requested: $(jq -r 'join(", ")' <<<"${invalid}")"
  fi

  [ "$(jq 'length' <<<"${selected_json}")" -gt 0 ] || die "No hosts selected"
}

resolve_selected_hosts_json() {
  local all_hosts_json="$1"
  local selected_json=""

  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"
  selected_json="$(expand_selected_hosts_json "${selected_json}" "${all_hosts_json}")"
  order_selected_hosts_json "${selected_json}" "${all_hosts_json}"
}

prepare_run_context() {
  local -n selected_json_out_ref="$1"
  local config_json="" all_hosts_json=""
  local -a log_hosts=()

  if [ -f "${DEPLOY_CONFIG_PATH}" ]; then
    config_json="$(load_deploy_config_json "${DEPLOY_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  all_hosts_json="$(load_all_hosts_json)"
  selected_json_out_ref="$(resolve_selected_hosts_json "${all_hosts_json}")"

  json_array_to_bash_array "${selected_json_out_ref}" log_hosts

  log_section "nixbot"
  echo "Action: ${ACTION}" >&2
  print_host_block "Hosts" "${log_hosts[@]}"
  if is_deploy_style_action; then
    echo "Goal: ${GOAL}" >&2
    echo "Build host: ${BUILD_HOST}" >&2
  fi
}

##### Deploy Target / SSH Context #####

resolve_deploy_target() {
  local node="$1"
  local host_cfg user target key_path known_hosts bootstrap_key bootstrap_user bootstrap_key_path age_identity_key

  host_cfg="$(jq -c --arg h "${node}" '.[$h] // {}' <<<"${DEPLOY_HOSTS_JSON}")"

  user="$(jq -r '.user // empty' <<<"${host_cfg}")"
  target="$(jq -r '.target // empty' <<<"${host_cfg}")"
  key_path="$(jq -r '.key // empty' <<<"${host_cfg}")"
  known_hosts="$(jq -r '.knownHosts // empty' <<<"${host_cfg}")"
  bootstrap_key="$(jq -r '.bootstrapKey // empty' <<<"${host_cfg}")"
  bootstrap_user="$(jq -r '.bootstrapUser // empty' <<<"${host_cfg}")"
  bootstrap_key_path="$(jq -r '.bootstrapKeyPath // empty' <<<"${host_cfg}")"
  age_identity_key="$(jq -r '.ageIdentityKey // empty' <<<"${host_cfg}")"

  [ -n "${user}" ] || user="${DEPLOY_DEFAULT_USER}"
  [ -n "${target}" ] || target="${node}"
  [ -n "${key_path}" ] || key_path="${DEPLOY_DEFAULT_KEY_PATH}"
  [ -n "${known_hosts}" ] || known_hosts="${DEPLOY_DEFAULT_KNOWN_HOSTS}"
  [ -n "${bootstrap_key}" ] || bootstrap_key="${DEPLOY_DEFAULT_BOOTSTRAP_KEY}"
  [ -n "${bootstrap_user}" ] || bootstrap_user="${DEPLOY_DEFAULT_BOOTSTRAP_USER}"
  [ -n "${bootstrap_key_path}" ] || bootstrap_key_path="${DEPLOY_DEFAULT_BOOTSTRAP_KEY_PATH}"
  [ -n "${age_identity_key}" ] || age_identity_key="${DEPLOY_DEFAULT_AGE_IDENTITY_KEY}"

  jq -cn \
    --arg user "${user}" \
    --arg target "${target}" \
    --arg keyPath "${key_path}" \
    --arg knownHosts "${known_hosts}" \
    --arg bootstrapKey "${bootstrap_key}" \
    --arg bootstrapUser "${bootstrap_user}" \
    --arg bootstrapKeyPath "${bootstrap_key_path}" \
    --arg ageIdentityKey "${age_identity_key}" \
    '{user: $user, target: $target, keyPath: $keyPath, knownHosts: $knownHosts, bootstrapKey: $bootstrapKey, bootstrapUser: $bootstrapUser, bootstrapKeyPath: $bootstrapKeyPath, ageIdentityKey: $ageIdentityKey}'
}

ensure_known_hosts_file() {
  local node="$1"
  local known_hosts="$2"
  local safe_node known_hosts_file

  ensure_tmp_dir
  safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
  known_hosts_file="${TMP_SSH_DIR}/${NODE_KNOWN_HOSTS_PREFIX}.${safe_node}"

  if [ -n "${known_hosts}" ]; then
    printf '%s\n' "${known_hosts}" > "${known_hosts_file}"
  else
    : > "${known_hosts_file}"
  fi

  chmod 600 "${known_hosts_file}"
  printf '%s\n' "${known_hosts_file}"
}

ensure_known_host() {
  local host="$1"
  local known_hosts="$2"
  local known_hosts_file="$3"

  if [ -n "${known_hosts}" ]; then
    return
  fi

  if ! grep -Fq "${host}" "${known_hosts_file}"; then
    ssh-keyscan "${host}" >> "${known_hosts_file}" 2>/dev/null || true
  fi
}

ssh_host_from_target() {
  local target="$1"

  target="${target##*@}"
  target="${target#\[}"
  target="${target%\]}"
  printf '%s\n' "${target}"
}

mark_bootstrap_ready() {
  local node="$1"
  case " ${BOOTSTRAP_READY_NODES} " in
    *" ${node} "*) ;;
    *) BOOTSTRAP_READY_NODES="${BOOTSTRAP_READY_NODES} ${node}" ;;
  esac
}

is_bootstrap_ready() {
  local node="$1"
  case " ${BOOTSTRAP_READY_NODES} " in
    *" ${node} "*) return 0 ;;
    *) return 1 ;;
  esac
}

check_bootstrap_via_forced_command() {
  local node="$1"
  local ssh_target="$2"
  local -a ssh_opts=("${@:3}")
  local -a check_ssh_opts=()
  local -a check_remote_cmd=()
  local check_output=""
  local check_sha=""
  local check_key_file=""
  local remote_config_path=""
  local i opt skip_next=0

  # Forced-command ingress may require a key different from the deploy key.
  for ((i=0; i<${#ssh_opts[@]}; i++)); do
    if [ "${skip_next}" -eq 1 ]; then
      skip_next=0
      continue
    fi
    opt="${ssh_opts[$i]}"
    case "${opt}" in
      -i)
        skip_next=1
        continue
        ;;
      -o)
        if [ $((i + 1)) -lt ${#ssh_opts[@]} ] && [[ "${ssh_opts[$((i + 1))]}" = IdentitiesOnly=* ]]; then
          skip_next=1
          continue
        fi
        check_ssh_opts+=("${opt}")
        if [ $((i + 1)) -lt ${#ssh_opts[@]} ]; then
          check_ssh_opts+=("${ssh_opts[$((i + 1))]}")
          skip_next=1
        fi
        ;;
      -oIdentitiesOnly=*|IdentitiesOnly=*)
        continue
        ;;
      *)
        check_ssh_opts+=("${opt}")
        ;;
    esac
  done

  if [ -n "${DEPLOY_BASTION_KEY_PATH_OVERRIDE}" ]; then
    if ! check_key_file="$(resolve_runtime_key_file "${DEPLOY_BASTION_KEY_PATH_OVERRIDE}" 1)"; then
      return 1
    fi
    if [ ! -f "${check_key_file}" ]; then
      echo "Forced-command key file not found: ${DEPLOY_BASTION_KEY_PATH_OVERRIDE} (resolved: ${check_key_file})" >&2
      return 1
    fi
    check_ssh_opts=(-i "${check_key_file}" -o IdentitiesOnly=yes "${check_ssh_opts[@]}")
  fi

  check_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  if [[ "${DEPLOY_CONFIG_PATH}" = /* ]]; then
    remote_config_path="${DEPLOY_CONFIG_PATH}"
  else
    remote_config_path="$(repo_worktree_file_path "${DEPLOY_CONFIG_PATH}")"
  fi

  check_remote_cmd=("${REMOTE_NIXBOT_DEPLOY_SCRIPT}" --hosts "${node}" --action check-bootstrap --config "${remote_config_path}")
  if [ -n "${check_sha}" ]; then
    check_remote_cmd=("${REMOTE_NIXBOT_DEPLOY_SCRIPT}" --sha "${check_sha}" --hosts "${node}" --action check-bootstrap --config "${remote_config_path}")
  fi

  # shellcheck disable=SC2029
  if [ -n "${check_sha}" ]; then
    if check_output="$(ssh "${check_ssh_opts[@]}" "${ssh_target}" "${check_remote_cmd[@]}" 2>&1)"; then
      echo "==> Bootstrap key validated via forced command for ${node}"
      return 0
    fi
  elif check_output="$(ssh "${check_ssh_opts[@]}" "${ssh_target}" "${check_remote_cmd[@]}" 2>&1)"; then
    echo "==> Bootstrap key validated via forced command for ${node}"
    return 0
  fi

  if [[ "${check_output}" == *"Unsupported --action: check-bootstrap"* ]] || [[ "${check_output}" == *"invalid --action"* ]]; then
    echo "==> Remote forced command is on an older revision (no check-bootstrap action); treating auth as valid for ${node}"
    return 0
  fi

  echo "==> Forced-command bootstrap check failed for ${node}; continuing with bootstrap injection fallback" >&2
  printf '%s\n' "${check_output}" >&2
  return 1
}

inject_bootstrap_nixbot_key() {
  local node="$1"
  local bootstrap_ssh_target="$2"
  local bootstrap_nixbot_key_path="$3"
  local -a bootstrap_ssh_opts=("${@:4}")
  local bootstrap_key_file remote_tmp expected_bootstrap_fpr
  local remote_has_key_cmd remote_install_cmd
  local bootstrap_dest="${REMOTE_NIXBOT_PRIMARY_KEY}"
  local bootstrap_legacy_dest="${REMOTE_NIXBOT_LEGACY_KEY}"

  if [ -z "${bootstrap_nixbot_key_path}" ]; then
    return
  fi

  if ! bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_nixbot_key_path}")"; then
    return 1
  fi
  if [ ! -f "${bootstrap_key_file}" ]; then
    echo "Bootstrap nixbot key not found for ${node}: ${bootstrap_nixbot_key_path} (resolved: ${bootstrap_key_file})" >&2
    return 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "DRY: would inject bootstrap nixbot key ${bootstrap_key_file} -> ${bootstrap_ssh_target}:${bootstrap_dest}"
    return
  fi

  expected_bootstrap_fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2)"
  if [ -z "${expected_bootstrap_fpr}" ]; then
    echo "Unable to compute bootstrap key fingerprint from ${bootstrap_key_file}" >&2
    return 1
  fi

  remote_has_key_cmd="$(build_remote_has_bootstrap_key_cmd "${bootstrap_dest}" "${expected_bootstrap_fpr}")"
  # shellcheck disable=SC2029
  if ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_has_key_cmd}" >/dev/null 2>&1; then
    echo "==> Skipping bootstrap nixbot key for ${node}; matching key already present on target"
    return
  fi

  remote_tmp="$(create_remote_tmp_file "${bootstrap_ssh_target}" "${REMOTE_BOOTSTRAP_KEY_TMP_PREFIX}" "${bootstrap_ssh_opts[@]}")"
  if [ -z "${remote_tmp}" ]; then
    echo "Failed to allocate remote temporary file for bootstrap key on ${node}" >&2
    return 1
  fi

  if ! copy_local_file_to_remote_tmp "${bootstrap_key_file}" "${bootstrap_ssh_target}" "${remote_tmp}" "${bootstrap_ssh_opts[@]}"; then
    cleanup_remote_tmp_file "${bootstrap_ssh_target}" "${remote_tmp}" "${bootstrap_ssh_opts[@]}"
    return 1
  fi

  remote_install_cmd="$(build_remote_bootstrap_install_cmd "${remote_tmp}" "${bootstrap_dest}" "${bootstrap_legacy_dest}")"

  echo "==> Injecting bootstrap nixbot key for ${node}"
  if ! run_remote_install_with_tty "${bootstrap_ssh_target}" "${remote_install_cmd}" "${bootstrap_ssh_opts[@]}"; then
    cleanup_remote_tmp_file "${bootstrap_ssh_target}" "${remote_tmp}" "${bootstrap_ssh_opts[@]}"
    return 1
  fi
}

build_remote_bootstrap_install_cmd() {
  local remote_tmp="$1"
  local bootstrap_dest="$2"
  local bootstrap_legacy_dest="$3"
  # shellcheck disable=SC2016
  local before_install_cmd='if sudo test -f "${remote_dest}"; then sudo install -m 0400 "${remote_dest}" "${bootstrap_legacy_dest}"; fi'
  # shellcheck disable=SC2016
  local after_install_cmd='if sudo id -u nixbot >/dev/null 2>&1; then sudo chown -R nixbot:nixbot '"${REMOTE_NIXBOT_SSH_DIR}"'; fi'

  build_remote_install_file_cmd \
    "${remote_tmp}" \
    "${bootstrap_dest}" \
    "${REMOTE_NIXBOT_SSH_DIR}" \
    "0700" \
    "0400" \
    "${before_install_cmd}" \
    "${after_install_cmd}" \
    "bootstrap_legacy_dest='${bootstrap_legacy_dest}'"
}

build_remote_install_file_cmd() {
  local remote_tmp="$1"
  local remote_dest="$2"
  local remote_dir="$3"
  local remote_dir_mode="$4"
  local remote_file_mode="$5"
  local before_install_cmd="${6:-}"
  local after_install_cmd="${7:-}"
  local extra_vars="${8:-}"

  cat <<EOF
install_managed_file() {
  remote_tmp='${remote_tmp}'
  remote_dest='${remote_dest}'
  remote_dir='${remote_dir}'
  remote_dir_mode='${remote_dir_mode}'
  remote_file_mode='${remote_file_mode}'
  ${extra_vars}

  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install \${remote_dest}" >&2
    return 1
  fi

  sudo install -d -m 0755 ${REMOTE_NIXBOT_BASE}
  sudo install -d -m "\${remote_dir_mode}" "\${remote_dir}"
  ${before_install_cmd}
  sudo install -m "\${remote_file_mode}" "\${remote_tmp}" "\${remote_dest}"
  rm -f "\${remote_tmp}"
  ${after_install_cmd}
  return 0
}
install_managed_file
EOF
}

build_remote_file_value_check_cmd() {
  local remote_dest="$1"
  local expected_value="$2"
  local read_cmd="$3"

  cat <<EOF
dest='${remote_dest}'
want='${expected_value}'
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to validate \${dest}" >&2
  exit 1
fi
current="\$(DEST="\${dest}" sudo -n env DEST="\${dest}" sh -c '${read_cmd}' 2>/dev/null || true)"
[ "\${current}" = "\${want}" ]
EOF
}

build_remote_has_bootstrap_key_cmd() {
  local bootstrap_dest="$1"
  local expected_bootstrap_fpr="$2"

  # shellcheck disable=SC2016
  build_remote_file_value_check_cmd \
    "${bootstrap_dest}" \
    "${expected_bootstrap_fpr}" \
    'ssh-keygen -lf "$DEST" | tr -s " " | cut -d " " -f2'
}

create_remote_tmp_file() {
  local ssh_target="$1"
  local tmp_prefix="$2"
  shift 2
  local -a ssh_opts=("$@")

  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${ssh_target}" "umask 077; mktemp ${tmp_prefix}XXXXXX"
}

cleanup_remote_tmp_file() {
  local ssh_target="$1"
  local remote_tmp="$2"
  shift 2
  local -a ssh_opts=("$@")

  [ -n "${remote_tmp}" ] || return 0
  # shellcheck disable=SC2029
  ssh "${ssh_opts[@]}" "${ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
}

copy_local_file_to_remote_tmp() {
  local local_file="$1"
  local ssh_target="$2"
  local remote_tmp="$3"
  shift 3
  local -a ssh_opts=("$@")

  scp "${ssh_opts[@]}" "${local_file}" "${ssh_target}:${remote_tmp}"
}

run_remote_install_with_tty() {
  local ssh_target="$1"
  local install_cmd="$2"
  shift 2
  local -a ssh_opts=("$@")

  ssh -tt "${ssh_opts[@]}" "${ssh_target}" "${install_cmd}" <"$(resolve_ssh_tty_stdin_path)"
}

set_prepared_deploy_context() {
  local ssh_target="$1"
  local nix_sshopts="$2"
  local using_bootstrap_fallback="$3"
  local age_identity_key="$4"
  shift 4
  local -a ssh_opts=("$@")

  PREP_DEPLOY_SSH_TARGET="${ssh_target}"
  PREP_DEPLOY_SSH_OPTS=("${ssh_opts[@]}")
  PREP_DEPLOY_NIX_SSHOPTS="${nix_sshopts}"
  PREP_USING_BOOTSTRAP_FALLBACK="${using_bootstrap_fallback}"
  PREP_DEPLOY_AGE_IDENTITY_KEY="${age_identity_key}"
}

clear_prepared_deploy_context() {
  PREP_DEPLOY_SSH_TARGET=""
  PREP_DEPLOY_NIX_SSHOPTS=""
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_AGE_IDENTITY_KEY=""
  PREP_DEPLOY_SSH_OPTS=()
}

init_known_hosts_ssh_context() {
  local batch_mode="$1"
  local known_hosts_file="$2"
  # shellcheck disable=SC2178
  local -n ssh_opts_out_ref="$3"
  local -n nix_sshopts_out_ref="$4"

  ssh_opts_out_ref=(-o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
  nix_sshopts_out_ref="-o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"

  if [ "${batch_mode}" -eq 1 ]; then
    ssh_opts_out_ref=(-o BatchMode=yes "${ssh_opts_out_ref[@]}")
    nix_sshopts_out_ref="-o BatchMode=yes ${nix_sshopts_out_ref}"
  fi
}

apply_identity_to_ssh_context() {
  local key_file="$1"
  # shellcheck disable=SC2178
  local -n ssh_opts_inout_ref="$2"
  local -n nix_sshopts_inout_ref="$3"

  ssh_opts_inout_ref=(-i "${key_file}" -o IdentitiesOnly=yes "${ssh_opts_inout_ref[@]}")
  if [ -n "${nix_sshopts_inout_ref}" ]; then
    nix_sshopts_inout_ref="-i ${key_file} -o IdentitiesOnly=yes ${nix_sshopts_inout_ref}"
  else
    nix_sshopts_inout_ref="-i ${key_file} -o IdentitiesOnly=yes"
  fi
}

resolve_ssh_identity_file() {
  local key_path="$1"
  local label="$2"
  local require_age="${3:-0}"
  local -n resolved_key_file_out_ref="$4"

  resolved_key_file_out_ref=""
  [ -n "${key_path}" ] || return 0

  if ! resolved_key_file_out_ref="$(resolve_runtime_key_file "${key_path}" "${require_age}")"; then
    return 1
  fi
  if [ ! -f "${resolved_key_file_out_ref}" ]; then
    echo "${label} file not found: ${key_path} (resolved: ${resolved_key_file_out_ref})" >&2
    return 1
  fi
}

prepare_host_ssh_contexts() {
  local node="$1"
  local host="$2"
  local known_hosts="$3"
  # shellcheck disable=SC2178
  local -n host_ssh_opts_out_ref="$4"
  # shellcheck disable=SC2178
  local -n host_nix_sshopts_out_ref="$5"
  # shellcheck disable=SC2178,SC2034
  local -n bootstrap_ssh_opts_out_ref="$6"
  # shellcheck disable=SC2178,SC2034
  local -n bootstrap_nix_sshopts_out_ref="$7"
  local known_hosts_file build_host_host=""

  # shellcheck disable=SC2034
  host_ssh_opts_out_ref=()
  # shellcheck disable=SC2034
  host_nix_sshopts_out_ref=""
  # shellcheck disable=SC2034
  bootstrap_ssh_opts_out_ref=()
  # shellcheck disable=SC2034
  bootstrap_nix_sshopts_out_ref=""

  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi

  known_hosts_file="$(ensure_known_hosts_file "${node}" "${known_hosts}")"
  ensure_known_host "${host}" "${known_hosts}" "${known_hosts_file}"
  case "${BUILD_HOST}" in
    local|target)
      ;;
    *)
      build_host_host="$(ssh_host_from_target "${BUILD_HOST}")"
      if [ -n "${build_host_host}" ] && [ "${build_host_host}" != "${host}" ]; then
        ensure_known_host "${build_host_host}" "${known_hosts}" "${known_hosts_file}"
      fi
      ;;
  esac

  init_known_hosts_ssh_context 1 "${known_hosts_file}" host_ssh_opts_out_ref host_nix_sshopts_out_ref
  init_known_hosts_ssh_context 0 "${known_hosts_file}" bootstrap_ssh_opts_out_ref bootstrap_nix_sshopts_out_ref
}

ensure_bootstrap_key_ready() {
  local node="$1"
  local bootstrap_ssh_target="$2"
  local bootstrap_nixbot_key_path="$3"
  shift 3
  local -a bootstrap_ssh_opts=("$@")

  if [ -z "${bootstrap_nixbot_key_path}" ]; then
    return 0
  fi
  if is_bootstrap_ready "${node}"; then
    echo "==> Reusing bootstrap readiness for ${node} from earlier step"
    return 0
  fi
  inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key_path}" "${bootstrap_ssh_opts[@]}" || return 1
  mark_bootstrap_ready "${node}"
}

use_prepared_bootstrap_context() {
  local node="$1"
  local bootstrap_ssh_target="$2"
  local bootstrap_nix_sshopts="$3"
  local age_identity_key="$4"
  local bootstrap_key="$5"
  shift 5
  local -a bootstrap_ssh_opts=("$@")

  ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
  set_prepared_deploy_context "${bootstrap_ssh_target}" "${bootstrap_nix_sshopts}" 1 "${age_identity_key}" "${bootstrap_ssh_opts[@]}"
}

inject_host_age_identity_key() {
  local node="$1"
  local ssh_target="$2"
  local age_identity_key_path="$3"
  local -a ssh_opts=("${@:4}")
  local age_identity_key_file remote_tmp expected_sha
  local remote_dest="${REMOTE_NIXBOT_AGE_IDENTITY}"
  local remote_has_cmd remote_install_cmd

  if [ -z "${age_identity_key_path}" ]; then
    return
  fi

  if ! age_identity_key_file="$(resolve_runtime_key_file "${age_identity_key_path}")"; then
    return 1
  fi
  if [ ! -f "${age_identity_key_file}" ]; then
    echo "Host age identity key not found for ${node}: ${age_identity_key_path} (resolved: ${age_identity_key_file})" >&2
    return 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "DRY: would inject host age identity ${age_identity_key_file} -> ${ssh_target}:${remote_dest}"
    return
  fi

  expected_sha="$(sha256sum "${age_identity_key_file}" | awk '{print $1}')"
  if [ -z "${expected_sha}" ]; then
    echo "Unable to compute host age identity checksum for ${node}" >&2
    return 1
  fi

  # shellcheck disable=SC2016
  remote_has_cmd="$(build_remote_file_value_check_cmd \
    "${remote_dest}" \
    "${expected_sha}" \
    'set -- $(sha256sum "$DEST"); printf "%s\n" "$1"')"
  # shellcheck disable=SC2029
  if ssh "${ssh_opts[@]}" "${ssh_target}" "${remote_has_cmd}" >/dev/null 2>&1; then
    echo "==> Skipping host age identity for ${node}; matching key already present on target"
    return
  fi

  remote_tmp="$(create_remote_tmp_file "${ssh_target}" "${REMOTE_AGE_IDENTITY_TMP_PREFIX}" "${ssh_opts[@]}")"
  if [ -z "${remote_tmp}" ]; then
    echo "Failed to allocate remote temporary file for host age identity on ${node}" >&2
    return 1
  fi

  if ! copy_local_file_to_remote_tmp "${age_identity_key_file}" "${ssh_target}" "${remote_tmp}" "${ssh_opts[@]}"; then
    cleanup_remote_tmp_file "${ssh_target}" "${remote_tmp}" "${ssh_opts[@]}"
    return 1
  fi

  # shellcheck disable=SC2016
  remote_install_cmd="$(build_remote_install_file_cmd \
    "${remote_tmp}" \
    "${remote_dest}" \
    "${REMOTE_NIXBOT_AGE_DIR}" \
    "0710" \
    "0440" \
    "" \
    'sudo chown root:nixbot "${remote_dir}" "${remote_dest}"')"

  echo "==> Injecting host age identity for ${node}"
  if ! run_remote_install_with_tty "${ssh_target}" "${remote_install_cmd}" "${ssh_opts[@]}"; then
    cleanup_remote_tmp_file "${ssh_target}" "${remote_tmp}" "${ssh_opts[@]}"
    return 1
  fi
}

prepare_deploy_context() {
  local node="$1"
  local target_info user host key_path known_hosts bootstrap_key bootstrap_user bootstrap_key_path age_identity_key
  local key_file bootstrap_key_file
  local ssh_target bootstrap_ssh_target
  local -a ssh_opts=()
  local -a bootstrap_ssh_opts=()
  local nix_sshopts=""
  local bootstrap_nix_sshopts=""

  clear_prepared_deploy_context
  target_info="$(resolve_deploy_target "${node}")"

  user="$(jq -r '.user' <<<"${target_info}")"
  host="$(jq -r '.target' <<<"${target_info}")"
  key_path="$(jq -r '.keyPath // empty' <<<"${target_info}")"
  known_hosts="$(jq -r '.knownHosts // empty' <<<"${target_info}")"
  bootstrap_key="$(jq -r '.bootstrapKey // empty' <<<"${target_info}")"
  bootstrap_user="$(jq -r '.bootstrapUser // empty' <<<"${target_info}")"
  bootstrap_key_path="$(jq -r '.bootstrapKeyPath // empty' <<<"${target_info}")"
  age_identity_key="$(jq -r '.ageIdentityKey // empty' <<<"${target_info}")"

  ssh_target="${user}@${host}"
  bootstrap_ssh_target="${bootstrap_user}@${host}"

  prepare_host_ssh_contexts \
    "${node}" \
    "${host}" \
    "${known_hosts}" \
    ssh_opts \
    nix_sshopts \
    bootstrap_ssh_opts \
    bootstrap_nix_sshopts || return 1

  if [ -n "${key_path}" ]; then
    if ! resolve_ssh_identity_file "${key_path}" "Deploy SSH key" "${DEPLOY_KEY_OVERRIDE_EXPLICIT}" key_file; then
      return 1
    fi
    apply_identity_to_ssh_context "${key_file}" ssh_opts nix_sshopts
  fi

  if [ -n "${bootstrap_key_path}" ]; then
    if ! resolve_ssh_identity_file "${bootstrap_key_path}" "Bootstrap SSH key" 0 bootstrap_key_file; then
      return 1
    fi
    apply_identity_to_ssh_context "${bootstrap_key_file}" bootstrap_ssh_opts bootstrap_nix_sshopts
  fi

  set_prepared_deploy_context "${ssh_target}" "${nix_sshopts}" 0 "${age_identity_key}" "${ssh_opts[@]}"

  if [ "${FORCE_BOOTSTRAP_PATH}" -eq 1 ]; then
    echo "==> Forcing bootstrap path for ${node}: ${bootstrap_ssh_target}"
    use_prepared_bootstrap_context "${node}" "${bootstrap_ssh_target}" "${bootstrap_nix_sshopts}" "${age_identity_key}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
    return
  fi

  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
      if ! ssh "${ssh_opts[@]}" "${ssh_target}" "true" >/dev/null 2>&1; then
        local validated_via_forced_command=0

        if is_bootstrap_ready "${node}"; then
          echo "==> Reusing bootstrap readiness for ${node} from earlier step"
          validated_via_forced_command=1
        elif [ -n "${bootstrap_key}" ] && check_bootstrap_via_forced_command "${node}" "${ssh_target}" "${ssh_opts[@]}"; then
          validated_via_forced_command=1
          mark_bootstrap_ready "${node}"
        else
          ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
        fi

        if [ "${validated_via_forced_command}" -eq 1 ]; then
          echo "==> Primary deploy target ${ssh_target} is forced-command-only for ingress checks; using bootstrap target ${bootstrap_ssh_target} for nixos-rebuild"
        else
          echo "==> Primary deploy target ${ssh_target} is unavailable; falling back to bootstrap target ${bootstrap_ssh_target} for this run"
        fi

        use_prepared_bootstrap_context "${node}" "${bootstrap_ssh_target}" "${bootstrap_nix_sshopts}" "${age_identity_key}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
        return
      fi
    else
      ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
    fi
  elif [ -n "${bootstrap_key}" ]; then
    ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
  fi
}

##### Host Phases #####

snapshot_host_generation() {
  local node="$1"
  local snapshot_file="$2"
  local remote_current_path ssh_target
  local -a ssh_opts=()

  log_host_stage "snapshot" "${node}"
  prepare_deploy_context "${node}" || return 1
  ssh_target="${PREP_DEPLOY_SSH_TARGET}"
  ssh_opts=("${PREP_DEPLOY_SSH_OPTS[@]}")
  # shellcheck disable=SC2029
  if ! remote_current_path="$(ssh "${ssh_opts[@]}" "${ssh_target}" "readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true")"; then
    remote_current_path=""
  fi

  if [ -z "${remote_current_path}" ]; then
    echo "${node}: snapshot failed" >&2
    return 1
  fi

  printf '%s\n' "${remote_current_path}" > "${snapshot_file}"
  echo "${remote_current_path}"
}

snapshot_exists() {
  local snapshot_file="$1"

  [ -s "${snapshot_file}" ]
}

wave_needs_snapshot_retry() {
  local snapshot_dir="$1"
  shift

  local node

  [ "${DRY_RUN}" -eq 0 ] || return 1
  [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 1

  for node in "$@"; do
    [ -n "${node}" ] || continue
    if ! snapshot_exists "${snapshot_dir}/${node}.path"; then
      return 0
    fi
  done

  return 1
}

wait_for_job_slot() {
  local -n active_jobs_inout_ref="$1"
  local max_jobs="$2"
  local wait_rc=0

  if [ "${active_jobs_inout_ref}" -ge "${max_jobs}" ]; then
    if ! wait -n; then
      wait_rc="$?"
      if is_signal_exit_status "${wait_rc}"; then
        return "${wait_rc}"
      fi
    fi
    active_jobs_inout_ref=$((active_jobs_inout_ref - 1))
  fi
}

drain_job_slots() {
  local -n active_jobs_inout_ref="$1"
  local wait_rc=0

  while [ "${active_jobs_inout_ref}" -gt 0 ]; do
    if ! wait -n; then
      wait_rc="$?"
      if is_signal_exit_status "${wait_rc}"; then
        return "${wait_rc}"
      fi
    fi
    active_jobs_inout_ref=$((active_jobs_inout_ref - 1))
  done
}

run_streamed_host_command() {
  local node="$1"
  local log_file="${2:-}"
  shift 2

  if [ -n "${log_file}" ]; then
    run_with_combined_output "$@" > >(host_log_filter "${node}" | tee -a "${log_file}")
  elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
    run_with_combined_output "$@" > >(host_log_filter "${node}")
  else
    "$@"
  fi
}

run_build_job() {
  local node="$1"
  local out_file="$2"
  local status_file="$3"
  local log_file="${4:-}"
  local built_out_path rc

  (
    set +e
    if [ -n "${log_file}" ]; then
      built_out_path="$(resolve_build_out_path "${node}" \
        2> >(host_log_filter "${node}" | tee -a "${log_file}" >&2))"
      rc="$?"
      if [ "${rc}" = "0" ] && [ -n "${built_out_path}" ]; then
        printf '%s\n' "${built_out_path}" | host_log_filter "${node}" | tee -a "${log_file}" >/dev/null
      fi
    elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
      built_out_path="$(resolve_build_out_path "${node}" 2> >(host_log_filter "${node}" >&2))"
      rc="$?"
    else
      built_out_path="$(resolve_build_out_path "${node}")"
      rc="$?"
    fi
    if [ "${rc}" = "0" ]; then
      printf '%s\n' "${built_out_path}" > "${out_file}"
    fi
    log_group_end_host_stage "build"
    write_status_file "${status_file}" "${rc}"
    exit "${rc}"
  )
}

record_phase_status() {
  local node="$1"
  local status_file="$2"
  local -n success_hosts_out_ref="$3"
  local -n failed_hosts_out_ref="$4"
  local rc

  if ! rc="$(read_status_file "${status_file}")"; then
    failed_hosts_out_ref+=("${node}")
    return 1
  fi
  if [ "${rc}" != "0" ]; then
    failed_hosts_out_ref+=("${node}")
    if is_signal_exit_status "${rc}"; then
      return "${rc}"
    fi
    return 1
  fi

  success_hosts_out_ref+=("${node}")
  return 0
}

record_deploy_phase_status() {
  local node="$1"
  local status_file="$2"
  # shellcheck disable=SC2178
  local -n success_hosts_out_ref="$3"
  local -n skipped_hosts_out_ref="$4"
  # shellcheck disable=SC2178
  local -n failed_hosts_out_ref="$5"
  local status

  if ! status="$(read_status_file "${status_file}")"; then
    failed_hosts_out_ref+=("${node}")
    return 1
  fi
  case "${status}" in
    0)
      success_hosts_out_ref+=("${node}")
      return 0
      ;;
    skip)
      skipped_hosts_out_ref+=("${node}")
      return 0
      ;;
    *)
      failed_hosts_out_ref+=("${node}")
      if is_signal_exit_status "${status}"; then
        return "${status}"
      fi
      return 1
      ;;
  esac
}

append_unique_array_item() {
  local -n array_out_ref="$1"
  local item="$2"

  array_contains "${item}" "${array_out_ref[@]}" || array_out_ref+=("${item}")
}

collect_completed_deploy_wave_statuses() {
  local deploy_status_dir="$1"
  # shellcheck disable=SC2178
  local -n success_hosts_out_ref="$2"
  # shellcheck disable=SC2178
  local -n skipped_hosts_out_ref="$3"
  # shellcheck disable=SC2178
  local -n failed_hosts_out_ref="$4"
  shift 4

  local node status_file status=""

  for node in "$@"; do
    [ -n "${node}" ] || continue
    status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
    if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
      continue
    fi
    case "${status}" in
      0)
        append_unique_array_item success_hosts_out_ref "${node}"
        ;;
      skip)
        append_unique_array_item skipped_hosts_out_ref "${node}"
        ;;
      *)
        append_unique_array_item failed_hosts_out_ref "${node}"
        ;;
    esac
  done
}

handle_deploy_interrupt() {
  local interrupt_rc="$1"
  local snapshot_dir="$2"
  local deploy_status_dir="$3"
  local rollback_log_dir="$4"
  local rollback_status_dir="$5"
  # shellcheck disable=SC2178
  local -n success_hosts_out_ref="$6"
  # shellcheck disable=SC2178
  local -n skipped_hosts_out_ref="$7"
  # shellcheck disable=SC2178
  local -n failed_hosts_out_ref="$8"
  shift 8

  terminate_background_jobs
  collect_completed_deploy_wave_statuses \
    "${deploy_status_dir}" \
    success_hosts_out_ref \
    skipped_hosts_out_ref \
    failed_hosts_out_ref \
    "$@"
  maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${success_hosts_out_ref[@]}"
  return "${interrupt_rc}"
}

abort_deploy_on_signal() {
  local phase_rc="$1"
  local snapshot_dir="$2"
  local deploy_status_dir="$3"
  local rollback_log_dir="$4"
  local rollback_status_dir="$5"
  # shellcheck disable=SC2178
  local -n success_hosts_out_ref="$6"
  # shellcheck disable=SC2178
  local -n skipped_hosts_out_ref="$7"
  # shellcheck disable=SC2178
  local -n failed_hosts_out_ref="$8"
  shift 8

  if ! is_signal_exit_status "${phase_rc}"; then
    return 1
  fi

  handle_deploy_interrupt \
    "${phase_rc}" \
    "${snapshot_dir}" \
    "${deploy_status_dir}" \
    "${rollback_log_dir}" \
    "${rollback_status_dir}" \
    success_hosts_out_ref \
    skipped_hosts_out_ref \
    failed_hosts_out_ref \
    "$@"
}

log_snapshot_retry_transition() {
  local snapshot_dir="$1"
  local level_index="$2"
  shift 2

  if ! wave_needs_snapshot_retry "${snapshot_dir}" "$@"; then
    return 1
  fi

  log_section "Phase: Snapshot"
  if [ "$#" -eq 1 ]; then
    log_subsection "Snapshot Wave ${level_index}: $1"
  else
    log_subsection "Snapshot Wave ${level_index}: $(join_by_comma "$@")"
  fi
  return 0
}

run_deploy_job() {
  local node="$1"
  local out_file="$2"
  local status_file="$3"
  local log_file="${4:-}"
  local built_out_path rc skip_marker

  (
    set +e
    skip_marker="${status_file}.skip"
    rm -f "${skip_marker}"
    if [ ! -s "${out_file}" ]; then
      echo "Missing built output path for ${node}: ${out_file}" >&2
      rc=1
    else
      built_out_path="$(cat "${out_file}")"
      if run_streamed_host_command "${node}" "${log_file}" deploy_host "${node}" "${built_out_path}" "${skip_marker}"; then
        rc=0
      else
        rc="$?"
      fi
    fi
    log_group_end_host_stage "deploy"
    if [ "${rc}" = "0" ] && [ -e "${skip_marker}" ]; then
      write_status_file "${status_file}" "skip"
    else
      write_status_file "${status_file}" "${rc}"
    fi
    rm -f "${skip_marker}"
    exit "${rc}"
  )
}

print_host_failures() {
  local heading="$1"
  local mode="${2:-plain}"
  local log_dir="${3:-}"
  local status_dir=""

  if [ "${mode}" = "build" ]; then
    status_dir="${4:-}"
    shift 4
  else
    shift 3
  fi

  local -a failed_hosts=("$@")
  local node status_file log_file rc

  [ "${#failed_hosts[@]}" -gt 0 ] || return 0

  echo "${heading} for ${#failed_hosts[@]} host(s):" >&2
  for node in "${failed_hosts[@]}"; do
    case "${mode}" in
      build)
        status_file="$(phase_dir_item_status_file "${status_dir}" "${node}")"
        log_file="$(phase_dir_item_log_file "${log_dir}" "${node}")"
        rc="unknown"
        if rc="$(read_status_file "${status_file}")"; then
          :
        fi

        if [ -f "${log_file}" ]; then
          echo "  - ${node} (exit=${rc}, log=${log_file})" >&2
        else
          echo "  - ${node} (exit=${rc})" >&2
        fi
        ;;
      deploy)
        echo "  - ${node} (log=$(phase_dir_item_log_file "${log_dir}" "${node}"))" >&2
        ;;
      snapshot)
        echo "  - ${node} (exit=snapshot)" >&2
        ;;
      plain|*)
        echo "  - ${node}" >&2
        ;;
    esac
  done
}

maybe_rollback_successful_hosts() {
  local snapshot_dir="$1"
  local rollback_log_dir="$2"
  local rollback_status_dir="$3"
  shift 3

  local -a successful_hosts=("$@")

  if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
    rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts[@]}" || true
  fi
}

record_snapshot_failures_for_wave() {
  local snapshot_dir="$1"
  local -n snapshot_failed_hosts_out_ref="$2"
  # shellcheck disable=SC2178
  local -n deploy_failed_hosts_out_ref="$3"
  shift 3

  local node
  for node in "$@"; do
    [ -n "${node}" ] || continue
    if ! snapshot_exists "${snapshot_dir}/${node}.path"; then
      snapshot_failed_hosts_out_ref+=("${node}")
      deploy_failed_hosts_out_ref+=("${node}")
    fi
  done
}

run_initial_snapshot_wave() {
  local level_group="$1"
  local snapshot_dir="$2"
  local -a level_hosts=()
  local node

  [ -n "${level_group}" ] || return 0

  mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
  log_subsection "Snapshot Wave 0: $(join_by_comma "${level_hosts[@]}")"
  for node in "${level_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
      snapshot_host_generation "${node}" "${snapshot_dir}/${node}.path" \
        > >(host_log_filter "${node}") \
        2> >(host_log_filter "${node}" >&2) || {
        echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
      }
    elif ! snapshot_host_generation "${node}" "${snapshot_dir}/${node}.path"; then
      echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
    fi
  done
}

ensure_wave_snapshots() {
  local snapshot_dir="$1"
  shift

  local node snapshot_file rc=0

  [ "${DRY_RUN}" -eq 0 ] || return 0
  [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 0
  [ "$#" -gt 0 ] || return 0

  for node in "$@"; do
    [ -n "${node}" ] || continue
    snapshot_file="${snapshot_dir}/${node}.path"
    if snapshot_exists "${snapshot_file}"; then
      continue
    fi

    if ! snapshot_host_generation "${node}" "${snapshot_file}"; then
      echo "Unable to record pre-deploy generation for ${node}; refusing deploy without rollback snapshot" >&2
      rc=1
    fi
  done

  return "${rc}"
}

rollback_host_to_snapshot() {
  local node="$1"
  local snapshot_path="$2"
  local rollback_cmd deploy_user ssh_target using_bootstrap_fallback
  local -a ssh_opts=()

  [ -n "${snapshot_path}" ] || {
    echo "Rollback snapshot is empty for ${node}" >&2
    return 1
  }

  log_host_stage "rollback" "${node}"
  prepare_deploy_context "${node}" || return 1
  ssh_target="${PREP_DEPLOY_SSH_TARGET}"
  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  ssh_opts=("${PREP_DEPLOY_SSH_OPTS[@]}")
  deploy_user="${ssh_target%%@*}"

  # shellcheck disable=SC2016
  rollback_cmd='set -euo pipefail; snap="'"${snapshot_path}"'"; if [ ! -x "${snap}/bin/switch-to-configuration" ]; then echo "snapshot is not activatable: ${snap}" >&2; exit 1; fi; if [ "$(id -u)" -eq 0 ]; then "${snap}/bin/switch-to-configuration" switch; elif command -v sudo >/dev/null 2>&1; then sudo "${snap}/bin/switch-to-configuration" switch; else echo "sudo is required for rollback as non-root user" >&2; exit 1; fi'

  echo "${snapshot_path}" >&2
  if should_ask_sudo_password "${deploy_user}" "${using_bootstrap_fallback}"; then
    ssh -tt "${ssh_opts[@]}" "${ssh_target}" "${rollback_cmd}" <"$(resolve_ssh_tty_stdin_path)"
  else
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${ssh_target}" "${rollback_cmd}"
  fi
}

rollback_successful_hosts() {
  local snapshot_dir="$1"
  local rollback_log_dir="$2"
  local rollback_status_dir="$3"
  shift 3

  local -a successful_hosts=("$@")
  local node status_file log_file rc
  local rollback_rc=0
  ROLLBACK_OK_HOSTS=()
  ROLLBACK_FAILED_HOSTS=()

  [ "${#successful_hosts[@]}" -gt 0 ] || return 0

  log_section "Phase: Rollback"
  echo "Rolling back ${#successful_hosts[@]} successful host(s) to pre-deploy generations" >&2

  for node in "${successful_hosts[@]}"; do
    status_file="$(phase_dir_item_status_file "${rollback_status_dir}" "${node}")"
    log_file="$(phase_dir_item_log_file "${rollback_log_dir}" "${node}")"

    if run_streamed_host_command "${node}" "${log_file}" rollback_host_to_snapshot "${node}" "$(cat "${snapshot_dir}/${node}.path")"; then
      write_status_file "${status_file}" 0
      ROLLBACK_OK_HOSTS+=("${node}")
    else
      rc="$?"
      write_status_file "${status_file}" "${rc}"
      ROLLBACK_FAILED_HOSTS+=("${node}")
      rollback_rc=1
    fi
  done

  if [ "${rollback_rc}" -ne 0 ]; then
    echo "Rollback failed for one or more hosts. Check logs under ${rollback_log_dir}" >&2
  fi

  return "${rollback_rc}"
}

should_ask_sudo_password() {
  local deploy_user="$1"
  local using_bootstrap_fallback="$2"

  if [ "${using_bootstrap_fallback}" -eq 1 ] || { [ "${deploy_user}" != "root" ] && [ "${deploy_user}" != "nixbot" ]; }; then
    return 0
  fi

  return 1
}

deploy_host() {
  local node="$1"
  local built_out_path="$2"
  local skip_marker="${3:-}"
  local remote_current_path ssh_target nix_sshopts using_bootstrap_fallback age_identity_key
  local deploy_user build_host=""
  local -a rebuild_cmd=()
  local -a ssh_opts=()

  log_host_stage "deploy" "${node}" "${GOAL}"
  prepare_deploy_context "${node}" || return 1
  ssh_target="${PREP_DEPLOY_SSH_TARGET}"
  nix_sshopts="${PREP_DEPLOY_NIX_SSHOPTS}"
  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"
  ssh_opts=("${PREP_DEPLOY_SSH_OPTS[@]}")
  inject_host_age_identity_key "${node}" "${ssh_target}" "${age_identity_key}" "${ssh_opts[@]}" || return 1

  deploy_user="${ssh_target%%@*}"

  if [ "${DEPLOY_IF_CHANGED}" -eq 1 ]; then
    # shellcheck disable=SC2029
    remote_current_path="$(ssh "${ssh_opts[@]}" "${ssh_target}" "readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true")"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "[${node}] deploy | skip" >&2
      echo "${built_out_path}" >&2
      if [ -n "${skip_marker}" ]; then
        : > "${skip_marker}"
      fi
      return 0
    fi
  fi

  case "${BUILD_HOST}" in
    local)
      if [ "${using_bootstrap_fallback}" -eq 1 ] || { [ -n "${DEPLOY_USER_OVERRIDE}" ] && [ "${ssh_target%%@*}" != "root" ]; }; then
        build_host="${ssh_target}"
      fi
      ;;
    target)
      build_host="${ssh_target}"
      ;;
    *)
      build_host="${BUILD_HOST}"
      ;;
  esac

  rebuild_cmd=(
    nixos-rebuild
    --flake "path:.#${node}"
    --target-host "${ssh_target}"
    --sudo
  )

  if should_ask_sudo_password "${deploy_user}" "${using_bootstrap_fallback}"; then
    rebuild_cmd+=(--ask-sudo-password)
  fi

  if [ "${using_bootstrap_fallback}" -eq 1 ]; then
    rebuild_cmd+=(--use-substitutes)
  fi

  rebuild_cmd+=("${GOAL}")

  if [ -n "${build_host}" ]; then
    rebuild_cmd+=(--build-host "${build_host}")
  fi

  if [ -n "${nix_sshopts}" ]; then
    rebuild_cmd=(env "NIX_SSHOPTS=${nix_sshopts}" "${rebuild_cmd[@]}")
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '%q ' "${rebuild_cmd[@]}"
    echo
  else
    "${rebuild_cmd[@]}"
  fi
}

run_bootstrap_key_checks() {
  local selected_json="$1"
  local -n bootstrap_ok_hosts_out_ref="$2"
  local -n bootstrap_failed_hosts_out_ref="$3"
  local node target_info bootstrap_key bootstrap_key_file
  local fpr=""
  local rc=0
  local -a selected_hosts=()

  bootstrap_ok_hosts_out_ref=()
  bootstrap_failed_hosts_out_ref=()

  json_array_to_bash_array "${selected_json}" selected_hosts

  log_section "Phase: Bootstrap Key Check"
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue

    target_info="$(resolve_deploy_target "${node}")"
    bootstrap_key="$(jq -r '.bootstrapKey // empty' <<<"${target_info}")"

    if [ -z "${bootstrap_key}" ]; then
      echo "==> ${node}: no bootstrapKey configured"
      bootstrap_ok_hosts_out_ref+=("${node}")
      continue
    fi

    if ! bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key}")"; then
      rc=1
      bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "==> ${node}: bootstrap key missing: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi

    fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2 || true)"
    if [ -z "${fpr}" ]; then
      echo "==> ${node}: bootstrap key unreadable: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi

    echo "==> ${node}: bootstrap key OK (${fpr})"
    bootstrap_ok_hosts_out_ref+=("${node}")
  done

  return "${rc}"
}

##### Host Phase Artifacts #####

init_run_dirs() {
  local base_dir="$1"
  local -n build_log_dir_out_ref="$2"
  local -n build_status_dir_out_ref="$3"
  local -n deploy_log_dir_out_ref="$4"
  local -n deploy_status_dir_out_ref="$5"
  local -n build_out_dir_out_ref="$6"
  local -n snapshot_dir_out_ref="$7"
  local -n rollback_log_dir_out_ref="$8"
  local -n rollback_status_dir_out_ref="$9"

  # shellcheck disable=SC2034
  {
    build_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "build")"
    build_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "build")"
    deploy_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "deploy")"
    deploy_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "deploy")"
    build_out_dir_out_ref="${base_dir}/build-outs"
    snapshot_dir_out_ref="${base_dir}/snapshots"
    rollback_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "rollback")"
    rollback_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "rollback")"
  }

  ensure_phase_runtime_dirs "${base_dir}" build deploy rollback
  mkdir -p "${build_out_dir_out_ref}" "${snapshot_dir_out_ref}"
}

phase_dir_path() {
  local base_dir="$1"
  local kind="$2"
  local phase="$3"

  printf '%s/%s.%s\n' "${base_dir}" "${kind}" "${phase}"
}

phase_log_dir_path() {
  phase_dir_path "$1" "logs" "$2"
}

phase_status_dir_path() {
  phase_dir_path "$1" "status" "$2"
}

phase_item_name() {
  local phase="$1"
  local item="$2"
  local subitem="${3:-}"

  case "${phase}" in
    tf)
      [ -n "${subitem}" ] || die "Missing Terraform subitem for phase item name: ${item}"
      printf '%s.%s\n' "${item}" "${subitem}"
      ;;
    *)
      printf '%s\n' "${item}"
      ;;
  esac
}

phase_item_log_file() {
  local base_dir="$1"
  local phase="$2"
  local item="$3"
  local subitem="${4:-}"

  printf '%s/%s.log\n' "$(phase_log_dir_path "${base_dir}" "${phase}")" "$(phase_item_name "${phase}" "${item}" "${subitem}")"
}

phase_item_status_file() {
  local base_dir="$1"
  local phase="$2"
  local item="$3"
  local subitem="${4:-}"

  printf '%s/%s.rc\n' "$(phase_status_dir_path "${base_dir}" "${phase}")" "$(phase_item_name "${phase}" "${item}" "${subitem}")"
}

phase_dir_item_log_file() {
  local log_dir="$1"
  local item="$2"

  printf '%s/%s.log\n' "${log_dir}" "${item}"
}

phase_dir_item_status_file() {
  local status_dir="$1"
  local item="$2"

  printf '%s/%s.rc\n' "${status_dir}" "${item}"
}

write_status_file() {
  local status_file="$1"
  local rc="$2"

  printf '%s\n' "${rc}" > "${status_file}"
}

read_status_file() {
  local status_file="$1"

  [ -s "${status_file}" ] || return 1
  cat "${status_file}"
}

ensure_phase_artifact_dirs() {
  local base_dir="$1"
  shift
  local phase=""

  for phase in "$@"; do
    [ -n "${phase}" ] || continue
    mkdir -p \
      "$(phase_log_dir_path "${base_dir}" "${phase}")" \
      "$(phase_status_dir_path "${base_dir}" "${phase}")"
  done
}

phase_artifact_dir_path() {
  local base_dir="$1"
  local phase="$2"

  printf '%s/artifacts.%s\n' "${base_dir}" "${phase}"
}

ensure_phase_runtime_dirs() {
  local base_dir="$1"
  shift
  local phase=""

  ensure_phase_artifact_dirs "${base_dir}" "$@"
  for phase in "$@"; do
    [ -n "${phase}" ] || continue
    mkdir -p "$(phase_artifact_dir_path "${base_dir}" "${phase}")"
  done
}

##### Build Phase #####

build_host() {
  local node="$1"
  local out_path

  log_host_stage "build" "${node}"
  echo "Starting local build" >&2
  if ! out_path="$(nix build --print-out-paths "path:.#nixosConfigurations.${node}.config.system.build.toplevel")"; then
    echo "Build failed for ${node}" >&2
    return 1
  fi

  [ -n "${out_path}" ] || {
    echo "Build produced no output path for ${node}" >&2
    return 1
  }

  echo "Built out path: ${out_path}" >&2
  if ! nix path-info --closure-size --human-readable "${out_path}" >&2; then
    echo "Unable to resolve closure size for ${node}: ${out_path}" >&2
    return 1
  fi

  printf '%s\n' "${out_path}"
}

eval_host_out_path() {
  local node="$1"
  local out_path

  log_host_stage "build" "${node}" "remote build"
  echo "Evaluating output path" >&2
  if ! out_path="$(nix eval --raw "path:.#nixosConfigurations.${node}.config.system.build.toplevel.outPath")"; then
    echo "Evaluation failed for ${node}" >&2
    return 1
  fi

  [ -n "${out_path}" ] || {
    echo "Evaluation produced no output path for ${node}" >&2
    return 1
  }

  echo "Planned out path: ${out_path}" >&2
  printf '%s\n' "${out_path}"
}

resolve_build_out_path() {
  local node="$1"

  if is_deploy_style_action && [ "${BUILD_HOST}" != "local" ]; then
    eval_host_out_path "${node}"
  else
    build_host "${node}"
  fi
}

run_build_phase() {
  local build_jobs="$1"
  local build_parallel="$2"
  local prioritize_bastion="$3"
  local bastion_host="$4"
  local build_log_dir="$5"
  local build_status_dir="$6"
  local build_out_dir="$7"
  local -n build_hosts_in_ref="$8"
  # shellcheck disable=SC2034
  local -n built_hosts_out_ref="$9"
  # shellcheck disable=SC2178
  local -n failed_hosts_out_ref="${10}"

  local node active_jobs=0
  local status_file out_file log_file
  local build_sync_leading_bastion=0
  local host_grouping=0
  local phase_rc=0

  if [ "${build_parallel}" -eq 0 ] && [ "${#build_hosts_in_ref[@]}" -gt 1 ]; then
    host_grouping=1
    log_grouped_phase_section "Phase: Build" "build" 1
  else
    log_grouped_phase_section "Phase: Build" "build" 0
  fi

  if [ "${build_parallel}" -eq 1 ] && [ "${prioritize_bastion}" -eq 1 ] \
    && [ "${#build_hosts_in_ref[@]}" -gt 0 ] && [ "${build_hosts_in_ref[0]}" = "${bastion_host}" ]; then
    build_sync_leading_bastion=1
    node="${bastion_host}"
    status_file="$(phase_dir_item_status_file "${build_status_dir}" "${node}")"
    out_file="${build_out_dir}/${node}.path"
    run_build_job "${node}" "${out_file}" "${status_file}"
    if ! record_phase_status "${node}" "${status_file}" built_hosts_out_ref failed_hosts_out_ref; then
      phase_rc="$?"
      if is_signal_exit_status "${phase_rc}"; then
        log_group_scope_end
        return "${phase_rc}"
      fi
    fi
  fi

  for node in "${build_hosts_in_ref[@]}"; do
    [ -n "${node}" ] || continue
    if [ "${build_sync_leading_bastion}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
      continue
    fi

    status_file="$(phase_dir_item_status_file "${build_status_dir}" "${node}")"
    out_file="${build_out_dir}/${node}.path"
    log_file=""
    if [ "${build_parallel}" -eq 1 ]; then
      log_file="$(phase_dir_item_log_file "${build_log_dir}" "${node}")"
      run_build_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
      active_jobs=$((active_jobs + 1))
      if ! wait_for_job_slot active_jobs "${build_jobs}"; then
        phase_rc="$?"
        log_group_scope_end
        return "${phase_rc}"
      fi
      continue
    fi

    run_build_job "${node}" "${out_file}" "${status_file}"
    if ! record_phase_status "${node}" "${status_file}" built_hosts_out_ref failed_hosts_out_ref; then
      phase_rc="$?"
      if is_signal_exit_status "${phase_rc}"; then
        log_group_scope_end
        return "${phase_rc}"
      fi
      break
    fi
  done

  if [ "${build_parallel}" -eq 1 ]; then
    if ! drain_job_slots active_jobs; then
      phase_rc="$?"
      log_group_scope_end
      return "${phase_rc}"
    fi
    for node in "${build_hosts_in_ref[@]}"; do
      [ -n "${node}" ] || continue
      status_file="$(phase_dir_item_status_file "${build_status_dir}" "${node}")"
      if [ "${build_sync_leading_bastion}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
        continue
      fi
      if ! record_phase_status "${node}" "${status_file}" built_hosts_out_ref failed_hosts_out_ref; then
        phase_rc="$?"
        if is_signal_exit_status "${phase_rc}"; then
          log_group_scope_end
          return "${phase_rc}"
        fi
      fi
    done
  fi

  if [ "${#failed_hosts_out_ref[@]}" -gt 0 ]; then
    print_host_failures "Build phase failed" build "${build_log_dir}" "${build_status_dir}" "${failed_hosts_out_ref[@]}"
    log_group_scope_end
    return 1
  fi

  log_group_scope_end
  return 0
}

##### Deploy Phase #####

run_deploy_phase() {
  local deploy_parallel="$1"
  local deploy_parallel_jobs="$2"
  local snapshot_dir="$3"
  local deploy_log_dir="$4"
  local deploy_status_dir="$5"
  local build_out_dir="$6"
  local rollback_log_dir="$7"
  local rollback_status_dir="$8"
  local -n level_groups_in_ref="$9"
  local -n successful_hosts_out_ref="${10}"
  # shellcheck disable=SC2034
  local -n deploy_skipped_hosts_out_ref="${11}"
  # shellcheck disable=SC2034,SC2178
  local -n snapshot_failed_hosts_out_ref="${12}"
  # shellcheck disable=SC2178
  local -n deploy_failed_hosts_out_ref="${13}"

  local level_group node active_jobs level_index=0
  local -a level_hosts=()
  local status_file out_file log_file
  local snapshot_retry_logged=0
  local deploy_wave_failed=0
  local total_deploy_hosts=0
  local level_group_size=0
  local host_grouping=0
  local phase_rc=0

  for level_group in "${level_groups_in_ref[@]}"; do
    [ -n "${level_group}" ] || continue
    level_group_size="$(jq 'length' <<<"${level_group}")"
    total_deploy_hosts=$((total_deploy_hosts + level_group_size))
  done

  if [ "${deploy_parallel}" -eq 0 ] && [ "${total_deploy_hosts}" -gt 1 ]; then
    host_grouping=1
    log_grouped_phase_section "Phase: Deploy" "deploy" 1
  else
    log_grouped_phase_section "Phase: Deploy" "deploy" 0
  fi

  for level_group in "${level_groups_in_ref[@]}"; do
    mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
    snapshot_retry_logged=0
    if log_snapshot_retry_transition "${snapshot_dir}" "${level_index}" "${level_hosts[@]}"; then
      snapshot_retry_logged=1
    fi
    if ! ensure_wave_snapshots "${snapshot_dir}" "${level_hosts[@]}"; then
      record_snapshot_failures_for_wave "${snapshot_dir}" snapshot_failed_hosts_out_ref deploy_failed_hosts_out_ref "${level_hosts[@]}"
      print_host_failures "Deploy phase failed" snapshot "" "${deploy_failed_hosts_out_ref[@]}"
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts_out_ref[@]}"
      log_group_scope_end
      return 1
    fi
    if [ "${snapshot_retry_logged}" -eq 1 ]; then
      log_grouped_phase_section "Phase: Deploy" "deploy" "${host_grouping}"
    fi

    log_subsection "Deploy Wave: $(join_by_comma "${level_hosts[@]}")"
    deploy_wave_failed=0
    active_jobs=0

    for node in "${level_hosts[@]}"; do
      [ -n "${node}" ] || continue

      status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
      out_file="${build_out_dir}/${node}.path"
      log_file=""
      if [ "${deploy_parallel}" -eq 1 ]; then
        log_file="$(phase_dir_item_log_file "${deploy_log_dir}" "${node}")"
        run_deploy_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
        active_jobs=$((active_jobs + 1))
        if ! wait_for_job_slot active_jobs "${deploy_parallel_jobs}"; then
          phase_rc="$?"
          abort_deploy_on_signal \
            "${phase_rc}" \
            "${snapshot_dir}" \
            "${deploy_status_dir}" \
            "${rollback_log_dir}" \
            "${rollback_status_dir}" \
            successful_hosts_out_ref \
            deploy_skipped_hosts_out_ref \
            deploy_failed_hosts_out_ref \
            "${level_hosts[@]}"
          phase_rc="$?"
          log_group_scope_end
          return "${phase_rc}"
        fi
        continue
      fi

      run_deploy_job "${node}" "${out_file}" "${status_file}"
      if ! record_deploy_phase_status "${node}" "${status_file}" successful_hosts_out_ref deploy_skipped_hosts_out_ref deploy_failed_hosts_out_ref; then
        phase_rc="$?"
        abort_deploy_on_signal \
          "${phase_rc}" \
          "${snapshot_dir}" \
          "${deploy_status_dir}" \
          "${rollback_log_dir}" \
          "${rollback_status_dir}" \
          successful_hosts_out_ref \
          deploy_skipped_hosts_out_ref \
          deploy_failed_hosts_out_ref \
          "${level_hosts[@]}"
        phase_rc="$?"
        if is_signal_exit_status "${phase_rc}"; then
          log_group_scope_end
          return "${phase_rc}"
        fi
        deploy_wave_failed=1
        break
      fi
    done

    if [ "${deploy_parallel}" -eq 1 ]; then
      if ! drain_job_slots active_jobs; then
        phase_rc="$?"
        abort_deploy_on_signal \
          "${phase_rc}" \
          "${snapshot_dir}" \
          "${deploy_status_dir}" \
          "${rollback_log_dir}" \
          "${rollback_status_dir}" \
          successful_hosts_out_ref \
          deploy_skipped_hosts_out_ref \
          deploy_failed_hosts_out_ref \
          "${level_hosts[@]}"
        phase_rc="$?"
        log_group_scope_end
        return "${phase_rc}"
      fi
      for node in "${level_hosts[@]}"; do
        [ -n "${node}" ] || continue
        status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
        if ! record_deploy_phase_status "${node}" "${status_file}" successful_hosts_out_ref deploy_skipped_hosts_out_ref deploy_failed_hosts_out_ref; then
          phase_rc="$?"
          abort_deploy_on_signal \
            "${phase_rc}" \
            "${snapshot_dir}" \
            "${deploy_status_dir}" \
            "${rollback_log_dir}" \
            "${rollback_status_dir}" \
            successful_hosts_out_ref \
            deploy_skipped_hosts_out_ref \
            deploy_failed_hosts_out_ref \
            "${level_hosts[@]}"
          phase_rc="$?"
          if is_signal_exit_status "${phase_rc}"; then
            log_group_scope_end
            return "${phase_rc}"
          fi
        fi
      done
      if [ "${#deploy_failed_hosts_out_ref[@]}" -gt 0 ]; then
        deploy_wave_failed=1
      fi
    fi

    if [ "${deploy_wave_failed}" -eq 1 ]; then
      if [ "${deploy_parallel}" -eq 1 ]; then
        print_host_failures "Deploy phase failed" deploy "${deploy_log_dir}" "${deploy_failed_hosts_out_ref[@]}"
      else
        print_host_failures "Deploy phase failed" plain "" "${deploy_failed_hosts_out_ref[@]}"
      fi
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts_out_ref[@]}"
      log_group_scope_end
      return 1
    fi

    level_index=$((level_index + 1))
  done

  log_group_scope_end
  return 0
}

capture_current_run_summary_state() {
  local action="$1"
  local selected_hosts_name="$2"
  local build_ok_hosts_name="$3"
  local build_failed_hosts_name="$4"
  local snapshot_failed_hosts_name="$5"
  local deploy_ok_hosts_name="$6"
  local deploy_skipped_hosts_name="$7"
  local deploy_failed_hosts_name="$8"

  set_run_summary_host_state \
    "${action}" \
    "${selected_hosts_name}" \
    "${build_ok_hosts_name}" \
    "${build_failed_hosts_name}" \
    "${snapshot_failed_hosts_name}" \
    "${deploy_ok_hosts_name}" \
    "${deploy_skipped_hosts_name}" \
    "${deploy_failed_hosts_name}" \
    ROLLBACK_OK_HOSTS \
    ROLLBACK_FAILED_HOSTS
}

run_hosts() {
  local selected_json="$1"
  local bastion_host="${BASTION_TRIGGER_HOST}"
  # shellcheck disable=SC2034
  local -a selected_hosts=() failed_hosts=() successful_hosts=() built_hosts=() snapshot_failed_hosts=() deploy_skipped_hosts=() deploy_failed_hosts=() build_hosts=() level_groups=() bootstrap_ok_hosts=() bootstrap_failed_hosts=()

  local build_log_dir build_status_dir deploy_log_dir deploy_status_dir
  local build_out_dir snapshot_dir rollback_log_dir rollback_status_dir
  local levels_json
  local final_rc=0
  local build_parallel=0
  local deploy_parallel=0

  if is_bootstrap_check_action; then
    json_array_to_bash_array "${selected_json}" selected_hosts
    if ! run_bootstrap_key_checks "${selected_json}" bootstrap_ok_hosts bootstrap_failed_hosts; then
      final_rc=1
    fi
    capture_current_run_summary_state \
      "${ACTION}" \
      selected_hosts \
      bootstrap_ok_hosts \
      bootstrap_failed_hosts \
      snapshot_failed_hosts \
      successful_hosts \
      deploy_skipped_hosts \
      deploy_failed_hosts
    return "${final_rc}"
  fi

  json_array_to_bash_array "${selected_json}" selected_hosts
  levels_json="$(selected_host_levels_json "${selected_json}")"
  mapfile -t level_groups < <(jq -c '.[]' <<<"${levels_json}")
  # shellcheck disable=SC2034
  build_hosts=("${selected_hosts[@]}")
  if [ "${BUILD_JOBS}" -gt 1 ]; then
    build_parallel=1
  fi
  if [ "${DEPLOY_PARALLEL_JOBS}" -gt 1 ]; then
    deploy_parallel=1
  fi

  ensure_tmp_dir
  init_run_dirs \
    "${DEPLOY_TMP_DIR}" \
    build_log_dir \
    build_status_dir \
    deploy_log_dir \
    deploy_status_dir \
    build_out_dir \
    snapshot_dir \
    rollback_log_dir \
    rollback_status_dir

  if ! run_build_phase \
    "${BUILD_JOBS}" \
    "${build_parallel}" \
    "${PRIORITIZE_BASTION_FIRST}" \
    "${bastion_host}" \
    "${build_log_dir}" \
    "${build_status_dir}" \
    "${build_out_dir}" \
    build_hosts \
    built_hosts \
    failed_hosts; then
    final_rc=1
  fi

  if is_host_build_only_action || [ "${final_rc}" -ne 0 ]; then
    capture_current_run_summary_state \
      "${ACTION}" \
      selected_hosts \
      built_hosts \
      failed_hosts \
      snapshot_failed_hosts \
      successful_hosts \
      deploy_skipped_hosts \
      deploy_failed_hosts
    return "${final_rc}"
  fi

  # Snapshot phase.
  if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ]; then
    log_section "Phase: Snapshot"
    if [ "${#level_groups[@]}" -gt 0 ]; then
      run_initial_snapshot_wave "${level_groups[0]}" "${snapshot_dir}"
    fi
  fi

  failed_hosts=()
  successful_hosts=()

  if ! run_deploy_phase \
    "${deploy_parallel}" \
    "${DEPLOY_PARALLEL_JOBS}" \
    "${snapshot_dir}" \
    "${deploy_log_dir}" \
    "${deploy_status_dir}" \
    "${build_out_dir}" \
    "${rollback_log_dir}" \
    "${rollback_status_dir}" \
    level_groups \
    successful_hosts \
    deploy_skipped_hosts \
    snapshot_failed_hosts \
    deploy_failed_hosts; then
    final_rc=1
  fi

  capture_current_run_summary_state \
    "${ACTION}" \
    selected_hosts \
    built_hosts \
    failed_hosts \
    snapshot_failed_hosts \
    successful_hosts \
    deploy_skipped_hosts \
    deploy_failed_hosts
  return "${final_rc}"
}

##### Terraform #####

load_tf_backend_runtime_secrets() {
  local var_name decrypted_file
  local -A _tf_backend_secrets=(
    [R2_ACCOUNT_ID]="${TF_R2_ACCOUNT_ID_PATH}"
    [R2_STATE_BUCKET]="${TF_R2_STATE_BUCKET_PATH}"
    [R2_ACCESS_KEY_ID]="${TF_R2_ACCESS_KEY_ID_PATH}"
    [R2_SECRET_ACCESS_KEY]="${TF_R2_SECRET_ACCESS_KEY_PATH}"
  )

  for var_name in "${!_tf_backend_secrets[@]}"; do
    if [ -z "${!var_name:-}" ]; then
      decrypted_file="$(resolve_runtime_key_file "${_tf_backend_secrets[${var_name}]}" 1)"
      set_env_from_file_if_unset "${var_name}" "${decrypted_file}"
    fi
  done
}

load_cloudflare_tf_runtime_secrets() {
  local decrypted_file=""

  if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
    decrypted_file="$(resolve_runtime_key_file "${TF_CLOUDFLARE_API_TOKEN_PATH}" 1)"
    set_env_from_file_if_unset "CLOUDFLARE_API_TOKEN" "${decrypted_file}"
  fi
}

tf_project_name_from_dir() {
  basename "$1"
}

tf_project_provider_from_name() {
  local project_name="$1"
  printf '%s\n' "${project_name%-*}"
}

tf_project_dirs_for_phase() {
  local phase="$1"
  local project_name=""

  if [ -n "${TF_WORK_DIR}" ]; then
    project_name="$(tf_project_name_from_dir "${TF_WORK_DIR}")"
    if [[ "${project_name}" == *-"${phase}" ]]; then
      printf '%s\n' "${TF_WORK_DIR}"
    fi
    return 0
  fi

  find tf -mindepth 1 -maxdepth 1 -type d -name "*-${phase}" | sort
}

tf_state_key_for_project() {
  local project_name="$1"

  if [ -n "${R2_STATE_KEY:-}" ]; then
    printf '%s\n' "${R2_STATE_KEY}"
    return 0
  fi

  printf '%s/terraform.tfstate\n' "${project_name}"
}

emit_tf_secret_paths_for_project() {
  local project_name="$1"
  local cf="${TF_SECRETS_DIR}/cloudflare"
  local dir

  [ -f "${TF_SECRETS_DIR}/${project_name}.tfvars.age" ] && printf '%s\n' "${TF_SECRETS_DIR}/${project_name}.tfvars.age"
  [ -d "${TF_SECRETS_DIR}/${project_name}" ] && find "${TF_SECRETS_DIR}/${project_name}" -type f -name '*.tfvars.age' | sort

  case "${project_name}" in
    cloudflare-dns)
      [ -d "${cf}/dns" ] && find "${cf}/dns" -type f -name '*.tfvars.age' | sort
      ;;
    cloudflare-platform)
      [ -f "${cf}/secrets.tfvars.age" ] && printf '%s\n' "${cf}/secrets.tfvars.age"
      for dir in account access tunnels r2 zone-dnssec zone-settings zone-security rulesets page-rules email-routing; do
        [ -d "${cf}/${dir}" ] && find "${cf}/${dir}" -type f -name '*.tfvars.age' | sort
      done
      ;;
    cloudflare-apps)
      [ -f "${cf}/secrets.tfvars.age" ] && printf '%s\n' "${cf}/secrets.tfvars.age"
      [ -d "${cf}/account" ] && find "${cf}/account" -type f -name '*.tfvars.age' | sort
      [ -d "${cf}/workers" ] && find "${cf}/workers" -type f -name '*.tfvars.age' | sort
      ;;
  esac
}

load_tf_runtime_secrets_for_project() {
  local project_name="$1"
  local provider_name

  load_tf_backend_runtime_secrets

  provider_name="$(tf_project_provider_from_name "${project_name}")"
  case "${provider_name}" in
    cloudflare)
      load_cloudflare_tf_runtime_secrets
      ;;
  esac
}

require_tf_runtime_env_for_project() {
  local project_name="$1"
  local provider_name

  [ -n "${R2_ACCOUNT_ID:-}" ] || die "Missing required environment variable: R2_ACCOUNT_ID"
  [ -n "${R2_STATE_BUCKET:-}" ] || die "Missing required environment variable: R2_STATE_BUCKET"
  [ -n "${R2_ACCESS_KEY_ID:-}" ] || die "Missing required environment variable: R2_ACCESS_KEY_ID"
  [ -n "${R2_SECRET_ACCESS_KEY:-}" ] || die "Missing required environment variable: R2_SECRET_ACCESS_KEY"

  provider_name="$(tf_project_provider_from_name "${project_name}")"
  case "${provider_name}" in
    cloudflare)
      [ -n "${CLOUDFLARE_API_TOKEN:-}" ] || die "Missing required environment variable: CLOUDFLARE_API_TOKEN"
      ;;
  esac
}

is_tf_candidate_path_for_project() {
  local phase="$1"
  local project_name="$2"
  local path="$3"
  local provider_name

  provider_name="$(tf_project_provider_from_name "${project_name}")"

  case "${path}" in
    "tf/${project_name}"|"tf/${project_name}/"*) return 0 ;;
    "tf/modules/${provider_name}"|"tf/modules/${provider_name}/"*) return 0 ;;
    "data/secrets/${provider_name}"|"data/secrets/${provider_name}/"*) return 0 ;;
    "data/secrets/tf/${provider_name}"|"data/secrets/tf/${provider_name}/"*) return 0 ;;
    "data/secrets/cloudflare/r2-account-id.key.age"|"data/secrets/cloudflare/r2-state-bucket.key.age"|"data/secrets/cloudflare/r2-access-key-id.key.age"|"data/secrets/cloudflare/r2-secret-access-key.key.age") return 0 ;;
  esac

  if [ "${phase}" = "apps" ]; then
    case "${path}" in
      services|services/*) return 0 ;;
    esac
  fi

  return 1
}

resolve_tf_project_dir() {
  local project_dir="$1"

  if [[ "${project_dir}" != /* ]]; then
    project_dir="$(pwd -P)/${project_dir}"
  fi

  [ -d "${project_dir}" ] || die "Terraform directory not found: ${project_dir}"
  printf '%s\n' "${project_dir}"
}

resolve_tf_project_context() {
  local input_dir="$1"
  local require_repo_project="${2:-1}"
  local -n project_dir_out_ref="$3"
  local -n project_name_out_ref="$4"
  local -n provider_name_out_ref="$5"
  local _pname=""

  project_dir_out_ref="$(resolve_tf_project_dir "${input_dir}")"
  project_name_out_ref=""
  provider_name_out_ref=""

  _pname="$(tf_project_name_from_dir "${project_dir_out_ref}")"
  if [[ "${_pname}" != *-* ]] || [ "$(basename "$(dirname "${project_dir_out_ref}")")" != "tf" ]; then
    [ "${require_repo_project}" -eq 1 ] && return 1
    return 0
  fi

  # shellcheck disable=SC2034
  project_name_out_ref="${_pname}"
  # shellcheck disable=SC2034
  provider_name_out_ref="$(tf_project_provider_from_name "${_pname}")"
}

prepare_tf_project_runtime() {
  local project_name="$1"

  prepare_tf_apps_project_runtime "${project_name}"
  load_tf_runtime_secrets_for_project "${project_name}"
  require_tf_runtime_env_for_project "${project_name}"
}

tf_project_apps_package_dir() {
  local project_name="$1"
  local project_pkg_dir="pkgs/${project_name}"

  [[ "${project_name}" == *-apps ]] || return 1
  [ -f "${project_pkg_dir}/flake.nix" ] || return 1

  printf '%s\n' "${project_pkg_dir}"
}

prepare_tf_apps_project_runtime() {
  local project_name="$1"
  local project_pkg_dir=""

  if ! project_pkg_dir="$(tf_project_apps_package_dir "${project_name}")"; then
    return 0
  fi

  echo "Preparing Terraform apps package build: ${project_name}" >&2
  nix build "path:${project_pkg_dir}#build" --no-link
}
collect_tf_var_files_for_project() {
  local project_name="$1"
  local -n tf_var_files_out_ref="$2"
  local -n discovered_tf_var_files_out_ref="$3"
  local log_discovered_paths="${4:-0}"
  local tf_var_path=""
  local resolved_tf_var_file=""

  tf_var_files_out_ref=()
  discovered_tf_var_files_out_ref=0

  while IFS= read -r tf_var_path; do
    discovered_tf_var_files_out_ref=$((discovered_tf_var_files_out_ref + 1))
    if [ "${log_discovered_paths}" -eq 1 ]; then
      echo "Sensitive tfvars: ${tf_var_path}" >&2
    fi
    resolved_tf_var_file="$(resolve_runtime_key_file "${tf_var_path}")"
    if [ -f "${resolved_tf_var_file}" ]; then
      tf_var_files_out_ref+=("${resolved_tf_var_file}")
    elif [ "${log_discovered_paths}" -eq 1 ]; then
      echo "Sensitive tfvars: ${tf_var_path} not present" >&2
    fi
  done < <(emit_tf_secret_paths_for_project "${project_name}" | sort -u)
}

append_tf_var_files_to_cmd() {
  local -n cmd_inout_ref="$1"
  shift
  local tf_var_file=""

  for tf_var_file in "$@"; do
    cmd_inout_ref+=("-var-file=${tf_var_file}")
  done
}

tf_backend_endpoint() {
  printf 'https://%s.r2.cloudflarestorage.com\n' "${R2_ACCOUNT_ID}"
}

should_run_tf_project_action() {
  local phase="$1"
  local project_name="$2"
  local target_ref base_ref diff_output diff_status=0
  local path=""
  local status_output=""
  local status_path=""

  if [ "${TF_IF_CHANGED}" -eq 0 ]; then
    echo "Terraform change detection bypassed by --force" >&2
    return 0
  fi

  target_ref="${SHA:-HEAD}"
  if ! git rev-parse --verify "${target_ref}" >/dev/null 2>&1; then
    echo "Terraform change detection unavailable for ${target_ref}; running TF ${phase}" >&2
    return 0
  fi

  if ! base_ref="$(resolve_tf_change_base_ref "${target_ref}")"; then
    echo "Terraform change base unavailable for ${target_ref}; running TF ${phase}" >&2
    return 0
  fi

  diff_output="$(git diff --name-only "${base_ref}" "${target_ref}" -- 2>/dev/null)" || diff_status=$?
  if [ "${diff_status}" -ne 0 ]; then
    echo "Terraform change detection failed for ${base_ref}..${target_ref}; running TF ${phase}" >&2
    return 0
  fi

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    if is_tf_candidate_path_for_project "${phase}" "${project_name}" "${path}"; then
      echo "Terraform ${project_name} change detected: ${path}" >&2
      return 0
    fi
  done <<< "${diff_output}"

  status_output="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  while IFS= read -r status_path; do
    [ -n "${status_path}" ] || continue
    status_path="${status_path#?? }"
    status_path="${status_path##* -> }"
    if is_tf_candidate_path_for_project "${phase}" "${project_name}" "${status_path}"; then
      echo "Terraform ${project_name} working tree change detected: ${status_path}" >&2
      return 0
    fi
  done <<< "${status_output}"

  echo "Terraform ${project_name} unchanged; skipping TF action" >&2
  return 1
}

resolve_tf_change_base_ref() {
  local target_ref="${1:-HEAD}"
  local target_commit=""
  local base_commit=""

  if ! git rev-parse --verify "${target_ref}" >/dev/null 2>&1; then
    return 1
  fi
  target_commit="$(git rev-parse --verify "${target_ref}" 2>/dev/null || true)"

  if [ -n "${TF_CHANGE_BASE_REF}" ] && git rev-parse --verify "${TF_CHANGE_BASE_REF}" >/dev/null 2>&1; then
    base_commit="$(git rev-parse --verify "${TF_CHANGE_BASE_REF}" 2>/dev/null || true)"
    if [ -n "${base_commit}" ] && [ "${base_commit}" != "${target_commit}" ]; then
      printf '%s\n' "${TF_CHANGE_BASE_REF}"
      return 0
    fi
  fi

  if git rev-parse --verify "${target_ref}^1" >/dev/null 2>&1; then
    printf '%s^1\n' "${target_ref}"
    return 0
  fi
  return 1
}

run_tf_phases() {
  local phase=""

  for phase in "$@"; do
    [ -n "${phase}" ] || continue
    if ! run_requested_tf_phase "${phase}"; then
      return 1
    fi
  done
}

tofu_args_extract_subcommand() {
  local -a args=("$@")
  local i arg

  for ((i=0; i<${#args[@]}; i++)); do
    arg="${args[$i]}"
    case "${arg}" in
      -chdir)
        i=$((i + 1))
        ;;
      -chdir=*|-help|--help|-version|--version)
        ;;
      -*)
        ;;
      *)
        printf '%s\n' "${arg}"
        return 0
        ;;
    esac
  done

  return 1
}

tofu_args_have_explicit_vars() {
  local -a args=("$@")
  local arg

  for arg in "${args[@]}"; do
    case "${arg}" in
      -var|-var=*|-var-file|-var-file=*)
        return 0
        ;;
    esac
  done

  return 1
}

tofu_subcommand_supports_var_files() {
  local subcommand="${1:-}"

  case "${subcommand}" in
    plan|apply|destroy|import|console)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_tofu_auto_var_file_subcommand() {
  local -n subcommand_out_ref="$1"
  shift
  local subcommand=""

  subcommand_out_ref=""

  if ! subcommand="$(tofu_args_extract_subcommand "$@")"; then
    return 1
  fi

  if ! tofu_subcommand_supports_var_files "${subcommand}"; then
    return 1
  fi

  if tofu_args_have_explicit_vars "$@"; then
    return 1
  fi

  # shellcheck disable=SC2034
  subcommand_out_ref="${subcommand}"
}

_exec_tofu_cmd() {
  local project_name="${1:-}"
  shift
  local subcommand=""
  local discovered_tf_var_files=0
  local -a cmd=()
  local -a tf_var_files=()

  cmd=(tofu "$@")

  if [ -n "${project_name}" ] && resolve_tofu_auto_var_file_subcommand subcommand "$@"; then
    collect_tf_var_files_for_project "${project_name}" tf_var_files discovered_tf_var_files 1

    if [ "${discovered_tf_var_files}" -eq 0 ]; then
      echo "Sensitive tfvars: no *.tfvars.age files found under ${TF_SECRETS_DIR}" >&2
    fi

    append_tf_var_files_to_cmd cmd "${tf_var_files[@]}"

    if [ "${#tf_var_files[@]}" -gt 0 ]; then
      echo "Terraform ${project_name}: appended ${#tf_var_files[@]} decrypted var-file(s) for ${subcommand}" >&2
    fi
  fi

  run_with_combined_output "${cmd[@]}"
}

log_tf_action_context() {
  local phase="$1"
  local project_name="$2"
  local tf_dir="$3"
  local state_key="$4"
  local endpoint="$5"

  echo "Working dir: ${tf_dir}" >&2
  echo "State bucket: ${R2_STATE_BUCKET}" >&2
  echo "State key: ${state_key}" >&2
  echo "Endpoint: ${endpoint}" >&2
}

run_tf_action() {
  local phase="$1"
  local project_dir="$2"
  local project_name="" provider_name="" tf_dir=""
  local state_key="" endpoint="" plan_file

  resolve_tf_project_context "${project_dir}" 1 tf_dir project_name provider_name
  prepare_tf_project_runtime "${project_name}"

  state_key="$(tf_state_key_for_project "${project_name}")"
  endpoint="$(tf_backend_endpoint)"
  log_tf_action_context "${phase}" "${project_name}" "${tf_dir}" "${state_key}" "${endpoint}"

  # Init (no var-file injection needed)
  _exec_tofu_cmd "" -chdir="${tf_dir}" init \
    -lockfile=readonly \
    -backend-config="bucket=${R2_STATE_BUCKET}" \
    -backend-config="key=${state_key}" \
    -backend-config="region=auto" \
    -backend-config="endpoint=${endpoint}" \
    -backend-config="access_key=${R2_ACCESS_KEY_ID}" \
    -backend-config="secret_key=${R2_SECRET_ACCESS_KEY}" \
    -backend-config="skip_credentials_validation=true" \
    -backend-config="skip_region_validation=true" \
    -backend-config="skip_requesting_account_id=true" \
    -backend-config="use_path_style=true"

  if [ "${DRY_RUN}" -eq 1 ]; then
    _exec_tofu_cmd "${project_name}" -chdir="${tf_dir}" plan -input=false
    return
  fi

  ensure_tmp_dir
  plan_file="$(tmp_runtime_mktemp tf "tfplan.XXXXXX")"
  _exec_tofu_cmd "${project_name}" -chdir="${tf_dir}" plan -input=false -out="${plan_file}"
  # Apply saved plan (no var-file injection)
  _exec_tofu_cmd "" -chdir="${tf_dir}" apply -input=false -auto-approve "${plan_file}"
}

log_tf_project_status() {
  local project_name="$1"
  local status="$2"

  echo "Terraform ${project_name}: ${status}" >&2
}

run_tf_project_action() {
  local phase="$1"
  local project_name="$2"
  local project_dir="$3"
  local log_file="" status_file="" rc=0

  log_grouped_nested_item_start "$(log_group_tf_project_title "${phase}" "${project_name}")"
  log_subsection "Terraform Project: ${project_name}"
  ensure_tmp_dir
  log_file="$(phase_item_log_file "${DEPLOY_TMP_DIR}" "tf" "${phase}" "${project_name}")"
  status_file="$(phase_item_status_file "${DEPLOY_TMP_DIR}" "tf" "${phase}" "${project_name}")"
  if run_tf_action "${phase}" "${project_dir}" > >(tee -a "${log_file}") 2>&1; then
    write_status_file "${status_file}" 0
  else
    rc="$?"
    write_status_file "${status_file}" "${rc}"
  fi
  log_grouped_item_end
  [ "${rc}" -eq 0 ]
}

tofu_wrapper_extract_chdir() {
  local -a args=("$@")
  local i arg

  for ((i=0; i<${#args[@]}; i++)); do
    arg="${args[$i]}"
    case "${arg}" in
      -chdir=*)
        printf '%s\n' "${arg#-chdir=}"
        return 0
        ;;
      -chdir)
        if [ $((i + 1)) -lt ${#args[@]} ]; then
          printf '%s\n' "${args[$((i + 1))]}"
          return 0
        fi
        ;;
    esac
  done

  return 1
}

resolve_tofu_wrapper_context() {
  local project_dir_name="$1"
  local project_name_name="$2"
  local provider_name_name="$3"
  shift 3
  local chdir_arg=""
  local input_dir=""

  chdir_arg="$(tofu_wrapper_extract_chdir "$@" || true)"
  input_dir="${chdir_arg:-$(pwd -P)}"
  resolve_tf_project_context "${input_dir}" 0 "${project_dir_name}" "${project_name_name}" "${provider_name_name}"
}

run_tofu_wrapper() {
  local -a tofu_args=("$@")
  local project_dir="" project_name="" provider_name=""

  [ "${#tofu_args[@]}" -gt 0 ] || die "Usage: scripts/nixbot-deploy.sh tofu <tofu-args...>"
  [ -z "${SSH_ORIGINAL_COMMAND:-}" ] || die "The nixbot-deploy tofu wrapper is local-only and cannot run via SSH forced-command/bastion trigger."

  if resolve_tofu_wrapper_context project_dir project_name provider_name "${tofu_args[@]}" && [ -n "${project_name}" ]; then
    prepare_tf_project_runtime "${project_name}"
    echo "Terraform wrapper project: ${project_name} (${provider_name})" >&2
  fi

  _exec_tofu_cmd "${project_name}" "${tofu_args[@]}"
}

run_requested_tf_phase() {
  local phase="$1"
  local project_dir=""
  local found=0
  local project_name=""
  local project_rc=0

  log_section "Phase: Terraform (${phase})"

  while IFS= read -r project_dir; do
    [ -n "${project_dir}" ] || continue
    found=1
    project_name="$(tf_project_name_from_dir "${project_dir}")"
    project_rc=0

    if should_run_tf_project_action "${phase}" "${project_name}"; then
      if run_tf_project_action "${phase}" "${project_name}" "${project_dir}"; then
        log_tf_project_status "${project_name}" "ok"
        record_tf_run_summary "${phase}" "${project_name}" "ok"
      else
        log_tf_project_status "${project_name}" "fail"
        record_tf_run_summary "${phase}" "${project_name}" "fail"
        project_rc=1
      fi
    else
      log_tf_project_status "${project_name}" "skip"
      record_tf_run_summary "${phase}" "${project_name}" "skip"
    fi

    if [ "${project_rc}" -ne 0 ]; then
      return 1
    fi
  done < <(tf_project_dirs_for_phase "${phase}")

  if [ "${found}" -eq 0 ]; then
    echo "No Terraform ${phase} projects found; skipping" >&2
  fi
}

run_tf_only_action() {
  case "${ACTION}" in
    tf)
      run_tf_phases dns platform apps
      ;;
    tf-dns)
      run_tf_phases dns
      ;;
    tf-platform)
      run_tf_phases platform
      ;;
    tf-apps)
      run_tf_phases apps
      ;;
    *)
      die "Unsupported Terraform-only action: ${ACTION}"
      ;;
  esac
}

##### Logging #####

host_phase_border() {
  local phase="$1"

  case "${phase}" in
    build)
      printf '%s' '>>>>>>>>>>'
      ;;
    snapshot)
      printf '%s' '----------'
      ;;
    deploy)
      printf '%s' '++++++++++'
      ;;
    rollback)
      printf '%s' '!!!!!!!!!!'
      ;;
    remote-trigger)
      printf '%s' '^^^^^^^^^^'
      ;;
    repo-reexec)
      printf '%s' '##########'
      ;;
    bootstrap-check)
      printf '%s' '??????????'
      ;;
    *)
      printf '%s' '=========='
      ;;
  esac
}

log_heading() {
  local level="$1"
  local title="$2"
  local group_mode="${3:-auto}"

  case "${level}" in
    section)
      if is_github_actions_log_mode; then
        log_group_end
        if log_group_should_section "${title}" "${group_mode}"; then
          log_group_start "${title}"
        fi
      fi
      printf '\n========== %s ==========\n' "${title}" >&2
      ;;
    subsection)
      printf -- '--- %s ---\n' "${title}" >&2
      ;;
    *)
      die "Unsupported log heading level: ${level}"
      ;;
  esac
}

log_section() {
  local title="$1"
  local group_mode="${2:-auto}"

  log_heading section "${title}" "${group_mode}"
}

log_group_start() {
  local title="$1"

  printf '::group::%s\n' "${title}" >&2
  _NIXBOT_LOG_GROUP_DEPTH=$((_NIXBOT_LOG_GROUP_DEPTH + 1))
}

log_group_end() {
  if is_github_actions_log_mode && [ "${_NIXBOT_LOG_GROUP_DEPTH:-0}" -gt 0 ]; then
    printf '::endgroup::\n' >&2
    _NIXBOT_LOG_GROUP_DEPTH=$((_NIXBOT_LOG_GROUP_DEPTH - 1))
  fi
}

log_group_end_all() {
  while is_github_actions_log_mode && [ "${_NIXBOT_LOG_GROUP_DEPTH:-0}" -gt 0 ]; do
    log_group_end
  done
}

log_group_should_section() {
  local title="$1"
  local group_mode="${2:-auto}"

  case "${group_mode}" in
    none)
      return 1
      ;;
  esac

  case "${title}" in
    "Phase: Build"|"Phase: Snapshot"|"Phase: Deploy"|"Phase: Rollback"|"Phase: Bootstrap Key Check")
      return 0
      ;;
    "Phase: Terraform ("*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

log_subsection() {
  local title="$1"

  log_heading subsection "${title}"
}

log_grouped_item_start() {
  local group_title="$1"

  if is_github_actions_log_mode; then
    log_group_end
    log_group_start "${group_title}"
  fi
}

log_grouped_nested_item_start() {
  local group_title="$1"

  if is_github_actions_log_mode; then
    log_group_start "${group_title}"
  fi
}

log_grouped_item_end() {
  if is_github_actions_log_mode; then
    log_group_end
  fi
}

log_group_tf_project_title() {
  local phase="$1"
  local project_name="$2"

  printf 'Phase: Terraform (%s) / %s\n' "${phase}" "${project_name}"
}

log_host_stage() {
  local phase="$1"
  local node="$2"
  local extra="${3:-}"
  local border

  if log_group_scope_matches "${phase}"; then
    log_grouped_item_start "$(log_group_host_stage_title "${phase}" "${node}")"
  fi

  border="$(host_phase_border "${phase}")"

  printf '\n%s %s | %s %s\n' "${border}" "${node}" "${phase}" "${border}" >&2
  if [ -n "${extra}" ]; then
    printf '[%s] %s | %s\n' "${node}" "${phase}" "${extra}" >&2
  else
    printf '[%s] %s\n' "${node}" "${phase}" >&2
  fi
}

log_group_scope_start() {
  _NIXBOT_LOG_GROUP_SCOPE="$1"
}

log_group_scope_end() {
  _NIXBOT_LOG_GROUP_SCOPE=""
}

log_grouped_phase_section() {
  local title="$1"
  local scope="$2"
  local grouped="$3"

  if [ "${grouped}" -eq 1 ]; then
    log_group_scope_start "${scope}"
    log_section "${title}" none
  else
    log_group_scope_end
    log_section "${title}"
  fi
}

log_group_scope_matches() {
  local scope="$1"

  is_github_actions_log_mode || return 1
  [ -n "${_NIXBOT_LOG_GROUP_SCOPE:-}" ] || return 1
  [ "${_NIXBOT_LOG_GROUP_SCOPE}" = "${scope}" ]
}

log_group_end_host_stage() {
  local phase="$1"

  if log_group_scope_matches "${phase}"; then
    log_grouped_item_end
  fi
}

log_group_host_stage_title() {
  local phase="$1"
  local node="$2"
  local phase_title=""

  case "${phase}" in
    build)
      phase_title="Build"
      ;;
    deploy)
      phase_title="Deploy"
      ;;
    snapshot)
      phase_title="Snapshot"
      ;;
    rollback)
      phase_title="Rollback"
      ;;
    bootstrap-check)
      phase_title="Bootstrap Key Check"
      ;;
    *)
      phase_title="${phase}"
      ;;
  esac

  printf 'Phase: %s / %s\n' "${phase_title}" "${node}"
}

join_by_comma() {
  local first=1 item

  for item in "$@"; do
    [ -n "${item}" ] || continue
    if [ "${first}" -eq 1 ]; then
      printf '%s' "${item}"
      first=0
    else
      printf ', %s' "${item}"
    fi
  done

  if [ "${first}" -eq 1 ]; then
    printf '(none)'
  fi
}

print_host_block() {
  local title="$1"
  shift
  local item

  echo "${title}:" >&2
  if [ "$#" -eq 0 ]; then
    echo "  - (none)" >&2
    return
  fi

  for item in "$@"; do
    [ -n "${item}" ] || continue
    echo "  - ${item}" >&2
  done
}

prefix_host_logs() {
  local node="$1"
  awk -v node="${node}" '{ if (length($0) == 0) { print ""; } else { print "| " node " | " $0; } fflush(); }'
}

host_log_filter() {
  local node="$1"

  if [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
    prefix_host_logs "${node}"
  else
    cat
  fi
}

run_with_combined_output() {
  (
    exec 2>&1
    "$@"
  )
}

array_contains() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    [ "${item}" = "${needle}" ] && return 0
  done

  return 1
}

host_final_status() {
  local action="$1"
  local node="$2"
  local build_ok_hosts_name="$3"
  local build_failed_hosts_name="$4"
  local snapshot_failed_hosts_name="$5"
  local deploy_ok_hosts_name="$6"
  local deploy_skipped_hosts_name="$7"
  local deploy_failed_hosts_name="$8"
  local rollback_ok_hosts_name="$9"
  local rollback_failed_hosts_name="${10}"
  local -n build_ok_hosts_in_ref="${build_ok_hosts_name}"
  local -n build_failed_hosts_in_ref="${build_failed_hosts_name}"
  # shellcheck disable=SC2178
  local -n snapshot_failed_hosts_in_ref="${snapshot_failed_hosts_name}"
  local -n deploy_ok_hosts_in_ref="${deploy_ok_hosts_name}"
  local -n deploy_skipped_hosts_in_ref="${deploy_skipped_hosts_name}"
  # shellcheck disable=SC2178
  local -n deploy_failed_hosts_in_ref="${deploy_failed_hosts_name}"
  local -n rollback_ok_hosts_in_ref="${rollback_ok_hosts_name}"
  local -n rollback_failed_hosts_in_ref="${rollback_failed_hosts_name}"

  if array_contains "${node}" "${build_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (build)'
    return
  fi

  if [ "${action}" = "build" ] || [ "${action}" = "check-bootstrap" ]; then
    if array_contains "${node}" "${build_ok_hosts_in_ref[@]}"; then
      printf '%s' 'ok'
    else
      printf '%s' 'FAIL'
    fi
    return
  fi

  if array_contains "${node}" "${rollback_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (rollback)'
  elif array_contains "${node}" "${snapshot_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (snapshot)'
  elif array_contains "${node}" "${deploy_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (deploy)'
  elif array_contains "${node}" "${rollback_ok_hosts_in_ref[@]}"; then
    printf '%s' 'rolled back'
  elif array_contains "${node}" "${deploy_skipped_hosts_in_ref[@]}"; then
    printf '%s' 'ok (skip)'
  elif array_contains "${node}" "${deploy_ok_hosts_in_ref[@]}"; then
    printf '%s' 'ok'
  elif array_contains "${node}" "${build_ok_hosts_in_ref[@]}"; then
    printf '%s' 'built'
  else
    printf '%s' 'FAIL'
  fi
}

tf_summary_display_status() {
  local status="$1"

  case "${status}" in
    fail)
      printf '%s' 'FAIL'
      ;;
    skip)
      printf '%s' 'skip'
      ;;
    *)
      printf '%s' 'ok'
      ;;
  esac
}

run_summary_has_failures() {
  local tf_status

  if [ "${#RUN_SUMMARY_BUILD_FAILED_HOSTS[@]}" -gt 0 ] \
    || [ "${#RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS[@]}" -gt 0 ] \
    || [ "${#RUN_SUMMARY_DEPLOY_FAILED_HOSTS[@]}" -gt 0 ] \
    || [ "${#RUN_SUMMARY_ROLLBACK_FAILED_HOSTS[@]}" -gt 0 ]; then
    return 0
  fi

  for tf_status in "${RUN_SUMMARY_TF_STATUSES[@]}"; do
    if [ "${tf_status}" = "fail" ]; then
      return 0
    fi
  done

  return 1
}

print_run_summary() {
  local final_rc="$1"
  local node status
  local -a failed_summary_hosts=()
  local tf_label tf_status tf_display_status
  local -a failed_summary_tf=()

  log_section "Phase: Summary"
  echo "Action: ${RUN_SUMMARY_ACTION:-${ACTION}}" >&2
  echo "Hosts:" >&2
  if [ "${#RUN_SUMMARY_SELECTED_HOSTS[@]}" -eq 0 ]; then
    echo "  - (none)" >&2
  fi
  for node in "${RUN_SUMMARY_SELECTED_HOSTS[@]}"; do
    status="$(host_final_status \
      "${RUN_SUMMARY_ACTION:-${ACTION}}" \
      "${node}" \
      RUN_SUMMARY_BUILD_OK_HOSTS \
      RUN_SUMMARY_BUILD_FAILED_HOSTS \
      RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS \
      RUN_SUMMARY_DEPLOY_OK_HOSTS \
      RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS \
      RUN_SUMMARY_DEPLOY_FAILED_HOSTS \
      RUN_SUMMARY_ROLLBACK_OK_HOSTS \
      RUN_SUMMARY_ROLLBACK_FAILED_HOSTS)"

    echo "  - ${node}: ${status}" >&2
    if [[ "${status}" == FAIL* ]]; then
      failed_summary_hosts+=("${node}: ${status}")
    fi
  done
  echo "Terraform:" >&2
  if [ "${#RUN_SUMMARY_TF_LABELS[@]}" -eq 0 ]; then
    echo "  - (none)" >&2
  fi
  for ((i=0; i<${#RUN_SUMMARY_TF_LABELS[@]}; i++)); do
    tf_label="${RUN_SUMMARY_TF_LABELS[$i]}"
    tf_status="${RUN_SUMMARY_TF_STATUSES[$i]}"
    tf_display_status="$(tf_summary_display_status "${tf_status}")"
    echo "  - ${tf_label}: ${tf_display_status}" >&2
    if [ "${tf_status}" = "fail" ]; then
      failed_summary_tf+=("${tf_label}: FAIL (tf)")
    fi
  done
  if [ "${#failed_summary_hosts[@]}" -gt 0 ]; then
    printf '\n!!!!!!!!!! FAILURE !!!!!!!!!!\n' >&2
    for node in "${failed_summary_hosts[@]}"; do
      echo "  - ${node}" >&2
    done
    for tf_label in "${failed_summary_tf[@]}"; do
      echo "  - ${tf_label}" >&2
    done
  elif [ "${#failed_summary_tf[@]}" -gt 0 ]; then
    printf '\n!!!!!!!!!! FAILURE !!!!!!!!!!\n' >&2
    for tf_label in "${failed_summary_tf[@]}"; do
      echo "  - ${tf_label}" >&2
    done
  fi
  printf '\nResult: %s\n' "$([ "${final_rc}" -eq 0 ] && printf 'success' || printf 'failure')" >&2
}

clear_run_summary_state() {
  RUN_SUMMARY_ACTION=""
  RUN_SUMMARY_SELECTED_HOSTS=()
  RUN_SUMMARY_BUILD_OK_HOSTS=()
  RUN_SUMMARY_BUILD_FAILED_HOSTS=()
  RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS=()
  RUN_SUMMARY_DEPLOY_OK_HOSTS=()
  RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS=()
  RUN_SUMMARY_DEPLOY_FAILED_HOSTS=()
  RUN_SUMMARY_ROLLBACK_OK_HOSTS=()
  RUN_SUMMARY_ROLLBACK_FAILED_HOSTS=()
  RUN_SUMMARY_TF_LABELS=()
  RUN_SUMMARY_TF_STATUSES=()
}

set_run_summary_host_state() {
  local action="$1"
  local selected_hosts_name="$2"
  local build_ok_hosts_name="$3"
  local build_failed_hosts_name="$4"
  local snapshot_failed_hosts_name="$5"
  local deploy_ok_hosts_name="$6"
  local deploy_skipped_hosts_name="$7"
  local deploy_failed_hosts_name="$8"
  local rollback_ok_hosts_name="$9"
  local rollback_failed_hosts_name="${10}"
  local -n selected_hosts_in_ref="${selected_hosts_name}"
  local -n build_ok_hosts_in_ref="${build_ok_hosts_name}"
  local -n build_failed_hosts_in_ref="${build_failed_hosts_name}"
  # shellcheck disable=SC2178
  local -n snapshot_failed_hosts_in_ref="${snapshot_failed_hosts_name}"
  local -n deploy_ok_hosts_in_ref="${deploy_ok_hosts_name}"
  local -n deploy_skipped_hosts_in_ref="${deploy_skipped_hosts_name}"
  # shellcheck disable=SC2178
  local -n deploy_failed_hosts_in_ref="${deploy_failed_hosts_name}"
  local -n rollback_ok_hosts_in_ref="${rollback_ok_hosts_name}"
  local -n rollback_failed_hosts_in_ref="${rollback_failed_hosts_name}"

  # shellcheck disable=SC2034
  {
    RUN_SUMMARY_ACTION="${action}"
    RUN_SUMMARY_SELECTED_HOSTS=("${selected_hosts_in_ref[@]}")
    RUN_SUMMARY_BUILD_OK_HOSTS=("${build_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_BUILD_FAILED_HOSTS=("${build_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS=("${snapshot_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_OK_HOSTS=("${deploy_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS=("${deploy_skipped_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_FAILED_HOSTS=("${deploy_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_ROLLBACK_OK_HOSTS=("${rollback_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_ROLLBACK_FAILED_HOSTS=("${rollback_failed_hosts_in_ref[@]}")
  }
}

record_tf_run_summary() {
  local phase="$1"
  local project_name="$2"
  local status="$3"

  RUN_SUMMARY_TF_LABELS+=("${phase}/${project_name}")
  RUN_SUMMARY_TF_STATUSES+=("${status}")
}

# End logging helpers.

##### Dispatch #####

ensure_runtime_shell() {
  local script_path
  local flake_path
  local -a nix_shell_cmd=()

  if [ "${RUNTIME_SHELL_FLAG}" = "1" ]; then
    return
  fi

  require_cmds nix

  script_path="${BASH_SOURCE[0]:-$0}"
  if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    nix_shell_cmd=(nix shell "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
  else
    flake_path="$(cd "$(dirname "${script_path}")/.." && pwd -P)"
    nix_shell_cmd=(nix shell --inputs-from "${flake_path}" "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
  fi

  exec "${nix_shell_cmd[@]}" -c env NIXBOT_DEPLOY_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

ensure_runtime_tools() {
  require_cmds "${NIXBOT_RUNTIME_COMMANDS[@]}"
}

hydrate_request_args_from_ssh_command() {
  local -n request_args_out_ref="$1"

  if [ "${#request_args_out_ref[@]}" -ne 0 ] || [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then
    return
  fi

  echo "Received SSH_ORIGINAL_COMMAND:"
  echo "${SSH_ORIGINAL_COMMAND}"
  read -r -a request_args_out_ref <<<"${SSH_ORIGINAL_COMMAND}"
  if [ "${#request_args_out_ref[@]}" -gt 0 ] && [ "${request_args_out_ref[0]}" = "--" ]; then
    request_args_out_ref=("${request_args_out_ref[@]:1}")
  fi
  if [ "${#request_args_out_ref[@]}" -gt 0 ]; then
    case "${request_args_out_ref[0]}" in
      nixbot-deploy.sh|*/nixbot-deploy.sh)
        request_args_out_ref=("${request_args_out_ref[@]:1}")
        ;;
    esac
  fi
}

is_tofu_wrapper_request() {
  local -a request_args=("$@")

  [ "${#request_args[@]}" -gt 0 ] && [ "${request_args[0]}" = "tofu" ]
}

run_deploy_request_action() {
  local selected_json="$1"

  if [ "${ACTION}" = "all" ]; then
    run_all_action "${selected_json}"
  elif action_is_tf_only "${ACTION}"; then
    run_tf_only_action
  else
    run_hosts "${selected_json}"
  fi
}

run_all_action() {
  local selected_json="$1"

  if ! run_tf_phases dns platform; then
    return "$?"
  fi

  if ! run_hosts "${selected_json}"; then
    return "$?"
  fi

  if ! run_tf_phases apps; then
    return "$?"
  fi

  return 0
}

run_requested_action() {
  local selected_json=""
  local action_rc=0

  prepare_run_context selected_json

  if run_deploy_request_action "${selected_json}"; then
    :
  else
    action_rc="$?"
  fi

  if [ "${action_rc}" -eq 0 ] && run_summary_has_failures; then
    action_rc=1
  fi

  print_run_summary "${action_rc}"
  return "${action_rc}"
}

##### Main #####

main() {
  local -a request_args=("$@")

  ensure_runtime_shell "$@"
  init_vars
  trap cleanup EXIT
  cleanup_stale_runtime_dirs

  hydrate_request_args_from_ssh_command request_args

  if is_tofu_wrapper_request "${request_args[@]}"; then
    ensure_runtime_tools
    run_tofu_wrapper "${request_args[@]:1}"
    return
  fi

  parse_args "${request_args[@]}"
  ensure_runtime_tools
  if [ "${ENSURE_DEPS_ONLY}" -eq 1 ]; then
    return
  fi

  if [ "${BASTION_TRIGGER}" -eq 1 ]; then
    run_bastion_trigger
    return
  fi

  prepare_repo_worktree
  reexec_repo_script_if_needed "${request_args[@]}"

  run_requested_action
}

main "$@"
