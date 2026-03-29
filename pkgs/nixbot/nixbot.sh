#!/usr/bin/env bash
set -Eeuo pipefail

##### Nixbot Deploy #####

RUNTIME_SHELL_FLAG="${NIXBOT_IN_NIX_SHELL:-0}"
readonly NIXBOT_VERSION="2026.03.27.10"
readonly NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE_FALLBACK="/run/current-system/sw/bin/incus-machines-reconciler{resourceArgs}"
readonly NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE_FALLBACK="/run/current-system/sw/bin/incus-machines-settlement --timeout {timeout}{resourceArgs}"

readonly -a NIXBOT_RUNTIME_INSTALLABLES=(
  nixpkgs#age
  nixpkgs#git
  nixpkgs#jq
  nixpkgs#nixos-rebuild-ng
  nixpkgs#openssh
  nixpkgs#opentofu
)
readonly -a NIXBOT_RUNTIME_COMMANDS=(
  nix
  age
  git
  jq
  nixos-rebuild-ng
  ssh
  scp
  ssh-keygen
  tofu
)
readonly NIXBOT_SSH_ARGV_PREFIX="__nixbot_argv64"

usage() {
  cat <<'USAGE'
Usage:
  nixbot
  nixbot <deps|check-deps|version>
  nixbot <run|deploy|build|tf|tf-dns|tf-platform|tf-apps|tf/<project>|check-bootstrap> [--sha <commit>] [--hosts "host1,host2|all"] [--goal <goal>] [--build-host <local|target|host>] [--build-jobs <n>] [--deploy-jobs <n>] [--force] [--bootstrap] [--bastion-first] [--dirty] [--dry] [--no-rollback] [--prefix-host-logs] [--log-format <auto|gh|plain>] [--user <name>] [--ssh-key <path>] [--known-hosts <contents>] [--config <path>] [--age-key-file <path>] [--discover-keys[=auto|on|off]] [--repo-url <url>] [--repo-path <path>] [--use-repo-script] [--bastion-check-ssh-key-path <path>] [--bastion-trigger] [--bastion-host <host>] [--bastion-user <user>] [--bastion-ssh-key <key-content>] [--bastion-known-hosts <known-hosts-content>]
  nixbot tofu <tofu-args...>

Dependency Actions:
  deps            Enter the nixbot runtime shell, verify tools, and exit.
  check-deps      Verify required commands in the current environment.
  version         Print the nixbot script version and exit.

Workflow Actions:
  run             Run the full workflow.
  deploy          Run host build and deploy.
  build           Run host build only.
  tf              Run all Terraform phases.
  tf-dns          Run the DNS Terraform phase.
  tf-platform     Run the platform Terraform phase.
  tf-apps         Run the apps Terraform phase.
  tf/<project>    Run one configured Terraform project.
  check-bootstrap Run forced-command bootstrap checks.

Local Wrapper Action:
  tofu            Run local OpenTofu in the nixbot runtime shell.

Workflow Selection Options:
  --hosts          Hosts/context to target (comma/space-separated or `all`; default: all)
  --sha            Commit to check out before running

Build Action Options (`run`, `deploy`, `build`):
  --build-host     local|target|<ssh-host> (default: local)
  --build-jobs     Parallel host builds (default: 1)

Deploy Action Options (`run`, `deploy`):
  --goal           switch|boot|test|dry-activate (default: switch)
  --deploy-jobs    Parallel deploys within a dependency wave (default: 1)
  --bootstrap      Always use bootstrap SSH user/key selection
  --no-rollback    Disable rollback if any deploy fails
  --prefix-host-logs Always prefix host log lines

Host Workflow Ordering Options (`run`, `deploy`, `build`, `check-bootstrap`):
  --bastion-first  Prioritize bastion host first when bastion is selected

Workflow Behavior Options:
  --dry            Print commands without applying changes
  --force          Bypass change-detection gates
  --dirty          Allow running from a dirty repo root (worktree = HEAD)
  --dirty-staged   Like --dirty, but overlay staged changes into the worktree
  --log-format     auto|gh|plain (default: auto)

Auth / Config Options:
  --user           Default deploy user override
  --ssh-key        SSH key path for deploy target auth (must be .age when set)
  --known-hosts    known_hosts override for all hosts
  --config         Nix deploy config path (default: hosts/nixbot.nix)
  --age-key-file   Age/SSH identity used to decrypt `*.age` secrets
  --discover-keys  Fallback decrypt identity discovery (auto|on|off; default: auto)

Bootstrap/Forced-Command Options:
  --bastion-check-ssh-key-path .age key override for bootstrap checks

Remote Trigger Options:
  --bastion-trigger Run remotely on bastion via SSH and exit
  --bastion-host   Bastion hostname/IP (default: pvl-x2)
  --bastion-user   Bastion user (default: nixbot)
  --bastion-ssh-key Optional SSH private key content for bastion trigger
  --bastion-known-hosts Optional known_hosts content for bastion trigger

Repo Options:
  --repo-url       Repo URL for cloning a managed repo root
  --repo-path      Persistent repo root for sync and per-run worktrees
  --use-repo-script Re-exec from the worktree copy of this script; disabled by
                    default for security

Environment (Workflow Selection):
  NIXBOT_HOSTS                Same as --hosts
  NIXBOT_SHA                  Same as --sha

Environment (Build Actions):
  NIXBOT_BUILD_HOST           Same as --build-host
  NIXBOT_BUILD_JOBS           Same as --build-jobs

Environment (Deploy Actions):
  NIXBOT_GOAL                 Same as --goal
  NIXBOT_JOBS                 Same as --deploy-jobs
  NIXBOT_NO_ROLLBACK          Same as --no-rollback (bool)
  NIXBOT_PREFIX_HOST_LOGS     Same as --prefix-host-logs (bool)

Environment (Host Workflow Ordering):
  NIXBOT_BASTION_FIRST        Same as --bastion-first (bool)
  NIXBOT_LOCAL_SELF_TARGET    Self-target transport policy: auto|on|off
                              (default: auto)

Environment (Workflow Behavior):
  NIXBOT_FORCE                Same as --force (bool: 1/0, true/false, yes/no)
  NIXBOT_DIRTY                Same as --dirty (bool: 1/0, true/false, yes/no)
  NIXBOT_DIRTY_STAGED          Same as --dirty-staged (bool: 1/0, true/false, yes/no)
  NIXBOT_DRY                  Same as --dry (bool)
  NIXBOT_LOG_FORMAT           Same as --log-format

Environment (Auth / Config):
  NIXBOT_USER                 Same as --user
  NIXBOT_SSH_KEY              Same as --ssh-key
  NIXBOT_SSH_KNOWN_HOSTS      Same as --known-hosts
  NIXBOT_CONFIG               Same as --config
  AGE_KEY_FILE                Same as --age-key-file
  NIXBOT_DISCOVER_KEYS        Same as --discover-keys (auto|on|off)

Environment (Bootstrap / Forced-Command):
  NIXBOT_BOOTSTRAP            Same as --bootstrap (bool)
  NIXBOT_BASTION_SSH_KEY_PATH Same as --bastion-check-ssh-key-path

Environment (Remote Trigger):
  NIXBOT_BASTION_TRIGGER      Same as --bastion-trigger (bool)
  NIXBOT_BASTION_HOST         Same as --bastion-host
  NIXBOT_BASTION_USER         Same as --bastion-user
  NIXBOT_BASTION_SSH_KEY      Same as --bastion-ssh-key
  NIXBOT_BASTION_KNOWN_HOSTS  Same as --bastion-known-hosts

Environment (Repo):
  NIXBOT_REPO_URL             Same as --repo-url
  NIXBOT_REPO_PATH            Same as --repo-path
  NIXBOT_USE_REPO_SCRIPT      Same as --use-repo-script (bool)

Environment (Terraform actions):
  R2_ACCOUNT_ID               Cloudflare account ID used for the shared R2 backend endpoint
  R2_STATE_BUCKET             R2 bucket name for Terraform state
  R2_ACCESS_KEY_ID            R2 access key ID
  R2_SECRET_ACCESS_KEY        R2 secret access key
  R2_STATE_KEY                Optional Cloudflare state object key override
  GCP_STATE_BUCKET            GCS bucket name for GCP Terraform state
  GCP_STATE_PREFIX            Optional GCP state object prefix override
  GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT Optional service account email for GCS backend access
  GOOGLE_APPLICATION_CREDENTIALS Path to the Google service-account JSON used for provider auth
  NIXBOT_TF_DIR               Optional single-project override; must match the requested phase suffix
  CLOUDFLARE_API_TOKEN        Provider-specific Cloudflare API token, required by Cloudflare projects

Runtime:
  Workflow actions and `tofu` always re-exec inside `nix shell` to provide a
  consistent toolchain: age, git, jq, nixos-rebuild-ng, openssh, and opentofu.
  `deps` re-execs and exits after verification.
  `check-deps` only checks the current environment.

Local tofu wrapper:
  `nixbot tofu ...` runs OpenTofu locally in the same runtime shell.
  For recognized `tf/<provider>-<phase>` projects, it can auto-load backend
  and provider secrets plus decrypted `-var-file` inputs when none are set.
  GCP projects can also auto-load `GOOGLE_APPLICATION_CREDENTIALS`,
  `GCP_STATE_BUCKET`, and `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` from
  encrypted files under `data/secrets/gcp/`.
  This mode is local-only and not supported via bastion trigger.
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
  HOSTS_RAW="${NIXBOT_HOSTS:-all}"
  ACTION=""
  HOST_ACTION=""
  GOAL="${NIXBOT_GOAL:-switch}"
  BUILD_HOST="${NIXBOT_BUILD_HOST:-local}"
  BUILD_JOBS="${NIXBOT_BUILD_JOBS:-1}"
  NIXBOT_PARALLEL_JOBS="${NIXBOT_JOBS:-1}"
  NIXBOT_IF_CHANGED=1
  TF_IF_CHANGED=1
  FORCE_REQUESTED=0
  ALLOW_DIRTY_REPO=0
  OVERLAY_STAGED=0
  FORCE_BOOTSTRAP_PATH=0
  PRIORITIZE_BASTION_FIRST=0
  DRY_RUN=0
  ROLLBACK_ON_FAILURE=1
  FORCE_PREFIX_HOST_LOGS=0
  PREFIX_HOST_LOGS_EXPLICIT=0
  LOG_FORMAT="${NIXBOT_LOG_FORMAT:-auto}"
  NIXBOT_LOCAL_SELF_TARGET_MODE="${NIXBOT_LOCAL_SELF_TARGET:-auto}"
  NIXBOT_PARENT_SETTLE_TIMEOUT="${NIXBOT_PARENT_SETTLE_TIMEOUT:-180}"
  NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT="${NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT:-45}"
  NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS="${NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS:-5}"
  NIXBOT_CONTROL_PERSIST_SECS="${NIXBOT_CONTROL_PERSIST_SECS:-120}"
  NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE="${NIXBOT_PARENT_RECONCILE_TEMPLATE:-}"
  NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE="${NIXBOT_PARENT_SETTLE_TEMPLATE:-}"
  if [ -z "${NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE}" ]; then
    NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE="${NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE_FALLBACK}"
  fi
  if [ -z "${NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE}" ]; then
    NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE="${NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE_FALLBACK}"
  fi
  NIXBOT_CONFIG_PATH="${NIXBOT_CONFIG:-hosts/nixbot.nix}"
  SHA="${NIXBOT_SHA:-}"
  BASTION_TRIGGER=0
  BASTION_TRIGGER_HOST="${NIXBOT_BASTION_HOST:-pvl-x2}"
  BASTION_TRIGGER_USER="${NIXBOT_BASTION_USER:-nixbot}"
  BASTION_TRIGGER_SSH_KEY="${NIXBOT_BASTION_SSH_KEY:-}"
  BASTION_TRIGGER_KNOWN_HOSTS="${NIXBOT_BASTION_KNOWN_HOSTS:-}"
  BASTION_TRIGGER_SSH_OPTS=()
  AGE_DECRYPT_IDENTITY_FILE="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
  AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=0
  [ -n "${AGE_KEY_FILE:-}" ] && AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=1
  DISCOVER_DECRYPT_KEYS_MODE="${NIXBOT_DISCOVER_KEYS:-auto}"
  REEXEC_FROM_REPO=0
  REPO_PATH_EXPLICIT=0
  NIXBOT_REPO_ROOT_LOCK_TIMEOUT="${NIXBOT_REPO_ROOT_LOCK_TIMEOUT:-60}"
  NIXBOT_TRANSPORT_RETRY_ATTEMPTS="${NIXBOT_TRANSPORT_RETRY_ATTEMPTS:-3}"
  NIXBOT_TRANSPORT_RETRY_DELAY_SECS="${NIXBOT_TRANSPORT_RETRY_DELAY_SECS:-2}"
  TF_WORK_DIR="${NIXBOT_TF_DIR:-}"
  TF_CHANGE_BASE_REF=""
  _NIXBOT_LOG_GROUP_DEPTH=0
  _NIXBOT_LOG_GROUP_SCOPE=""

  clear_run_summary_state

  NIXBOT_USER_OVERRIDE="${NIXBOT_USER:-}"
  NIXBOT_KEY_PATH_OVERRIDE="${NIXBOT_SSH_KEY:-}"
  NIXBOT_KNOWN_HOSTS_OVERRIDE="${NIXBOT_SSH_KNOWN_HOSTS:-}"
  NIXBOT_BASTION_KEY_PATH_OVERRIDE="${NIXBOT_BASTION_SSH_KEY_PATH:-}"
  NIXBOT_KEY_OVERRIDE_EXPLICIT=0

  set_discover_keys_mode "${DISCOVER_DECRYPT_KEYS_MODE}"

  if [ -n "${NIXBOT_SSH_KEY:-}" ]; then
    NIXBOT_KEY_OVERRIDE_EXPLICIT=1
  fi

  if parse_bool_env "${NIXBOT_FORCE:-0}"; then
    enable_force_mode
  fi
  if parse_bool_env "${NIXBOT_DIRTY:-0}"; then
    ALLOW_DIRTY_REPO=1
  fi
  if parse_bool_env "${NIXBOT_DIRTY_STAGED:-0}"; then
    OVERLAY_STAGED=1
    ALLOW_DIRTY_REPO=1
  fi
  if parse_bool_env "${NIXBOT_BASTION_FIRST:-0}"; then
    PRIORITIZE_BASTION_FIRST=1
  fi
  if parse_bool_env "${NIXBOT_BOOTSTRAP:-0}"; then
    FORCE_BOOTSTRAP_PATH=1
  fi
  if parse_bool_env "${NIXBOT_DRY:-0}"; then
    enable_dry_run_mode
  fi
  if parse_bool_env "${NIXBOT_NO_ROLLBACK:-0}"; then
    ROLLBACK_ON_FAILURE=0
  fi
  if [ -n "${NIXBOT_PREFIX_HOST_LOGS:-}" ]; then
    if parse_bool_env "${NIXBOT_PREFIX_HOST_LOGS}"; then
      set_prefix_host_logs_mode 1
    else
      set_prefix_host_logs_mode 0
    fi
  fi
  if parse_bool_env "${NIXBOT_BASTION_TRIGGER:-0}"; then
    BASTION_TRIGGER=1
  fi
  if parse_bool_env "${NIXBOT_USE_REPO_SCRIPT:-0}"; then
    REEXEC_FROM_REPO=1
  fi


  NIXBOT_DEFAULT_USER="root"
  NIXBOT_DEFAULT_PORT="22"
  NIXBOT_DEFAULT_KEY_PATH=""
  NIXBOT_DEFAULT_KNOWN_HOSTS=""
  NIXBOT_DEFAULT_BOOTSTRAP_KEY=""
  NIXBOT_DEFAULT_BOOTSTRAP_USER="root"
  NIXBOT_DEFAULT_BOOTSTRAP_PORT="${NIXBOT_DEFAULT_PORT}"
  NIXBOT_DEFAULT_BOOTSTRAP_KEY_PATH=""
  NIXBOT_DEFAULT_AGE_IDENTITY_KEY=""
  NIXBOT_HOSTS_JSON='{}'

  NIXBOT_TMP_DIR=""
  NIXBOT_CONFIG_DIR=""
  BOOTSTRAP_READY_NODES=""
  PRIMARY_READY_NODES=""
  PREP_DEPLOY_NODE=""
  PREP_DEPLOY_SSH_TARGET=""
  PREP_DEPLOY_NIX_SSHOPTS=""
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_AGE_IDENTITY_KEY=""
  PREP_DEPLOY_LOCAL_EXEC=0
  PREP_DEPLOY_SSH_OPTS=()
  CURRENT_HOST_ALIASES=()
  CURRENT_HOST_ADDRESSES=()
  ROLLBACK_OK_HOSTS=()
  ROLLBACK_FAILED_HOSTS=()
  FULLY_SKIPPED_HOSTS=()
  OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=()
  OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
  OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=()

  BASTION_TRIGGER_KEY_PATH="data/secrets/bastion/nixbot-bastion-ssh.key.age"
  REMOTE_NIXBOT_BASE="/var/lib/nixbot"
  REMOTE_NIXBOT_SSH_DIR="${REMOTE_NIXBOT_BASE}/.ssh"
  REMOTE_NIXBOT_AGE_DIR="${REMOTE_NIXBOT_BASE}/.age"
  REMOTE_NIXBOT_DEPLOY_SCRIPT="nixbot"
  REMOTE_NIXBOT_PRIMARY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519"
  REMOTE_NIXBOT_LEGACY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519_legacy"
  REMOTE_NIXBOT_AGE_IDENTITY="${REMOTE_NIXBOT_AGE_DIR}/identity"
  REMOTE_CURRENT_SYSTEM_PATH="/run/current-system"
  RUNTIME_WORK_DIR_PREFIX="/dev/shm/nixbot-run."
  RUNTIME_WORK_DIR_FALLBACK_PREFIX="${TMPDIR:-/tmp}/nixbot-run."
  BASTION_KNOWN_HOSTS_PREFIX="bastion-known-hosts"
  NODE_KNOWN_HOSTS_PREFIX="known_hosts"
  TMP_SECRETS_DIR=""
  TMP_SSH_DIR=""
  TMP_TF_ARTIFACT_DIR=""
  REPO_DEPLOY_SCRIPT_REL="pkgs/nixbot/nixbot.sh"
  REMOTE_BOOTSTRAP_KEY_TMP_PREFIX="/tmp/nixbot-bootstrap-key."
  REMOTE_AGE_IDENTITY_TMP_PREFIX="/tmp/nixbot-age-identity."
  TF_CLOUDFLARE_API_TOKEN_PATH="data/secrets/cloudflare/api-token.key.age"
  TF_R2_ACCOUNT_ID_PATH="data/secrets/cloudflare/r2-account-id.key.age"
  TF_R2_STATE_BUCKET_PATH="data/secrets/cloudflare/r2-state-bucket.key.age"
  TF_R2_ACCESS_KEY_ID_PATH="data/secrets/cloudflare/r2-access-key-id.key.age"
  TF_R2_SECRET_ACCESS_KEY_PATH="data/secrets/cloudflare/r2-secret-access-key.key.age"
  TF_GCP_APPLICATION_CREDENTIALS_PATH="data/secrets/gcp/application-default-credentials.json.age"
  TF_GCP_STATE_BUCKET_PATH="data/secrets/gcp/state-bucket.key.age"
  TF_GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT_PATH="data/secrets/gcp/backend-impersonate-service-account.key.age"
  TF_SECRETS_DIR="data/secrets/tf"
  TF_PROJECT_NAMES=(
    cloudflare-dns
    cloudflare-platform
    # gcp-platform
    cloudflare-apps
  )

  # `REPO_ROOT` is the long-lived source mirror. Runs never execute from it
  # directly; they materialize `REPO_WORKTREE_ROOT` and switch into that tree.
  REPO_BASE="${REMOTE_NIXBOT_BASE}"
  REPO_ROOT="${NIXBOT_REPO_ROOT:-${NIXBOT_REPO_PATH:-${REPO_BASE}/nix}}"
  REPO_WORKTREE_ROOT="${NIXBOT_REPO_WORKTREE_ROOT:-}"
  REPO_ROOT_LOCK_DIR=""
  REPO_ROOT_MANAGED=1
  REPO_URL="${NIXBOT_REPO_URL:-ssh://git@github.com/prasannavl/nix.git}"
  REPO_SSH_KEY_PATH="${REMOTE_NIXBOT_PRIMARY_KEY}"
  REPO_GIT_SSH_COMMAND="ssh -i ${REPO_SSH_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  RUNTIME_WORK_DIR="${NIXBOT_RUNTIME_WORK_DIR:-}"

  init_current_host_aliases
  normalize_host_action
}

##### Core Helpers #####

init_current_host_aliases() {
  local alias="" addr=""

  CURRENT_HOST_ALIASES=()
  CURRENT_HOST_ADDRESSES=()
  while IFS= read -r alias; do
    [ -n "${alias}" ] || continue
    append_unique_array_item CURRENT_HOST_ALIASES "${alias}"
    append_unique_array_item CURRENT_HOST_ALIASES "${alias%%.*}"
  done < <(
    {
      hostname -s 2>/dev/null || true
      hostname 2>/dev/null || true
      hostname -f 2>/dev/null || true
    } | awk 'NF'
  )

  for alias in "${CURRENT_HOST_ALIASES[@]}"; do
    [ -n "${alias}" ] || continue
    while IFS= read -r addr; do
      [ -n "${addr}" ] || continue
      append_unique_array_item CURRENT_HOST_ADDRESSES "${addr}"
    done < <(resolve_identifier_addresses "${alias}")
  done

  if command -v ip >/dev/null 2>&1; then
    while IFS= read -r addr; do
      [ -n "${addr}" ] || continue
      append_unique_array_item CURRENT_HOST_ADDRESSES "${addr}"
    done < <(ip -o addr show up 2>/dev/null | awk '{split($4, a, "/"); print a[1]}' | awk 'NF')
  fi
}

set_env_from_file_if_unset() {
  local var_name="$1" file_path="$2" value=""

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

set_env_path_from_file_if_unset() {
  local var_name="$1" file_path="$2"

  if [ -n "${!var_name:-}" ] || [ ! -f "${file_path}" ]; then
    return
  fi

  printf -v "${var_name}" '%s' "${file_path}"
  export "${var_name?}"
}

load_env_value_from_secret_file_if_unset() {
  local var_name="$1" secret_path="$2" decrypted_file=""

  [ -z "${!var_name:-}" ] || return 0
  ensure_tmp_dir
  decrypted_file="$(resolve_runtime_key_file "${secret_path}" 1)"
  set_env_from_file_if_unset "${var_name}" "${decrypted_file}"
}

load_env_path_from_secret_file_if_unset() {
  local var_name="$1" secret_path="$2" decrypted_file=""

  [ -z "${!var_name:-}" ] || return 0
  ensure_tmp_dir
  decrypted_file="$(resolve_runtime_key_file "${secret_path}" 1)"
  set_env_path_from_file_if_unset "${var_name}" "${decrypted_file}"
}

require_nonempty_env_var() {
  local var_name="$1"
  [ -n "${!var_name:-}" ] || die "Missing required environment variable: ${var_name}"
}

require_existing_file_env_var() {
  local var_name="$1"

  require_nonempty_env_var "${var_name}"
  [ -f "${!var_name}" ] || die "Environment variable ${var_name} must point to an existing file: ${!var_name}"
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
  NIXBOT_IF_CHANGED=0
  TF_IF_CHANGED=0
  FORCE_REQUESTED=1
}

enable_dry_run_mode() {
  DRY_RUN=1
  NIXBOT_IF_CHANGED=0
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

action_is_tf_project_only() {
  case "${1:-}" in
    tf/*) return 0 ;;
    *) return 1 ;;
  esac
}

tf_action_project_name() {
  local action="${1:-}"

  case "${action}" in
    tf/*)
      printf '%s\n' "${action#tf/}"
      ;;
    *)
      return 1
      ;;
  esac
}

tf_project_phase_from_name() {
  local project_name="$1"
  local phase="${project_name##*-}"

  case "${phase}" in
    dns|platform|apps)
      printf '%s\n' "${phase}"
      ;;
    *)
      return 1
      ;;
  esac
}

tf_project_name_is_configured() {
  local project_name="$1" configured_project_name=""

  for configured_project_name in "${TF_PROJECT_NAMES[@]}"; do
    [ "${configured_project_name}" = "${project_name}" ] && return 0
  done

  return 1
}

action_is_supported() {
  case "${1:-}" in
    run|build|deploy|tf|tf-dns|tf-platform|tf-apps|check-bootstrap) return 0 ;;
    *)
      if action_is_tf_project_only "${1:-}"; then
        tf_project_name_is_configured "$(tf_action_project_name "${1:-}")"
        return
      fi
      return 1
      ;;
  esac
}

action_is_tf_only() {
  case "${1:-}" in
    tf|tf-dns|tf-platform|tf-apps) return 0 ;;
    *)
      action_is_tf_project_only "${1:-}"
      ;;
  esac
}

resolved_host_action() {
  case "${1:-}" in
    run) printf 'deploy\n' ;;
    *) printf '%s\n' "${1:-}" ;;
  esac
}

emit_normalized_hosts() {
  local raw="$1"

  printf '%s' "${raw}" \
    | tr ', ' '\n' \
    | awk 'NF && !seen[$0]++'
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
  local -n jatba_array_out_ref="$2"

  # shellcheck disable=SC2034
  mapfile -t jatba_array_out_ref < <(jq -r '.[]' <<<"${json}")
}

json_array_to_bash_set() {
  local json="$1"
  # shellcheck disable=SC2178
  local -n jatbs_set_out_ref="$2"
  local item=""

  # shellcheck disable=SC2034
  while IFS= read -r item; do
    [ -n "${item}" ] || continue
    jatbs_set_out_ref["${item}"]=1
  done < <(jq -r '.[]' <<<"${json}")
}

encode_ssh_command_args() {
  printf '%s\0' "$@" | base64 | tr -d '\n'
}

decode_ssh_command_args() {
  local encoded_args="$1"

  printf '%s' "${encoded_args}" | base64 -d
}

##### Argument Parsing #####

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sha|--sha=*)        take_optval "$@"; SHA="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --hosts|--hosts=*)    take_optval "$@"; HOSTS_RAW="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --goal|--goal=*)      take_optval "$@"; GOAL="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --build-host|--build-host=*)
        take_optval "$@"; BUILD_HOST="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --build-jobs|--build-jobs=*)
        take_optval "$@"; BUILD_JOBS="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --deploy-jobs|--deploy-jobs=*)
        take_optval "$@"; NIXBOT_PARALLEL_JOBS="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --force)              enable_force_mode; shift ;;
      --dirty)              ALLOW_DIRTY_REPO=1; shift ;;
      --dirty-staged)       OVERLAY_STAGED=1; ALLOW_DIRTY_REPO=1; shift ;;
      --bootstrap)          FORCE_BOOTSTRAP_PATH=1; shift ;;
      --bastion-first)      PRIORITIZE_BASTION_FIRST=1; shift ;;
      --dry)                enable_dry_run_mode; shift ;;
      --no-rollback)        ROLLBACK_ON_FAILURE=0; shift ;;
      --prefix-host-logs)   set_prefix_host_logs_mode 1; shift ;;
      --log-format|--log-format=*)
        take_optval "$@"; set_log_format_mode "${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --user|--user=*)      take_optval "$@"; NIXBOT_USER_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --ssh-key|--ssh-key=*)
        take_optval "$@"; NIXBOT_KEY_PATH_OVERRIDE="${OPTVAL}"; NIXBOT_KEY_OVERRIDE_EXPLICIT=1; shift "${OPTSHIFT}" ;;
      --known-hosts|--known-hosts=*)
        take_optval "$@"; NIXBOT_KNOWN_HOSTS_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
      --config|--config=*)  take_optval "$@"; NIXBOT_CONFIG_PATH="${OPTVAL}"; shift "${OPTSHIFT}" ;;
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
        take_optval "$@"; NIXBOT_BASTION_KEY_PATH_OVERRIDE="${OPTVAL}"; shift "${OPTSHIFT}" ;;
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

  action_is_supported "${ACTION}" || die "Unsupported action: ${ACTION}"
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
  [[ "${NIXBOT_PARALLEL_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --deploy-jobs: ${NIXBOT_PARALLEL_JOBS} (must be a positive integer)"
  case "${LOG_FORMAT}" in
    auto|gh|github-actions|plain) ;;
    *) die "Unsupported --log-format: ${LOG_FORMAT}" ;;
  esac
  if [ "${PREFIX_HOST_LOGS_EXPLICIT}" -eq 0 ] && { [ "${BUILD_JOBS}" -gt 1 ] || [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ]; }; then
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
  if [ -n "${RUNTIME_WORK_DIR}" ] && [ -d "${RUNTIME_WORK_DIR}" ]; then
    rm -rf "${RUNTIME_WORK_DIR}"
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
  if [ -n "${NIXBOT_TMP_DIR}" ]; then
    return
  fi
  ensure_runtime_work_dir
  NIXBOT_TMP_DIR="${RUNTIME_WORK_DIR}"

  # Keep sensitive temp material grouped by purpose so cleanup, debugging, and
  # future retention policies can treat secrets, SSH state, and TF artifacts
  # consistently.
  TMP_SECRETS_DIR="${NIXBOT_TMP_DIR}/secrets"
  TMP_SSH_DIR="${NIXBOT_TMP_DIR}/ssh"
  TMP_TF_ARTIFACT_DIR="$(phase_artifact_dir_path "${NIXBOT_TMP_DIR}" "tf")"
  mkdir -p "${TMP_SECRETS_DIR}" "${TMP_SSH_DIR}"
  ensure_phase_runtime_dirs "${NIXBOT_TMP_DIR}" tf
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
  local area="$1" pattern="$2"

  mktemp "$(tmp_runtime_dir_path "${area}")/${pattern}"
}

runtime_work_dir_prefix() {
  if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
    printf '%s\n' "${RUNTIME_WORK_DIR_PREFIX}"
  else
    printf '%s\n' "${RUNTIME_WORK_DIR_FALLBACK_PREFIX}"
  fi
}

ensure_runtime_work_dir() {
  [ -n "${RUNTIME_WORK_DIR}" ] && return 0
  RUNTIME_WORK_DIR="$(mktemp -d "$(runtime_work_dir_prefix)XXXXXX")"
}

cleanup_stale_runtime_dirs() {
  local scan_root="" path=""

  for scan_root in "/dev/shm" "${TMPDIR:-/tmp}"; do
    [ -d "${scan_root}" ] || continue

    while IFS= read -r path; do
      [ -n "${path}" ] || continue
      rm -rf "${path}" || true
    done < <(
      find "${scan_root}" -maxdepth 1 -mindepth 1 -type d \
        -name 'nixbot-run.*' \
        -mtime +3 -print 2>/dev/null
    )
  done
}

##### Repo Workspace #####

repo_worktree_file_path() {
  local relative_path="$1"

  printf '%s/%s\n' "${REPO_WORKTREE_ROOT%/}" "${relative_path}"
}

repo_worktree_script_path() {
  repo_worktree_file_path "${REPO_DEPLOY_SCRIPT_REL}"
}

repo_relative_path() {
  local path="$1" root="$2" resolved_path="" resolved_root=""

  [ -n "${path}" ] || return 1
  [ -n "${root}" ] || return 1
  resolved_path="$(readlink -f "${path}" 2>/dev/null || true)"
  resolved_root="$(readlink -f "${root}" 2>/dev/null || true)"
  [ -n "${resolved_path}" ] || resolved_path="${path}"
  [ -n "${resolved_root}" ] || resolved_root="${root}"

  if [ "${resolved_path}" = "${resolved_root}" ]; then
    printf '.\n'
    return 0
  fi
  case "${resolved_path}" in
    "${resolved_root}/"*)
      printf '%s\n' "${resolved_path#"${resolved_root}/"}"
      return 0
      ;;
  esac

  return 1
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
    git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  fi
  release_repo_root_lock
}

configure_bastion_trigger_ssh_opts() {
  local key_file="" known_hosts_file="" scanned_known_hosts=""

  BASTION_TRIGGER_SSH_OPTS=()

  ensure_tmp_dir

  if [ -z "${BASTION_TRIGGER_SSH_KEY}" ]; then
    if key_file="$(resolve_runtime_key_file "${BASTION_TRIGGER_KEY_PATH}" 1)" && [ -f "${key_file}" ]; then
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
    [ -n "${scanned_known_hosts}" ] || die "Could not determine bastion host key for ${BASTION_TRIGGER_HOST}. Pass --bastion-known-hosts/NIXBOT_BASTION_KNOWN_HOSTS or ensure ssh-keyscan can reach the bastion."
  fi

  known_hosts_file="$(tmp_runtime_mktemp ssh "${BASTION_KNOWN_HOSTS_PREFIX}.XXXXXX")"
  printf '%s\n' "${scanned_known_hosts}" > "${known_hosts_file}"
  chmod 600 "${known_hosts_file}"
  BASTION_TRIGGER_SSH_OPTS+=(-o StrictHostKeyChecking=yes -o UserKnownHostsFile="${known_hosts_file}")
}

run_bastion_trigger() {
  local trigger_sha="${SHA}" trigger_hosts="" encoded_request=""
  local -a remote_args=()
  if [ -z "${trigger_sha}" ]; then
    trigger_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
  fi
  [ -n "${trigger_sha}" ] || die "Could not resolve local HEAD; pass --sha/NIXBOT_SHA explicitly"
  [[ "${trigger_sha}" =~ ^[0-9a-f]{7,40}$ ]] || die "Unsupported --sha: ${trigger_sha}"

  action_is_supported "${ACTION}" || die "Unsupported action for --bastion-trigger: ${ACTION}"

  trigger_hosts="$(normalize_hosts_input "${HOSTS_RAW}")"
  [ -n "${trigger_hosts}" ] || die "No valid hosts after normalization"

  configure_bastion_trigger_ssh_opts

  log_section "Phase: Remote Trigger"
  echo "Bastion: ${BASTION_TRIGGER_USER}@${BASTION_TRIGGER_HOST}" >&2
  echo "Action: ${ACTION}" >&2
  echo "Hosts: ${trigger_hosts}" >&2
  echo "SHA: ${trigger_sha}" >&2
  # Intentionally forward only the bastion-safe subset here. This restriction is
  # deliberate: the remote side is expected to use its repo-local defaults and
  # checked-in config for deploy-shaping settings such as goal, build host, job
  # counts, rollback policy, and similar local overrides. Bastion-trigger runs
  # are therefore reproducible from committed state instead of inheriting
  # arbitrary local operator flags.
  remote_args=("${ACTION}" --sha "${trigger_sha}" --hosts "${trigger_hosts}")
  if [ "${LOG_FORMAT}" != "auto" ]; then
    remote_args+=(--log-format "${LOG_FORMAT}")
  elif is_github_actions_log_mode; then
    remote_args+=(--log-format gh)
  fi
  if [ "${DRY_RUN}" -eq 1 ]; then
    remote_args+=(--dry)
    echo "Dry run: true" >&2
  fi
  if [ "${FORCE_REQUESTED}" -eq 1 ]; then
    remote_args+=(--force)
    echo "Force: true" >&2
  fi
  if [ "${ALLOW_DIRTY_REPO}" -eq 1 ]; then
    remote_args+=(--dirty)
    echo "Dirty repo allowed: true" >&2
  fi

  encoded_request="$(encode_ssh_command_args "${remote_args[@]}")"
  log_group_end
  ssh "${BASTION_TRIGGER_SSH_OPTS[@]}" -- "${BASTION_TRIGGER_USER}@${BASTION_TRIGGER_HOST}" \
    "${NIXBOT_SSH_ARGV_PREFIX} ${encoded_request}"
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
  local git_dir="" lock_root="" lock_pid="" lock_deadline=0

  [ -n "${REPO_ROOT}" ] || return 0
  if [ -n "${REPO_ROOT_LOCK_DIR}" ] && [ -d "${REPO_ROOT_LOCK_DIR}" ]; then
    return 0
  fi

  git_dir="$(git -C "${REPO_ROOT}" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "${git_dir}" ]; then
    if [[ "${git_dir}" != /* ]]; then
      git_dir="${REPO_ROOT%/}/${git_dir}"
    fi
    lock_root="${git_dir%/}/nixbot-worktree.lock"
  else
    mkdir -p "$(dirname "${REPO_ROOT}")"
    lock_root="${REPO_ROOT%/}.nixbot-worktree.lock"
  fi

  lock_deadline=$((SECONDS + NIXBOT_REPO_ROOT_LOCK_TIMEOUT))
  while ! mkdir "${lock_root}" 2>/dev/null; do
    if [ "${SECONDS}" -ge "${lock_deadline}" ]; then
      lock_pid=""
      if [ -f "${lock_root}/pid" ]; then
        lock_pid="$(<"${lock_root}/pid")"
      fi

      if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
        die "Timed out waiting for repo root lock ${lock_root} held by pid ${lock_pid}"
      fi

      echo "Removing stale repo root lock: ${lock_root}" >&2
      rm -rf "${lock_root}" 2>/dev/null || true
      lock_deadline=$((SECONDS + NIXBOT_REPO_ROOT_LOCK_TIMEOUT))
      continue
    fi

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

  if [ -d "${REPO_ROOT}/.git" ] || [ -f "${REPO_ROOT}/.git" ]; then
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

  if [ "${ALLOW_DIRTY_REPO}" -eq 1 ]; then
    echo "Repo root dirty check bypassed by --dirty" >&2
    return 0
  fi

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
  local target_ref=""

  resolve_repo_root
  [ -n "${REPO_WORKTREE_ROOT}" ] && return 0
  ensure_runtime_work_dir

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

  REPO_WORKTREE_ROOT="${RUNTIME_WORK_DIR}/repo"
  git -C "${REPO_ROOT}" worktree add --detach "${REPO_WORKTREE_ROOT}" "${target_ref}" >/dev/null
  git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
  release_repo_root_lock

  # When --dirty-staged is set on a local repo, overlay staged changes and new
  # staged files into the worktree so the deploy includes them.
  if [ "${OVERLAY_STAGED}" -eq 1 ] && [ "${REPO_ROOT_MANAGED}" -eq 0 ]; then
    echo "Overlaying staged changes into worktree..." >&2
    if ! git -C "${REPO_ROOT}" diff --cached --binary | git -C "${REPO_WORKTREE_ROOT}" apply --allow-empty; then
      die "Failed to overlay staged changes into repo worktree"
    fi
    # Also copy untracked files that have been staged.
    while IFS= read -r -d '' f; do
      [ -n "${f}" ] || continue
      mkdir -p "${REPO_WORKTREE_ROOT}/$(dirname "${f}")"
      if ! git -C "${REPO_ROOT}" show ":${f}" > "${REPO_WORKTREE_ROOT}/${f}"; then
        die "Failed to materialize staged file in repo worktree: ${f}"
      fi
    done < <(git -C "${REPO_ROOT}" diff --cached --name-only --diff-filter=A -z)
  fi

  [ -f "$(repo_worktree_script_path)" ] || die "deploy script missing in repo worktree: $(repo_worktree_script_path)"
  cd "${REPO_WORKTREE_ROOT}"
}

reexec_repo_script_if_needed() {
  local current_script="" repo_script="" current_resolved="" repo_resolved=""
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
  exec env NIXBOT_REEXECED_FROM_REPO=1 NIXBOT_REPO_ROOT="${REPO_ROOT}" NIXBOT_REPO_WORKTREE_ROOT="${REPO_WORKTREE_ROOT}" NIXBOT_RUNTIME_WORK_DIR="${RUNTIME_WORK_DIR}" bash "${repo_script}" "${request_args[@]}"
}

##### Config / Secrets #####

load_deploy_config_json() {
  local path="$1"
  [ -f "${path}" ] || die "Deploy config not found: ${path}"
  nix eval --json --file "${path}"
}

init_deploy_settings() {
  local config_json="$1"

  NIXBOT_CONFIG_DIR="$(cd "$(dirname "${NIXBOT_CONFIG_PATH}")" && pwd -P)"

  {
    read -r NIXBOT_DEFAULT_USER
    read -r NIXBOT_DEFAULT_KEY_PATH
    read -r NIXBOT_DEFAULT_KNOWN_HOSTS
    read -r NIXBOT_DEFAULT_BOOTSTRAP_KEY
    read -r NIXBOT_DEFAULT_BOOTSTRAP_USER
    read -r NIXBOT_DEFAULT_BOOTSTRAP_KEY_PATH
    read -r NIXBOT_DEFAULT_AGE_IDENTITY_KEY
  } < <(jq -r '[(.defaults.user // "root"), (.defaults.key // ""), (.defaults.knownHosts // ""), (.defaults.bootstrapKey // ""), (.defaults.bootstrapUser // "root"), (.defaults.bootstrapKeyPath // ""), (.defaults.ageIdentityKey // "")] | .[]' <<<"${config_json}")
  NIXBOT_HOSTS_JSON="$(jq -c '.hosts // {}' <<<"${config_json}")"

  if [ -n "${NIXBOT_USER_OVERRIDE}" ]; then
    NIXBOT_DEFAULT_USER="${NIXBOT_USER_OVERRIDE}"
  fi

  if [ -n "${NIXBOT_KEY_PATH_OVERRIDE}" ]; then
    NIXBOT_DEFAULT_KEY_PATH="${NIXBOT_KEY_PATH_OVERRIDE}"
  elif [ -n "${NIXBOT_USER_OVERRIDE}" ]; then
    # If user override is set but key override is not, avoid forcing default key.
    NIXBOT_DEFAULT_KEY_PATH=""
  fi

  if [ -n "${NIXBOT_KNOWN_HOSTS_OVERRIDE}" ]; then
    NIXBOT_DEFAULT_KNOWN_HOSTS="${NIXBOT_KNOWN_HOSTS_OVERRIDE}"
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

  if [ -f "${NIXBOT_CONFIG_DIR}/${key_path}" ]; then
    printf '%s/%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
    return
  fi

  if [ -f "${NIXBOT_CONFIG_DIR}/../${key_path}" ]; then
    printf '%s/../%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
    return
  fi

  printf '%s/%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
}

resolve_runtime_key_file() {
  local key_path="$1" require_age="${2:-0}"
  local src_path="" out_file="" decrypt_identity="" age_stderr_file=""
  local decrypt_errors_file="" candidate_count=0 readable_candidate_count=0

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

  emit_normalized_hosts "${HOSTS_RAW}" | jq -Rn '[inputs | select(length > 0)]'
}

host_dependencies_for() {
  local node="$1"
  host_predecessors_for "${node}" dependency
}

# Emit all ordering predecessors (deps + after) for a host.
host_predecessors_for() {
  local node="$1" mode="${2:-all}"
  local parent=""

  parent="$(host_parent_for "${node}")"
  jq -r --arg h "${node}" --arg parent "${parent}" --arg mode "${mode}" '
    (
      (.[$h].deps // [])
      + (if $mode == "all" then (.[$h].after // []) else [] end)
      + (if $parent == "" then [] else [$parent] end)
    )
    | unique
    | .[]
  ' <<<"${NIXBOT_HOSTS_JSON}"
}

host_skip_enabled() {
  local node="$1" raw_value=""

  raw_value="$(jq -r --arg h "${node}" '.[$h].skip // false' <<<"${NIXBOT_HOSTS_JSON}")"
  case "${raw_value}" in
    true)
      return 0
      ;;
    false)
      return 1
      ;;
    *)
      die "Unsupported skip value for ${node}: ${raw_value}"
      ;;
  esac
}

host_deploy_mode() {
  local node="$1" raw_value=""

  raw_value="$(jq -r --arg h "${node}" '.[$h].deploy // "strict"' <<<"${NIXBOT_HOSTS_JSON}")"
  case "${raw_value}" in
    strict|optional|skip)
      printf '%s\n' "${raw_value}"
      ;;
    *)
      die "Unsupported deploy policy for ${node}: ${raw_value}"
      ;;
  esac
}

host_optional_deploy_enabled() {
  [ "$(host_deploy_mode "$1")" = "optional" ]
}

host_deploy_stage_skipped() {
  [ "$(host_deploy_mode "$1")" = "skip" ]
}

host_wait_seconds() {
  local node="$1"
  jq -r --arg h "${node}" '.[$h].wait // 0' <<<"${NIXBOT_HOSTS_JSON}"
}

host_parent_for() {
  local node="$1"
  jq -r --arg h "${node}" '.[$h].parent // ""' <<<"${NIXBOT_HOSTS_JSON}"
}

host_parent_resource_for() {
  local node="$1"
  jq -r --arg h "${node}" '.[$h].parentResource // $h' <<<"${NIXBOT_HOSTS_JSON}"
}

host_parent_reconcile_template_for() {
  local node="$1"
  jq -r --arg h "${node}" --arg default "${NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE}" \
    '.[$h].parentReconcileCommand // $default' <<<"${NIXBOT_HOSTS_JSON}"
}

host_parent_settle_template_for() {
  local node="$1"
  jq -r --arg h "${node}" --arg default "${NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE}" \
    '.[$h].parentSettleCommand // $default' <<<"${NIXBOT_HOSTS_JSON}"
}

wait_before_host_phase() {
  local node="$1" phase="$2" wait_secs=""

  wait_secs="$(host_wait_seconds "${node}")"
  if [ "${wait_secs}" -gt 0 ] 2>/dev/null; then
    echo "[${node}] ${phase} | waiting ${wait_secs}s before ${phase}" >&2
    sleep "${wait_secs}"
  fi
}

expand_selected_hosts_json() {
  local selected_json="$1" all_hosts_json="$2" node="" dep=""
  local -a queue=() expanded_hosts=()
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
  local selected_json="$1" all_hosts_json="$2" node="" dep="" progress="" bastion_host="${BASTION_TRIGGER_HOST}"
  local -a selected_hosts=() runnable_selected_hosts=() skipped_hosts=() ordered_hosts=()
  declare -A all_host_set=()
  declare -A selected_host_set=()
  declare -A emitted_host_set=()
  declare -A indegree=()
  declare -A dependents=()

  json_array_to_bash_array "${selected_json}" selected_hosts
  json_array_to_bash_set "${all_hosts_json}" all_host_set

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if host_skip_enabled "${node}"; then
      skipped_hosts+=("${node}")
      continue
    fi
    runnable_selected_hosts+=("${node}")
    selected_host_set["${node}"]=1
    indegree["${node}"]=0
  done

  for node in "${runnable_selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
        continue
      fi
      if [ -z "${all_host_set["${dep}"]+x}" ]; then
        die "Unknown dependency/ordering host declared for ${node}: ${dep}"
      fi
      if [ -n "${selected_host_set["${dep}"]+x}" ]; then
        indegree["${node}"]=$((indegree["${node}"] + 1))
        dependents["${dep}"]+="${node}"$'\n'
      fi
    done < <(host_predecessors_for "${node}")
  done

  if [ "${PRIORITIZE_BASTION_FIRST}" -eq 1 ] && [ -n "${selected_host_set["${bastion_host}"]+x}" ]; then
    emitted_host_set["${bastion_host}"]=1
    ordered_hosts+=("${bastion_host}")
    while IFS= read -r dep; do
      [ -n "${dep}" ] || continue
      indegree["${dep}"]=$((indegree["${dep}"] - 1))
    done <<<"${dependents["${bastion_host}"]:-}"
  fi

  while [ "${#ordered_hosts[@]}" -lt "${#runnable_selected_hosts[@]}" ]; do
    progress=0
    for node in "${runnable_selected_hosts[@]}"; do
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
      for node in "${runnable_selected_hosts[@]}"; do
        [ -n "${node}" ] || continue
        if [ -z "${emitted_host_set["${node}"]+x}" ]; then
          cycle_hosts+=("${node}")
        fi
      done
      die "Host dependency cycle detected among: ${cycle_hosts[*]}"
    fi
  done

  ordered_hosts+=("${skipped_hosts[@]}")

  jq -cn '$ARGS.positional' --args "${ordered_hosts[@]}"
}

selected_host_levels_json() {
  local selected_json="$1" node="" dep="" dep_level="" node_level=""
  local max_level="" level="" bastion_host="${BASTION_TRIGGER_HOST}"
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
        [ -n "${dep_level}" ] || die "Predecessor level missing for ${node}: ${dep}"
        if [ $((dep_level + 1)) -gt "${node_level}" ]; then
          node_level=$((dep_level + 1))
        fi
      fi
    done < <(host_predecessors_for "${node}")

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
  local selected_json="$1" all_hosts_json="$2" invalid=""

  invalid="$(jq -n --argjson selected "${selected_json}" --argjson all "${all_hosts_json}" '$selected - $all')"

  if [ "$(jq 'length' <<<"${invalid}")" -gt 0 ]; then
    die "Unknown hosts requested: $(jq -r 'join(", ")' <<<"${invalid}")"
  fi

  [ "$(jq 'length' <<<"${selected_json}")" -gt 0 ] || die "No hosts selected"
}

validate_selected_host_execution_policies() {
  local selected_json="$1" node="" dep=""
  local -a selected_hosts=() deps=()

  json_array_to_bash_array "${selected_json}" selected_hosts

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if host_skip_enabled "${node}"; then
      continue
    fi

    mapfile -t deps < <(host_dependencies_for "${node}")
    for dep in "${deps[@]}"; do
      [ -n "${dep}" ] || continue
      if host_skip_enabled "${dep}"; then
        die "Host ${node} cannot depend on skipped host ${dep}"
      fi
      if [ "$(host_deploy_mode "${dep}")" != "strict" ]; then
        die "Host ${node} cannot depend on non-strict deploy host ${dep}"
      fi
    done
  done
}

filter_runnable_hosts_json() {
  local selected_json="$1" node=""
  local -a selected_hosts=() runnable_hosts=()

  FULLY_SKIPPED_HOSTS=()
  json_array_to_bash_array "${selected_json}" selected_hosts

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if host_skip_enabled "${node}"; then
      FULLY_SKIPPED_HOSTS+=("${node}")
      continue
    fi
    runnable_hosts+=("${node}")
  done

  jq -cn '$ARGS.positional' --args "${runnable_hosts[@]}"
}

resolve_selected_hosts_json() {
  local all_hosts_json="$1" selected_json=""

  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"
  selected_json="$(expand_selected_hosts_json "${selected_json}" "${all_hosts_json}")"
  validate_selected_host_execution_policies "${selected_json}"
  order_selected_hosts_json "${selected_json}" "${all_hosts_json}"
}

prepare_run_context() {
  local -n prc_selected_json_out_ref="$1"
  local config_json="" all_hosts_json=""

  if [ -n "${NIXBOT_CONFIG_PATH}" ]; then
    config_json="$(load_deploy_config_json "${NIXBOT_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  all_hosts_json="$(load_all_hosts_json)"
  # Keep this as an in-process write: init_deploy_settings mutates global
  # deploy defaults/host metadata that must survive after this helper returns.
  # shellcheck disable=SC2034
  prc_selected_json_out_ref="$(resolve_selected_hosts_json "${all_hosts_json}")"
}

log_run_context() {
  local selected_json="$1" node="" mode="" wait_secs="" parent_host="" annotation=""
  local -a log_hosts=() annotated_hosts=()

  json_array_to_bash_array "${selected_json}" log_hosts

  for node in "${log_hosts[@]}"; do
    [ -n "${node}" ] || continue
    annotation=""
    mode="$(host_deploy_mode "${node}")"
    if [ "${mode}" != "strict" ]; then
      annotation="deploy: ${mode}"
    fi
    wait_secs="$(host_wait_seconds "${node}")"
    if [ "${wait_secs}" -gt 0 ] 2>/dev/null; then
      annotation="${annotation:+${annotation}, }wait: ${wait_secs}s"
    fi
    parent_host="$(host_parent_for "${node}")"
    if [ -n "${parent_host}" ]; then
      annotation="${annotation:+${annotation}, }parent: ${parent_host}"
    fi
    if [ -n "${annotation}" ]; then
      annotated_hosts+=("${node} (${annotation})")
    else
      annotated_hosts+=("${node}")
    fi
  done

  log_section "nixbot"
  echo "Version: ${NIXBOT_VERSION}" >&2
  echo "Action: ${ACTION}" >&2
  print_host_block "Hosts" "${annotated_hosts[@]}"
  if is_deploy_style_action; then
    echo "Goal: ${GOAL}" >&2
    echo "Build host: ${BUILD_HOST}" >&2
  fi
}

##### Deploy Target / SSH Context #####

resolve_deploy_target() {
  local node="$1"

  jq -c --arg h "${node}" \
    --arg defUser "${NIXBOT_DEFAULT_USER}" \
    --arg defTarget "${node}" \
    --arg defPort "${NIXBOT_DEFAULT_PORT}" \
    --arg defKey "${NIXBOT_DEFAULT_KEY_PATH}" \
    --arg defKnown "${NIXBOT_DEFAULT_KNOWN_HOSTS}" \
    --arg defBKey "${NIXBOT_DEFAULT_BOOTSTRAP_KEY}" \
    --arg defBUser "${NIXBOT_DEFAULT_BOOTSTRAP_USER}" \
    --arg defBPort "${NIXBOT_DEFAULT_BOOTSTRAP_PORT}" \
    --arg defBKeyPath "${NIXBOT_DEFAULT_BOOTSTRAP_KEY_PATH}" \
    --arg defAgeKey "${NIXBOT_DEFAULT_AGE_IDENTITY_KEY}" \
    '(.[$h] // {}) as $cfg |
    def fb($v; $d): ($v // "") | if . == "" then $d else . end;
    def portfb($v; $d): if ($v == null or $v == "") then $d else ($v | tostring) end;
    {
      user: fb($cfg.user; $defUser),
      target: fb($cfg.target; $defTarget),
      port: portfb($cfg.port; $defPort),
      keyPath: fb($cfg.key; $defKey),
      knownHosts: fb($cfg.knownHosts; $defKnown),
      bootstrapKey: fb($cfg.bootstrapKey; $defBKey),
      bootstrapUser: fb($cfg.bootstrapUser; $defBUser),
      bootstrapPort: portfb($cfg.bootstrapPort; portfb($cfg.port; $defBPort)),
      bootstrapKeyPath: fb($cfg.bootstrapKeyPath; $defBKeyPath),
      ageIdentityKey: fb($cfg.ageIdentityKey; $defAgeKey),
      proxyJump: ($cfg.proxyJump // "")
    }' <<<"${NIXBOT_HOSTS_JSON}"
}

resolve_proxy_chain() {
  local start_host="$1"

  [ -n "${start_host}" ] || return 0

  jq -c \
    --arg start "${start_host}" \
    --arg defUser "${NIXBOT_DEFAULT_USER}" \
    --arg defPort "${NIXBOT_DEFAULT_PORT}" \
    --arg defKey "${NIXBOT_DEFAULT_KEY_PATH}" '
    def fb($v; $d): ($v // "") | if . == "" then $d else . end;
    def portfb($v; $d): if ($v == null or $v == "") then $d else ($v | tostring) end;
    def resolve_chain($h; $visited):
      if $h == "" then []
      elif ($visited | index($h)) then
        error("proxyJump cycle detected: \($visited + [$h] | join(" -> "))")
      else
        (.[$h] // {}) as $cfg |
        ($cfg.target // $h) as $target |
        (fb($cfg.user; $defUser)) as $user |
        (portfb($cfg.port; $defPort)) as $port |
        (fb($cfg.key; $defKey)) as $keyPath |
        ($cfg.proxyJump // "") as $next |
        resolve_chain($next; $visited + [$h]) + [{
          node: $h,
          target: $target,
          port: $port,
          connectTarget: (if $user == "" then $target else "\($user)@\($target)" end),
          connectPort: $port,
          keyPath: $keyPath
        }]
      end;
    resolve_chain($start; [])[]
  ' <<<"${NIXBOT_HOSTS_JSON}"
}

resolve_effective_proxy_chain() {
  local proxy_jump="$1" hop_json="" proxy_target=""
  local trim_local_hops=1

  [ -n "${proxy_jump}" ] || return 0

  while IFS= read -r hop_json; do
    [ -n "${hop_json}" ] || continue
    proxy_target="$(jq -r '.target' <<<"${hop_json}")"
    [ -n "${proxy_target}" ] || continue
    if [ "${trim_local_hops}" -eq 1 ] && local_host_matches_identifier "${proxy_target}"; then
      continue
    fi

    trim_local_hops=0
    printf '%s\n' "${hop_json}"
  done < <(resolve_proxy_chain "${proxy_jump}")
}

ensure_known_hosts_file() {
  local node="$1" known_hosts="$2" safe_node="" known_hosts_file=""

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
  local host="$1" known_hosts="$2" known_hosts_file="$3"

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

format_ssh_connect_target() {
  local target="$1" user_prefix="" host_only=""

  if [[ "${target}" == *@* ]]; then
    user_prefix="${target%@*}@"
  fi
  host_only="$(ssh_host_from_target "${target}")"
  printf '%s%s\n' "${user_prefix}" "${host_only}"
}

format_ssh_forward_target() {
  local target="$1" port="${2:-22}" host_only=""

  host_only="$(ssh_host_from_target "${target}")"
  if [[ "${host_only}" == *:* ]]; then
    host_only="[${host_only}]"
  fi
  printf '%s:%s\n' "${host_only}" "${port}"
}

is_ip_address() {
  local value="$1"

  case "${value}" in
    *:*) return 0 ;;
    [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_identifier_addresses() {
  local identifier="$1" host_only="" addr=""

  [ -n "${identifier}" ] || return 0
  host_only="$(ssh_host_from_target "${identifier}")"
  [ -n "${host_only}" ] || return 0

  if is_ip_address "${host_only}"; then
    printf '%s\n' "${host_only}"
  fi

  if ! command -v getent >/dev/null 2>&1; then
    return 0
  fi

  while read -r addr _; do
    [ -n "${addr}" ] || continue
    printf '%s\n' "${addr}"
  done < <(getent ahosts "${host_only}" 2>/dev/null || true)
}

local_host_matches_identifier() {
  local identifier="$1" host_only="" alias="" addr=""

  [ -n "${identifier}" ] || return 1
  host_only="$(ssh_host_from_target "${identifier}")"

  for alias in "${CURRENT_HOST_ALIASES[@]}"; do
    [ -n "${alias}" ] || continue
    if [ "${host_only}" = "${alias}" ] || [ "${host_only%%.*}" = "${alias}" ]; then
      return 0
    fi
  done

  while IFS= read -r addr; do
    [ -n "${addr}" ] || continue
    if array_contains "${addr}" "${CURRENT_HOST_ADDRESSES[@]}"; then
      return 0
    fi
  done < <(resolve_identifier_addresses "${identifier}")

  return 1
}

should_use_local_self_target() {
  case "${NIXBOT_LOCAL_SELF_TARGET_MODE}" in
    on|true|1|yes)
      return 0
      ;;
    off|false|0|no)
      return 1
      ;;
    auto)
      return 0
      ;;
    *)
      die "Unsupported NIXBOT_LOCAL_SELF_TARGET value: ${NIXBOT_LOCAL_SELF_TARGET_MODE}"
      ;;
  esac
}

mark_bootstrap_ready() {
  local node="$1"
  local state_file=""

  ensure_tmp_dir
  state_file="${NIXBOT_TMP_DIR}/bootstrap-ready.nodes"
  case " ${BOOTSTRAP_READY_NODES} " in
    *" ${node} "*) return 0 ;;
    *) BOOTSTRAP_READY_NODES="${BOOTSTRAP_READY_NODES} ${node}" ;;
  esac
  if ! { [ -f "${state_file}" ] && grep -Fxq "${node}" "${state_file}"; }; then
    printf '%s\n' "${node}" >> "${state_file}"
  fi
}

is_bootstrap_ready() {
  local node="$1"
  local state_file=""

  case " ${BOOTSTRAP_READY_NODES} " in
    *" ${node} "*) return 0 ;;
  esac

  ensure_tmp_dir
  state_file="${NIXBOT_TMP_DIR}/bootstrap-ready.nodes"
  if [ -f "${state_file}" ] && grep -Fxq "${node}" "${state_file}"; then
    BOOTSTRAP_READY_NODES="${BOOTSTRAP_READY_NODES} ${node}"
    return 0
  fi

  return 1
}

mark_primary_ready() {
  local node="$1"
  local state_file=""

  ensure_tmp_dir
  state_file="${NIXBOT_TMP_DIR}/primary-ready.nodes"
  case " ${PRIMARY_READY_NODES} " in
    *" ${node} "*) return 0 ;;
    *) PRIMARY_READY_NODES="${PRIMARY_READY_NODES} ${node}" ;;
  esac
  if ! { [ -f "${state_file}" ] && grep -Fxq "${node}" "${state_file}"; }; then
    printf '%s\n' "${node}" >> "${state_file}"
  fi
}

is_primary_ready() {
  local node="$1"
  local state_file=""

  case " ${PRIMARY_READY_NODES} " in
    *" ${node} "*) return 0 ;;
  esac

  ensure_tmp_dir
  state_file="${NIXBOT_TMP_DIR}/primary-ready.nodes"
  if [ -f "${state_file}" ] && grep -Fxq "${node}" "${state_file}"; then
    PRIMARY_READY_NODES="${PRIMARY_READY_NODES} ${node}"
    return 0
  fi

  return 1
}

check_bootstrap_via_forced_command() {
  local node="$1" ssh_target="$2"
  local -a ssh_opts=("${@:3}") check_ssh_opts=() check_remote_cmd=()
  local check_output="" check_key_file="" remote_config_path="" i="" opt="" skip_next=0

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

  if [ -n "${NIXBOT_BASTION_KEY_PATH_OVERRIDE}" ]; then
    ensure_tmp_dir
    if ! check_key_file="$(resolve_runtime_key_file "${NIXBOT_BASTION_KEY_PATH_OVERRIDE}" 1)"; then
      return 1
    fi
    if [ ! -f "${check_key_file}" ]; then
      echo "Forced-command key file not found: ${NIXBOT_BASTION_KEY_PATH_OVERRIDE} (resolved: ${check_key_file})" >&2
      return 1
    fi
    check_ssh_opts=(-i "${check_key_file}" -o IdentitiesOnly=yes "${check_ssh_opts[@]}")
  fi

  check_remote_cmd=("${REMOTE_NIXBOT_DEPLOY_SCRIPT}" check-bootstrap)
  if [ -n "${SHA}" ]; then
    check_remote_cmd+=(--sha "${SHA}")
  fi
  check_remote_cmd+=(--hosts "${node}")
  if [ -n "${NIXBOT_CONFIG_PATH}" ]; then
    if [[ "${NIXBOT_CONFIG_PATH}" != /* ]]; then
      remote_config_path="${NIXBOT_CONFIG_PATH}"
    elif remote_config_path="$(repo_relative_path "${NIXBOT_CONFIG_PATH}" "${REPO_WORKTREE_ROOT}")"; then
      :
    elif remote_config_path="$(repo_relative_path "${NIXBOT_CONFIG_PATH}" "${REPO_ROOT}")"; then
      :
    else
      echo "Cannot forward absolute config path for forced-command bootstrap check: ${NIXBOT_CONFIG_PATH}" >&2
      return 1
    fi
    check_remote_cmd+=(--config "${remote_config_path}")
  fi

  if retry_transport_capture \
    check_output \
    "Forced-command bootstrap check for ${node}" \
    "" \
    ssh \
    "${check_ssh_opts[@]}" \
    "${ssh_target}" \
    "${check_remote_cmd[@]}"; then
    echo "==> Bootstrap key validated via forced command for ${node}"
    return 0
  fi

  if [[ "${check_output}" == *"Unsupported action: check-bootstrap"* ]] || [[ "${check_output}" == *"invalid action"* ]]; then
    echo "==> Remote forced command is on an older revision (no check-bootstrap action); treating auth as valid for ${node}"
    return 0
  fi

  echo "==> Forced-command bootstrap check failed for ${node}; continuing with bootstrap injection fallback" >&2
  printf '%s\n' "${check_output}" >&2
  return 1
}

inject_bootstrap_nixbot_key() {
  local node="$1" bootstrap_ssh_target="$2" bootstrap_nixbot_key_path="$3"
  local -a bootstrap_ssh_opts=("${@:4}")
  local bootstrap_key_file="" remote_tmp="" expected_bootstrap_fpr="" remote_check_rc=0
  local bootstrap_dest="${REMOTE_NIXBOT_PRIMARY_KEY}" bootstrap_legacy_dest="${REMOTE_NIXBOT_LEGACY_KEY}"

  if [ -z "${bootstrap_nixbot_key_path}" ]; then
    return
  fi

  ensure_tmp_dir
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

  # shellcheck disable=SC2016
  if target_file_matches_expected_value \
    0 \
    "${bootstrap_ssh_target}" \
    "${bootstrap_dest}" \
    "${expected_bootstrap_fpr}" \
    'ssh-keygen -lf "$DEST" | tr -s " " | cut -d " " -f2' \
    0 \
    "${bootstrap_ssh_opts[@]}" >/dev/null 2>&1; then
    echo "==> Skipping bootstrap nixbot key for ${node}; matching key already present on target"
    return
  else
    remote_check_rc="$?"
    if [ "${remote_check_rc}" -eq 255 ]; then
      echo "Unable to verify bootstrap key for ${node}; bootstrap target ${bootstrap_ssh_target} is unreachable" >&2
      return 1
    fi
  fi

  echo "==> Injecting bootstrap nixbot key for ${node}"
  # shellcheck disable=SC2016
  if ! install_local_file_via_target \
    "${node}" \
    "bootstrap key" \
    0 \
    "${bootstrap_ssh_target}" \
    "${bootstrap_key_file}" \
    "${REMOTE_BOOTSTRAP_KEY_TMP_PREFIX}" \
    "${bootstrap_dest}" \
    "${REMOTE_NIXBOT_SSH_DIR}" \
    "0700" \
    "0400" \
    'if sudo test -f "${remote_dest}"; then sudo install -m 0400 "${remote_dest}" "${bootstrap_legacy_dest}"; fi' \
    'if sudo id -u nixbot >/dev/null 2>&1; then sudo chown -R nixbot:nixbot '"${REMOTE_NIXBOT_SSH_DIR}"'; fi' \
    "bootstrap_legacy_dest='${bootstrap_legacy_dest}'" \
    0 \
    "${bootstrap_ssh_opts[@]}"; then
    return 1
  fi
}

build_remote_install_file_cmd() {
  local remote_tmp="$1" remote_dest="$2" remote_dir="$3"
  local remote_dir_mode="$4" remote_file_mode="$5"
  local before_install_cmd="${6:-}" after_install_cmd="${7:-}" extra_vars="${8:-}"

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
  local remote_dest="$1" expected_value="$2" read_cmd="$3" ask_sudo_password="${4:-0}"
  local sudo_cmd="sudo -n"

  if [ "${ask_sudo_password}" -eq 1 ]; then
    sudo_cmd="sudo"
  fi

  cat <<EOF
dest='${remote_dest}'
want='${expected_value}'
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to validate \${dest}" >&2
  exit 1
fi
current="\$(DEST="\${dest}" ${sudo_cmd} env DEST="\${dest}" sh -c '${read_cmd}' 2>/dev/null || true)"
[ "\${current}" = "\${want}" ]
EOF
}

run_target_command() {
  local local_exec="$1" ssh_target="$2" tty_mode="$3" target_cmd="$4"
  shift 4
  local -a ssh_opts=("$@")

  if [ "${local_exec}" -eq 1 ]; then
    bash -c "${target_cmd}"
  elif [ "${tty_mode}" -eq 1 ]; then
    ssh -tt "${ssh_opts[@]}" "${ssh_target}" "${target_cmd}" <"$(resolve_ssh_tty_stdin_path)"
  else
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${ssh_target}" "${target_cmd}"
  fi
}

transport_retry_backoff_seconds() {
  local attempt="$1"

  printf '%s\n' "$((NIXBOT_TRANSPORT_RETRY_DELAY_SECS * (attempt - 1)))"
}

retry_transport_command() {
  local retry_label="$1" retry_hook="${2:-}"
  shift 2
  local attempt=1 rc=0 retry_sleep_secs=0

  while :; do
    if "$@"; then
      return 0
    fi
    rc="$?"

    if [ "${rc}" -ne 255 ] || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
      return "${rc}"
    fi

    attempt=$((attempt + 1))
    retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
    echo "${retry_label} transport closed; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
    sleep "${retry_sleep_secs}"
    if [ -n "${retry_hook}" ]; then
      "${retry_hook}" || return "$?"
    fi
  done
}

retry_transport_capture() {
  # shellcheck disable=SC2034
  local -n rtc_output_out_ref="$1"
  local retry_label="$2" retry_hook="${3:-}"
  shift 3
  local attempt=1 rc=0 retry_sleep_secs=0 captured=""

  while :; do
    if captured="$("$@" 2>&1)"; then
      # shellcheck disable=SC2034
      rtc_output_out_ref="${captured}"
      return 0
    fi
    rc="$?"
    # shellcheck disable=SC2034
    rtc_output_out_ref="${captured}"

    if [ "${rc}" -ne 255 ] || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
      return "${rc}"
    fi

    attempt=$((attempt + 1))
    retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
    echo "${retry_label} transport closed; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
    sleep "${retry_sleep_secs}"
    if [ -n "${retry_hook}" ]; then
      "${retry_hook}" || return "$?"
    fi
  done
}

resolve_target_command_user() {
  local local_exec="$1" ssh_target="$2"

  if [ "${local_exec}" -eq 1 ]; then
    id -un
  else
    printf '%s\n' "${ssh_target%%@*}"
  fi
}

should_ask_sudo_password() {
  local deploy_user="$1" using_bootstrap_fallback="$2"

  [ "${using_bootstrap_fallback}" -eq 1 ] || { [ "${deploy_user}" != "root" ] && [ "${deploy_user}" != "nixbot" ]; }
}

resolve_target_sudo_policy() {
  local local_exec="$1" ssh_target="$2" using_bootstrap_fallback="$3"
  local deploy_user="" ask_sudo_password=0 sudo_tty_mode=0

  deploy_user="$(resolve_target_command_user "${local_exec}" "${ssh_target}")"
  if should_ask_sudo_password "${deploy_user}" "${using_bootstrap_fallback}"; then
    ask_sudo_password=1
  fi

  # Remote commands that invoke sudo should always allocate a TTY. Password
  # prompting is a separate concern from satisfying remote sudo/requiretty
  # policy.
  if [ "${local_exec}" -eq 0 ]; then
    sudo_tty_mode=1
  fi

  printf '%s\n%s\n%s\n' \
    "${deploy_user}" \
    "${ask_sudo_password}" \
    "${sudo_tty_mode}"
}

create_target_tmp_file() {
  local local_exec="$1" ssh_target="$2" tmp_prefix="$3"
  shift 3
  local -a ssh_opts=("$@")

  if [ "${local_exec}" -eq 1 ]; then
    umask 077
    mktemp "${tmp_prefix}XXXXXX"
  else
    run_target_command "${local_exec}" "${ssh_target}" 0 "umask 077; mktemp ${tmp_prefix}XXXXXX" "${ssh_opts[@]}"
  fi
}

cleanup_target_tmp_file() {
  local local_exec="$1" ssh_target="$2" target_tmp="$3"
  shift 3
  local -a ssh_opts=("$@")

  [ -n "${target_tmp}" ] || return 0
  if [ "${local_exec}" -eq 1 ]; then
    rm -f "${target_tmp}" || true
  else
    run_target_command "${local_exec}" "${ssh_target}" 0 "rm -f '${target_tmp}'" "${ssh_opts[@]}" >/dev/null 2>&1 || true
  fi
}

copy_local_file_to_target_tmp() {
  local local_exec="$1" local_file="$2" ssh_target="$3" target_tmp="$4"
  shift 4
  local -a ssh_opts=("$@")

  if [ "${local_exec}" -eq 1 ]; then
    cp "${local_file}" "${target_tmp}" && chmod 600 "${target_tmp}"
  else
    scp "${ssh_opts[@]}" "${local_file}" "${ssh_target}:${target_tmp}"
  fi
}

target_file_matches_expected_value() {
  local local_exec="$1" ssh_target="$2" remote_dest="$3"
  local expected_value="$4" read_cmd="$5" using_bootstrap_fallback="${6:-0}"
  shift 6
  local -a ssh_opts=("$@") sudo_policy=()
  local check_cmd="" ask_sudo_password=0 tty_mode=0 rc=0

  mapfile -t sudo_policy < <(resolve_target_sudo_policy "${local_exec}" "${ssh_target}" "${using_bootstrap_fallback}")
  ask_sudo_password="${sudo_policy[1]:-0}"
  tty_mode="${sudo_policy[2]:-0}"
  check_cmd="$(build_remote_file_value_check_cmd "${remote_dest}" "${expected_value}" "${read_cmd}" "${ask_sudo_password}")"
  if retry_transport_command \
    "Remote file validation on ${ssh_target}" \
    "" \
    run_target_command \
    "${local_exec}" \
    "${ssh_target}" \
    "${tty_mode}" \
    "${check_cmd}" \
    "${ssh_opts[@]}"; then
    return 0
  fi
  rc="$?"
  return "${rc}"
}

install_local_file_via_target() {
  local node="$1" install_label="$2" local_exec="$3" ssh_target="$4"
  local local_file="$5" tmp_prefix="$6" remote_dest="$7" remote_dir="$8"
  local remote_dir_mode="$9" remote_file_mode="${10}"
  local before_install_cmd="${11:-}" after_install_cmd="${12:-}" extra_vars="${13:-}"
  local using_bootstrap_fallback="${14:-0}"
  shift 14
  local -a ssh_opts=("$@") sudo_policy=()
  local target_tmp="" install_cmd="" tty_mode=0

  if ! retry_transport_capture \
    target_tmp \
    "Remote temp allocation for ${install_label} on ${ssh_target}" \
    "" \
    create_target_tmp_file \
    "${local_exec}" \
    "${ssh_target}" \
    "${tmp_prefix}" \
    "${ssh_opts[@]}"; then
    target_tmp=""
  fi
  if [ -z "${target_tmp}" ]; then
    echo "Failed to allocate remote temporary file for ${install_label} on ${node}" >&2
    return 1
  fi

  if ! retry_transport_command \
    "Copying ${install_label} to ${ssh_target}" \
    "" \
    copy_local_file_to_target_tmp \
    "${local_exec}" \
    "${local_file}" \
    "${ssh_target}" \
    "${target_tmp}" \
    "${ssh_opts[@]}"; then
    cleanup_target_tmp_file "${local_exec}" "${ssh_target}" "${target_tmp}" "${ssh_opts[@]}"
    return 1
  fi

  install_cmd="$(build_remote_install_file_cmd \
    "${target_tmp}" \
    "${remote_dest}" \
    "${remote_dir}" \
    "${remote_dir_mode}" \
    "${remote_file_mode}" \
    "${before_install_cmd}" \
    "${after_install_cmd}" \
    "${extra_vars}")"

  mapfile -t sudo_policy < <(resolve_target_sudo_policy "${local_exec}" "${ssh_target}" "${using_bootstrap_fallback}")
  tty_mode="${sudo_policy[2]:-0}"
  if ! retry_transport_command \
    "Installing ${install_label} on ${ssh_target}" \
    "" \
    run_target_command \
    "${local_exec}" \
    "${ssh_target}" \
    "${tty_mode}" \
    "${install_cmd}" \
    "${ssh_opts[@]}"; then
    cleanup_target_tmp_file "${local_exec}" "${ssh_target}" "${target_tmp}" "${ssh_opts[@]}"
    return 1
  fi
}

init_known_hosts_ssh_context() {
  local batch_mode="$1" known_hosts_file="$2"
  # shellcheck disable=SC2178
  local -n ikhsc_ssh_opts_out_ref="$3" ikhsc_nix_sshopts_out_ref="$4"
  local host_key_check="${5:-yes}"

  ikhsc_ssh_opts_out_ref=(-o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o "StrictHostKeyChecking=${host_key_check}")
  ikhsc_nix_sshopts_out_ref="-o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=${host_key_check}"

  if [ "${batch_mode}" -eq 1 ]; then
    ikhsc_ssh_opts_out_ref=(-o BatchMode=yes "${ikhsc_ssh_opts_out_ref[@]}")
    ikhsc_nix_sshopts_out_ref="-o BatchMode=yes ${ikhsc_nix_sshopts_out_ref}"
  fi
}

apply_control_master_to_ssh_context() {
  local node="$1" role="$2"
  # shellcheck disable=SC2178
  local -n acmtsc_ssh_opts_inout_ref="$3" acmtsc_nix_sshopts_inout_ref="$4"
  local safe_node="" control_path=""

  ensure_tmp_dir
  safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}-${role}")"
  control_path="${TMP_SSH_DIR}/cm-${safe_node}"

  acmtsc_ssh_opts_inout_ref+=(
    -o ControlMaster=auto
    -o "ControlPath=${control_path}"
    -o "ControlPersist=${NIXBOT_CONTROL_PERSIST_SECS}"
  )
  acmtsc_nix_sshopts_inout_ref="${acmtsc_nix_sshopts_inout_ref:+${acmtsc_nix_sshopts_inout_ref} }-o ControlMaster=auto -o ControlPath=${control_path} -o ControlPersist=${NIXBOT_CONTROL_PERSIST_SECS}"
}

apply_port_to_ssh_context() {
  local port="$1"
  # shellcheck disable=SC2178
  local -n aptsc_ssh_opts_inout_ref="$2" aptsc_nix_sshopts_inout_ref="$3"

  [ -n "${port}" ] || return 0

  aptsc_ssh_opts_inout_ref=(-o "Port=${port}" "${aptsc_ssh_opts_inout_ref[@]}")
  if [ -n "${aptsc_nix_sshopts_inout_ref}" ]; then
    aptsc_nix_sshopts_inout_ref="-o Port=${port} ${aptsc_nix_sshopts_inout_ref}"
  else
    aptsc_nix_sshopts_inout_ref="-o Port=${port}"
  fi
}

apply_identity_to_ssh_context() {
  local key_file="$1"
  # shellcheck disable=SC2178
  local -n aitsc_ssh_opts_inout_ref="$2" aitsc_nix_sshopts_inout_ref="$3"

  aitsc_ssh_opts_inout_ref=(-i "${key_file}" -o IdentitiesOnly=yes "${aitsc_ssh_opts_inout_ref[@]}")
  if [ -n "${aitsc_nix_sshopts_inout_ref}" ]; then
    aitsc_nix_sshopts_inout_ref="-i ${key_file} -o IdentitiesOnly=yes ${aitsc_nix_sshopts_inout_ref}"
  else
    aitsc_nix_sshopts_inout_ref="-i ${key_file} -o IdentitiesOnly=yes"
  fi
}

resolve_ssh_identity_file() {
  local key_path="$1" label="$2" require_age="${3:-0}"
  local resolved_key_file=""

  [ -n "${key_path}" ] || return 0

  ensure_tmp_dir
  if ! resolved_key_file="$(resolve_runtime_key_file "${key_path}" "${require_age}")"; then
    return 1
  fi
  if [ ! -f "${resolved_key_file}" ]; then
    echo "${label} file not found: ${key_path} (resolved: ${resolved_key_file})" >&2
    return 1
  fi

  printf '%s\n' "${resolved_key_file}"
}

prepare_host_ssh_contexts() {
  local node="$1" host="$2" known_hosts="$3"
  # shellcheck disable=SC2178
  local -n phsc_host_ssh_opts_out_ref="$4"
  # shellcheck disable=SC2178
  local -n phsc_host_nix_sshopts_out_ref="$5"
  # shellcheck disable=SC2178,SC2034
  local -n phsc_bootstrap_ssh_opts_out_ref="$6"
  # shellcheck disable=SC2178,SC2034
  local -n phsc_bootstrap_nix_sshopts_out_ref="$7"
  local proxy_chain="${8:-}"
  local known_hosts_file="" build_host_host=""

  # shellcheck disable=SC2034
  phsc_host_ssh_opts_out_ref=()
  # shellcheck disable=SC2034
  phsc_host_nix_sshopts_out_ref=""
  # shellcheck disable=SC2034
  phsc_bootstrap_ssh_opts_out_ref=()
  # shellcheck disable=SC2034
  phsc_bootstrap_nix_sshopts_out_ref=""

  if [ "${DRY_RUN}" -eq 1 ]; then
    return 0
  fi

  ensure_tmp_dir
  known_hosts_file="$(ensure_known_hosts_file "${node}" "${known_hosts}")"
  # When there is a proxy chain, the target host is not directly reachable
  # from here — its host key will be scanned later through the proxy in
  # prepare_deploy_context.  Scan it now only when there is no proxy.
  if [ -z "${proxy_chain}" ]; then
    ensure_known_host "${host}" "${known_hosts}" "${known_hosts_file}"
  fi
  # Scan all directly-reachable intermediate hops.
  if [ -n "${proxy_chain}" ]; then
    local -a _chain_hops=()
    local hop_json="" hop_target=""
    while IFS= read -r hop_json; do
      [ -n "${hop_json}" ] || continue
      _chain_hops+=("${hop_json}")
    done <<<"${proxy_chain}"
    # The first hop is directly reachable; subsequent hops are behind proxies
    # and will be scanned through the proxy scripts built in prepare_deploy_context.
    if [ "${#_chain_hops[@]}" -gt 0 ]; then
      hop_target="$(jq -r '.target' <<<"${_chain_hops[0]}")"
      ensure_known_host "${hop_target}" "${known_hosts}" "${known_hosts_file}"
    fi
  fi
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

  # When the target is behind a proxy, ssh-keyscan cannot reach it
  # (it has no ProxyCommand support).  Use accept-new so the host key
  # is recorded on first contact — same trust model as the proxy scripts.
  # accept-new still rejects CHANGED keys (MITM protection).
  local host_key_check="yes"
  if [ -n "${proxy_chain}" ]; then
    host_key_check="accept-new"
  fi
  init_known_hosts_ssh_context 1 "${known_hosts_file}" phsc_host_ssh_opts_out_ref phsc_host_nix_sshopts_out_ref "${host_key_check}"
  init_known_hosts_ssh_context 0 "${known_hosts_file}" phsc_bootstrap_ssh_opts_out_ref phsc_bootstrap_nix_sshopts_out_ref "${host_key_check}"
  if [ -z "${proxy_chain}" ]; then
    apply_control_master_to_ssh_context "${node}" primary phsc_host_ssh_opts_out_ref phsc_host_nix_sshopts_out_ref
    apply_control_master_to_ssh_context "${node}" bootstrap phsc_bootstrap_ssh_opts_out_ref phsc_bootstrap_nix_sshopts_out_ref
  fi
}

write_proxy_command_script() {
  local script_path="$1" known_hosts_file="$2" forward_target="$3" connect_target="$4"
  local connect_port="$5" previous_proxy_script="$6" identity_file="${7:-}"

  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -Eeuo pipefail'
    printf 'known_hosts_file=%q\n' "${known_hosts_file}"
    printf 'forward_target=%q\n' "${forward_target}"
    printf 'connect_target=%q\n' "${connect_target}"
    printf 'connect_port=%q\n' "${connect_port}"
    printf 'previous_proxy_script=%q\n' "${previous_proxy_script}"
    printf 'identity_file=%q\n' "${identity_file}"
    cat <<'EOF'
cmd=(ssh -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${known_hosts_file}")
if [ -n "${identity_file}" ]; then
  cmd+=(-i "${identity_file}" -o IdentitiesOnly=yes)
fi
if [ -n "${previous_proxy_script}" ]; then
  cmd+=(-o "ProxyCommand=${previous_proxy_script}")
fi
if [ -n "${connect_port}" ]; then
  cmd+=(-o "Port=${connect_port}")
fi
cmd+=(-W "${forward_target}" "${connect_target}")
exec "${cmd[@]}"
EOF
  } > "${script_path}"
  chmod +x "${script_path}"
}

apply_proxy_chain_to_ssh_contexts() {
  local node="$1" host="$2" target_port="$3" proxy_chain="$4"
  # shellcheck disable=SC2178
  local -n apctsc_host_ssh_opts_out_ref="$5" apctsc_host_nix_sshopts_out_ref="$6"
  # shellcheck disable=SC2178,SC2034
  local -n apctsc_bootstrap_ssh_opts_out_ref="$7" apctsc_bootstrap_nix_sshopts_out_ref="$8"
  local safe_node="" proxy_known_hosts_file=""
  local -a chain_hops=()
  local hop_json="" prev_script="" proxy_script="" proxy_cmd=""
  local i=0 fwd_host="" fwd_port=22
  local hop_target="" _hop_port="" hop_connect_target="" hop_connect_port="" hop_key_path="" hop_key_file=""

  [ -n "${proxy_chain}" ] || return 0

  ensure_tmp_dir

  # ProxyJump spawns a separate SSH process that does NOT inherit our custom
  # UserKnownHostsFile, so it falls back to ~/.ssh/known_hosts and can fail
  # with "REMOTE HOST IDENTIFICATION HAS CHANGED" on fresh/reinstalled hosts.
  # Use ProxyCommand instead so we can pass the known_hosts file through.
  # The proxy host key was already scanned into the node's known_hosts file
  # by prepare_host_ssh_contexts above.
  safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
  proxy_known_hosts_file="${TMP_SSH_DIR}/${NODE_KNOWN_HOSTS_PREFIX}.${safe_node}"

  while IFS= read -r hop_json; do
    [ -n "${hop_json}" ] || continue
    chain_hops+=("${hop_json}")
  done <<<"${proxy_chain}"

  for (( i=0; i<${#chain_hops[@]}; i++ )); do
    hop_json="${chain_hops[i]}"
    proxy_script="${TMP_SSH_DIR}/proxy-${safe_node}-${i}.sh"
    {
      read -r hop_target
      read -r _hop_port
      read -r hop_connect_target
      read -r hop_connect_port
      read -r hop_key_path
    } < <(jq -r '[.target, (.port // "22"), .connectTarget, (.connectPort // .port // "22"), (.keyPath // "")] | .[]' <<<"${hop_json}")
    if [ "${i}" -lt "$(( ${#chain_hops[@]} - 1 ))" ]; then
      fwd_host="$(jq -r '.target' <<<"${chain_hops[i+1]}")"
      fwd_port="$(jq -r '(.port // "22")' <<<"${chain_hops[i+1]}")"
    else
      fwd_host="${host}"
      fwd_port="${target_port}"
    fi

    hop_key_file=""
    if [ -n "${hop_key_path}" ]; then
      if ! hop_key_file="$(resolve_ssh_identity_file "${hop_key_path}" "Proxy hop SSH key (${hop_target})" 0)"; then
        return 1
      fi
    fi

    write_proxy_command_script \
      "${proxy_script}" \
      "${proxy_known_hosts_file}" \
      "$(format_ssh_forward_target "${fwd_host}" "${fwd_port}")" \
      "$(format_ssh_connect_target "${hop_connect_target}")" \
      "${hop_connect_port}" \
      "${prev_script}" \
      "${hop_key_file}"
    prev_script="${proxy_script}"
  done

  proxy_cmd="${prev_script}"
  apctsc_host_ssh_opts_out_ref+=(-o "ProxyCommand=${proxy_cmd}")
  apctsc_host_nix_sshopts_out_ref="${apctsc_host_nix_sshopts_out_ref:+${apctsc_host_nix_sshopts_out_ref} }-o ProxyCommand=${proxy_cmd}"
  apctsc_bootstrap_ssh_opts_out_ref+=(-o "ProxyCommand=${proxy_cmd}")
  apctsc_bootstrap_nix_sshopts_out_ref="${apctsc_bootstrap_nix_sshopts_out_ref:+${apctsc_bootstrap_nix_sshopts_out_ref} }-o ProxyCommand=${proxy_cmd}"
}

build_deploy_ssh_contexts() {
  local node="$1" host="$2" port="$3" bootstrap_port="$4" known_hosts="$5" proxy_chain="$6"
  local key_path="$7" bootstrap_key_path="$8"
  # shellcheck disable=SC2178,SC2034
  local -n bdsc_host_ssh_opts_out_ref="$9" bdsc_host_nix_sshopts_out_ref="${10}"
  # shellcheck disable=SC2178,SC2034
  local -n bdsc_bootstrap_ssh_opts_out_ref="${11}" bdsc_bootstrap_nix_sshopts_out_ref="${12}"
  local deploy_key_file="" bootstrap_key_file=""

  prepare_host_ssh_contexts \
    "${node}" \
    "${host}" \
    "${known_hosts}" \
    bdsc_host_ssh_opts_out_ref \
    bdsc_host_nix_sshopts_out_ref \
    bdsc_bootstrap_ssh_opts_out_ref \
    bdsc_bootstrap_nix_sshopts_out_ref \
    "${proxy_chain}" || return 1

  apply_port_to_ssh_context "${port}" bdsc_host_ssh_opts_out_ref bdsc_host_nix_sshopts_out_ref
  apply_port_to_ssh_context "${bootstrap_port}" bdsc_bootstrap_ssh_opts_out_ref bdsc_bootstrap_nix_sshopts_out_ref

  apply_proxy_chain_to_ssh_contexts \
    "${node}" \
    "${host}" \
    "${port}" \
    "${proxy_chain}" \
    bdsc_host_ssh_opts_out_ref \
    bdsc_host_nix_sshopts_out_ref \
    bdsc_bootstrap_ssh_opts_out_ref \
    bdsc_bootstrap_nix_sshopts_out_ref || return 1

  if [ -n "${key_path}" ]; then
    if ! deploy_key_file="$(resolve_ssh_identity_file "${key_path}" "Deploy SSH key" "${NIXBOT_KEY_OVERRIDE_EXPLICIT}")"; then
      return 1
    fi
    apply_identity_to_ssh_context "${deploy_key_file}" bdsc_host_ssh_opts_out_ref bdsc_host_nix_sshopts_out_ref
  fi

  if [ -n "${bootstrap_key_path}" ]; then
    if ! bootstrap_key_file="$(resolve_ssh_identity_file "${bootstrap_key_path}" "Bootstrap SSH key" 0)"; then
      return 1
    fi
    apply_identity_to_ssh_context "${bootstrap_key_file}" bdsc_bootstrap_ssh_opts_out_ref bdsc_bootstrap_nix_sshopts_out_ref
  fi
}

ensure_bootstrap_key_ready() {
  local node="$1" bootstrap_ssh_target="$2" bootstrap_nixbot_key_path="$3"
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

set_prepared_deploy_context() {
  local node="$1" ssh_target="$2" nix_sshopts="$3" using_bootstrap_fallback="$4"
  local age_identity_key="$5" local_exec="$6"
  shift 6
  local -a ssh_opts=("$@")

  PREP_DEPLOY_NODE="${node}"
  PREP_DEPLOY_SSH_TARGET="${ssh_target}"
  PREP_DEPLOY_NIX_SSHOPTS="${nix_sshopts}"
  PREP_USING_BOOTSTRAP_FALLBACK="${using_bootstrap_fallback}"
  PREP_DEPLOY_AGE_IDENTITY_KEY="${age_identity_key}"
  PREP_DEPLOY_LOCAL_EXEC="${local_exec}"
  PREP_DEPLOY_SSH_OPTS=("${ssh_opts[@]}")
}

set_prepared_remote_deploy_context() {
  local node="$1" ssh_target="$2" nix_sshopts="$3" age_identity_key="$4"
  shift 4
  local -a ssh_opts=("$@")

  set_prepared_deploy_context \
    "${node}" \
    "${ssh_target}" \
    "${nix_sshopts}" \
    0 \
    "${age_identity_key}" \
    0 \
    "${ssh_opts[@]}"
}

clear_prepared_deploy_context() {
  PREP_DEPLOY_NODE=""
  PREP_DEPLOY_SSH_TARGET=""
  PREP_DEPLOY_NIX_SSHOPTS=""
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_AGE_IDENTITY_KEY=""
  PREP_DEPLOY_LOCAL_EXEC=0
  PREP_DEPLOY_SSH_OPTS=()
}

probe_primary_deploy_target() {
  local ssh_target="$1"
  shift
  local -a ssh_opts=("$@")
  # shellcheck disable=SC2034
  local probe_output=""

  retry_transport_capture \
    probe_output \
    "Primary connectivity probe for ${ssh_target}" \
    "" \
    ssh \
    "${ssh_opts[@]}" \
    "${ssh_target}" \
    true
}

ensure_primary_deploy_connectivity() {
  local node="$1" host="$2" port="$3" bootstrap_port="$4" known_hosts="$5" ssh_target="$6"
  local full_proxy_chain="$7" effective_proxy_chain="$8"
  local key_path="$9" bootstrap_key_path="${10}" age_identity_key="${11}"
  # shellcheck disable=SC2178,SC2034
  local -n epdc_ssh_opts_inout_ref="${12}" epdc_bootstrap_ssh_opts_inout_ref="${14}"
  # shellcheck disable=SC2178,SC2034
  local -n epdc_nix_sshopts_inout_ref="${13}" epdc_bootstrap_nix_sshopts_inout_ref="${15}"

  if probe_primary_deploy_target "${ssh_target}" "${epdc_ssh_opts_inout_ref[@]}"; then
    mark_primary_ready "${node}"
    return 0
  fi

  if [ -z "${full_proxy_chain}" ] || [ "${full_proxy_chain}" = "${effective_proxy_chain}" ]; then
    return 1
  fi

  echo "==> Direct path to ${ssh_target} is unavailable; retrying with configured proxy chain"
  build_deploy_ssh_contexts \
    "${node}" \
    "${host}" \
    "${port}" \
    "${bootstrap_port}" \
    "${known_hosts}" \
    "${full_proxy_chain}" \
    "${key_path}" \
    "${bootstrap_key_path}" \
    epdc_ssh_opts_inout_ref \
    epdc_nix_sshopts_inout_ref \
    epdc_bootstrap_ssh_opts_inout_ref \
    epdc_bootstrap_nix_sshopts_inout_ref || return 1

  set_prepared_remote_deploy_context \
    "${node}" \
    "${ssh_target}" \
    "${epdc_nix_sshopts_inout_ref}" \
    "${age_identity_key}" \
    "${epdc_ssh_opts_inout_ref[@]}"

  if probe_primary_deploy_target "${ssh_target}" "${epdc_ssh_opts_inout_ref[@]}"; then
    mark_primary_ready "${node}"
    return 0
  fi

  return 1
}

prepare_bootstrap_deploy_context() {
  local node="$1" bootstrap_ssh_target="$2" bootstrap_nix_sshopts="$3"
  local age_identity_key="$4" bootstrap_key="$5"
  shift 5
  local -a bootstrap_ssh_opts=("$@")

  ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
  set_prepared_deploy_context \
    "${node}" \
    "${bootstrap_ssh_target}" \
    "${bootstrap_nix_sshopts}" \
    1 \
    "${age_identity_key}" \
    0 \
    "${bootstrap_ssh_opts[@]}"
}

inject_host_age_identity_key() {
  local node="$1" local_exec="$2" ssh_target="$3" age_identity_key_path="$4"
  local using_bootstrap_fallback="${5:-0}"
  local force_reinstall="${6:-0}"
  shift 6
  local -a ssh_opts=("$@")
  local age_identity_key_file="" expected_sha=""
  local remote_dest="${REMOTE_NIXBOT_AGE_IDENTITY}"

  if [ -z "${age_identity_key_path}" ]; then
    return
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    if ! read -r age_identity_key_file; then
      return 1
    fi < <(resolve_host_age_identity_key_file_and_sha "${node}" "${age_identity_key_path}")
    if [ "${local_exec}" -eq 1 ]; then
      echo "DRY: would inject host age identity ${age_identity_key_file} -> ${remote_dest}"
    else
      echo "DRY: would inject host age identity ${age_identity_key_file} -> ${ssh_target}:${remote_dest}"
    fi
    return
  fi

  {
    read -r age_identity_key_file
    read -r expected_sha
  } < <(resolve_host_age_identity_key_file_and_sha "${node}" "${age_identity_key_path}") || return 1

  if [ "${force_reinstall}" -ne 1 ]; then
    # shellcheck disable=SC2016
    if target_file_matches_expected_value \
      "${local_exec}" \
      "${ssh_target}" \
      "${remote_dest}" \
      "${expected_sha}" \
      'set -- $(sha256sum "$DEST"); printf "%s\n" "$1"' \
      "${using_bootstrap_fallback}" \
      "${ssh_opts[@]}"; then
      echo "==> Skipping host age identity for ${node}; matching key already present on target"
      return
    fi
  fi

  echo "==> Injecting host age identity for ${node}"
  # shellcheck disable=SC2016
  if ! install_local_file_via_target \
    "${node}" \
    "host age identity" \
    "${local_exec}" \
    "${ssh_target}" \
    "${age_identity_key_file}" \
    "${REMOTE_AGE_IDENTITY_TMP_PREFIX}" \
    "${remote_dest}" \
    "${REMOTE_NIXBOT_AGE_DIR}" \
    "0710" \
    "0440" \
    "" \
    'sudo chown root:nixbot "${remote_dir}" "${remote_dest}"' \
    "" \
    "${using_bootstrap_fallback}" \
    "${ssh_opts[@]}"; then
    return 1
  fi
}

resolve_host_age_identity_key_file_and_sha() {
  local node="$1" age_identity_key_path="$2"
  local age_identity_key_file="" expected_sha=""

  ensure_tmp_dir
  if ! age_identity_key_file="$(resolve_runtime_key_file "${age_identity_key_path}")"; then
    return 1
  fi
  if [ ! -f "${age_identity_key_file}" ]; then
    echo "Host age identity key not found for ${node}: ${age_identity_key_path} (resolved: ${age_identity_key_file})" >&2
    return 1
  fi

  expected_sha="$(sha256sum "${age_identity_key_file}" | awk '{print $1}')"
  if [ -z "${expected_sha}" ]; then
    echo "Unable to compute host age identity checksum for ${node}" >&2
    return 1
  fi

  printf '%s\n%s\n' "${age_identity_key_file}" "${expected_sha}"
}

prepare_deploy_context() {
  local node="$1" mode="${2:-normal}"
  local target_info="" user="" host="" port="" key_path="" known_hosts=""
  local bootstrap_key="" bootstrap_user="" bootstrap_port="" bootstrap_key_path=""
  local age_identity_key="" proxy_jump="" full_proxy_chain="" effective_proxy_chain=""
  local ssh_target="" bootstrap_ssh_target=""
  local local_exec=0 primary_target_ready=1
  local -a ssh_opts=() bootstrap_ssh_opts=()
  local nix_sshopts="" bootstrap_nix_sshopts=""

  clear_prepared_deploy_context

  target_info="$(resolve_deploy_target "${node}")"

  {
    read -r user
    read -r host
    read -r port
    read -r key_path
    read -r known_hosts
    read -r bootstrap_key
    read -r bootstrap_user
    read -r bootstrap_port
    read -r bootstrap_key_path
    read -r age_identity_key
    read -r proxy_jump
  } < <(jq -r '[.user, .target, (.port // "22"), (.keyPath // ""), (.knownHosts // ""), (.bootstrapKey // ""), (.bootstrapUser // ""), (.bootstrapPort // .port // "22"), (.bootstrapKeyPath // ""), (.ageIdentityKey // ""), (.proxyJump // "")] | .[]' <<<"${target_info}")

  ssh_target="${user}@${host}"
  bootstrap_ssh_target="${bootstrap_user}@${host}"

  if should_use_local_self_target \
    && { local_host_matches_identifier "${node}" || local_host_matches_identifier "${host}"; }; then
    local_exec=1
  fi
  if [ -n "${proxy_jump}" ]; then
    full_proxy_chain="$(resolve_proxy_chain "${proxy_jump}")"
    effective_proxy_chain="$(resolve_effective_proxy_chain "${proxy_jump}")"
  fi

  if [ "${local_exec}" -eq 1 ]; then
    set_prepared_deploy_context \
      "${node}" \
      "" \
      "" \
      0 \
      "${age_identity_key}" \
      1
    return 0
  fi

  build_deploy_ssh_contexts \
    "${node}" \
    "${host}" \
    "${port}" \
    "${bootstrap_port}" \
    "${known_hosts}" \
    "${effective_proxy_chain}" \
    "${key_path}" \
    "${bootstrap_key_path}" \
    ssh_opts \
    nix_sshopts \
    bootstrap_ssh_opts \
    bootstrap_nix_sshopts || return 1

  set_prepared_remote_deploy_context \
    "${node}" \
    "${ssh_target}" \
    "${nix_sshopts}" \
    "${age_identity_key}" \
    "${ssh_opts[@]}"

  if [ "${DRY_RUN}" -eq 0 ] && is_primary_ready "${node}"; then
    return 0
  fi

  if [ "${mode}" = "primary-only" ]; then
    :
  elif [ "${FORCE_BOOTSTRAP_PATH}" -eq 1 ]; then
    echo "==> Forcing bootstrap path for ${node}: ${bootstrap_ssh_target}"
    prepare_bootstrap_deploy_context \
      "${node}" \
      "${bootstrap_ssh_target}" \
      "${bootstrap_nix_sshopts}" \
      "${age_identity_key}" \
      "${bootstrap_key}" \
      "${bootstrap_ssh_opts[@]}" || return 1
    return
  fi

  if [ "${DRY_RUN}" -eq 0 ]; then
    if ! ensure_primary_deploy_connectivity \
      "${node}" \
      "${host}" \
      "${port}" \
      "${bootstrap_port}" \
      "${known_hosts}" \
      "${ssh_target}" \
      "${full_proxy_chain}" \
      "${effective_proxy_chain}" \
      "${key_path}" \
      "${bootstrap_key_path}" \
      "${age_identity_key}" \
      ssh_opts \
      nix_sshopts \
      bootstrap_ssh_opts \
      bootstrap_nix_sshopts; then
      primary_target_ready=0
    fi

    if [ "${mode}" = "primary-only" ]; then
      [ "${primary_target_ready}" -eq 1 ] || return 1
    elif [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
      if [ "${primary_target_ready}" -eq 0 ]; then
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

        prepare_bootstrap_deploy_context \
          "${node}" \
          "${bootstrap_ssh_target}" \
          "${bootstrap_nix_sshopts}" \
          "${age_identity_key}" \
          "${bootstrap_key}" \
          "${bootstrap_ssh_opts[@]}" || return 1
        return
      fi
    else
      ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
    fi
  elif [ -n "${bootstrap_key}" ]; then
    ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
  fi
}

run_prepared_deploy_command() {
  local tty_mode="$1" target_cmd="$2"

  if run_target_command \
    "${PREP_DEPLOY_LOCAL_EXEC}" \
    "${PREP_DEPLOY_SSH_TARGET}" \
    "${tty_mode}" \
    "${target_cmd}" \
    "${PREP_DEPLOY_SSH_OPTS[@]}"; then
    if [ -n "${PREP_DEPLOY_NODE}" ] && [ "${PREP_USING_BOOTSTRAP_FALLBACK}" -eq 0 ]; then
      mark_primary_ready "${PREP_DEPLOY_NODE}"
    fi
    return 0
  fi

  return 1
}

refresh_prepared_primary_target() {
  [ -n "${PREP_DEPLOY_NODE}" ] || return 0
  [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 0 ] || return 0

  prepare_deploy_context "${PREP_DEPLOY_NODE}" primary-only
}

run_prepared_deploy_command_with_retry() {
  local tty_mode="$1" retry_label="$2" target_cmd="$3"

  retry_transport_command \
    "${retry_label}" \
    refresh_prepared_primary_target \
    run_prepared_deploy_command \
    "${tty_mode}" \
    "${target_cmd}"
}

build_remote_activation_context_file_value_check_cmd() {
  local remote_dest="$1" expected_value="$2" read_cmd="$3" ask_sudo_password="${4:-0}"
  local sudo_cmd="sudo -n"

  if [ "${ask_sudo_password}" -eq 1 ]; then
    sudo_cmd="sudo"
  fi

  cat <<EOF
dest='${remote_dest}'
want='${expected_value}'
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to validate \${dest}" >&2
  exit 1
fi
current="\$(DEST="\${dest}" ${sudo_cmd} env DEST="\${dest}" sh -c 'systemd-run --wait --pipe --quiet --service-type=exec env DEST="\$DEST" sh -c '"'"'${read_cmd}'"'"' 2>/dev/null' 2>/dev/null || true)"
[ "\${current}" = "\${want}" ]
EOF
}

wait_for_prepared_host_age_identity_activation_visibility() {
  local node="$1" age_identity_key_path="$2"
  local age_identity_key_file="" expected_sha="" check_cmd="" ask_sudo_password=0 tty_mode=0
  local -a sudo_policy=()
  local attempt=1 max_attempts=10

  [ "${DRY_RUN}" -eq 0 ] || return 0

  [ -n "${age_identity_key_path}" ] || return 0

  {
    read -r age_identity_key_file
    read -r expected_sha
  } < <(resolve_host_age_identity_key_file_and_sha "${node}" "${age_identity_key_path}") || return 1

  mapfile -t sudo_policy < <(resolve_target_sudo_policy "${PREP_DEPLOY_LOCAL_EXEC}" "${PREP_DEPLOY_SSH_TARGET}" "${PREP_USING_BOOTSTRAP_FALLBACK}")
  ask_sudo_password="${sudo_policy[1]:-0}"
  tty_mode="${sudo_policy[2]:-0}"
  # shellcheck disable=SC2016
  check_cmd="$(build_remote_activation_context_file_value_check_cmd \
    "${REMOTE_NIXBOT_AGE_IDENTITY}" \
    "${expected_sha}" \
    'set -- $(sha256sum "$DEST"); printf "%s\n" "$1"' \
    "${ask_sudo_password}")"

  while [ "${attempt}" -le "${max_attempts}" ]; do
    if run_prepared_deploy_command_with_retry \
      "${tty_mode}" \
      "Activation-context host age identity validation on ${PREP_DEPLOY_SSH_TARGET}" \
      "${check_cmd}"; then
      return 0
    fi

    if [ "${attempt}" -ge "${max_attempts}" ]; then
      echo "Activation context never saw host age identity for ${node} after ${max_attempts} attempts" >&2
      return 1
    fi

    echo "==> Waiting for activation context to see host age identity for ${node} (${attempt}/${max_attempts})" >&2
    sleep 1
    attempt=$((attempt + 1))
  done
}

build_wrapped_root_command() {
  local target_cmd="$1" deploy_user="$2" ask_sudo_password="$3"
  local shell_cmd="" sudo_prefix=""

  printf -v shell_cmd 'bash -lc %q' "${target_cmd}"
  if [ "${deploy_user}" = "root" ]; then
    printf '%s\n' "${shell_cmd}"
    return
  fi

  sudo_prefix="sudo -n"
  if [ "${ask_sudo_password}" -eq 1 ]; then
    sudo_prefix="sudo"
  fi

  printf '%s %s\n' "${sudo_prefix}" "${shell_cmd}"
}

run_host_root_command() {
  local node="$1" target_cmd="$2"
  local using_bootstrap_fallback="" deploy_user="" ask_sudo_password=0 tty_mode=0
  local wrapped_cmd=""
  local -a sudo_policy=()

  prepare_deploy_context "${node}" || return 1
  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  mapfile -t sudo_policy < <(
    resolve_target_sudo_policy \
      "${PREP_DEPLOY_LOCAL_EXEC}" \
      "${PREP_DEPLOY_SSH_TARGET}" \
      "${using_bootstrap_fallback}"
  )
  deploy_user="${sudo_policy[0]:-}"
  ask_sudo_password="${sudo_policy[1]:-0}"
  tty_mode="${sudo_policy[2]:-0}"

  wrapped_cmd="$(build_wrapped_root_command "${target_cmd}" "${deploy_user}" "${ask_sudo_password}")"
  run_prepared_deploy_command "${tty_mode}" "${wrapped_cmd}"
}

run_prepared_root_command() {
  local target_cmd="$1"
  local using_bootstrap_fallback="" deploy_user="" ask_sudo_password=0 tty_mode=0
  local wrapped_cmd=""
  local -a sudo_policy=()

  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  mapfile -t sudo_policy < <(
    resolve_target_sudo_policy \
      "${PREP_DEPLOY_LOCAL_EXEC}" \
      "${PREP_DEPLOY_SSH_TARGET}" \
      "${using_bootstrap_fallback}"
  )
  deploy_user="${sudo_policy[0]:-}"
  ask_sudo_password="${sudo_policy[1]:-0}"
  tty_mode="${sudo_policy[2]:-0}"

  wrapped_cmd="$(build_wrapped_root_command "${target_cmd}" "${deploy_user}" "${ask_sudo_password}")"
  run_prepared_deploy_command "${tty_mode}" "${wrapped_cmd}"
}

run_named_prepared_root_command() {
  local phase_name="$1" parent="$2" resources="$3" target_cmd="$4"
  local rc=0

  if retry_transport_command \
    "Parent readiness ${phase_name} on ${parent}" \
    refresh_prepared_primary_target \
    run_prepared_root_command \
    "${target_cmd}"; then
    return 0
  fi
  rc="$?"

  echo "Parent readiness ${phase_name} failed on ${parent} for ${resources}" >&2
  return "${rc}"
}

build_parent_resource_args() {
  local resource="" resource_args=""

  for resource in "$@"; do
    [ -n "${resource}" ] || continue
    printf -v resource_args '%s --machine %q' "${resource_args}" "${resource}"
  done

  printf '%s\n' "${resource_args}"
}

render_parent_command_template() {
  local template="$1" resource_args="$2" resource_label="${3:-}"
  local rendered="" resource_quoted=""

  printf -v resource_quoted '%q' "${resource_label}"
  rendered="${template//\{resource\}/${resource_quoted}}"
  rendered="${rendered//\{resourceArgs\}/${resource_args}}"
  rendered="${rendered//\{timeout\}/${NIXBOT_PARENT_SETTLE_TIMEOUT}}"
  printf '%s\n' "${rendered}"
}

validate_rendered_parent_command() {
  local rendered="$1"

  case "${rendered}" in
    *"{resource}"*|*"{resourceArgs}"*|*"{timeout}"*)
      echo "Parent readiness command still contains unresolved placeholders: ${rendered}" >&2
      return 1
      ;;
  esac
}

parent_template_supports_batching() {
  local template="$1"

  [[ "${template}" == *"{resourceArgs}"* ]] && [[ "${template}" != *"{resource}"* ]]
}

ensure_deploy_wave_parent_readiness() {
  local node="" parent="" resource="" reconcile_template="" settle_template=""
  local group_key="" reconcile_cmd="" settle_cmd="" rendered_resource_args="" resource_args=""
  local -a group_order=() resources=()
  declare -A grouped_resources=() grouped_parents=() grouped_reconcile_templates=() grouped_settle_templates=()

  [ "$#" -gt 0 ] || return 0

  for node in "$@"; do
    [ -n "${node}" ] || continue
    parent="$(host_parent_for "${node}")"
    [ -n "${parent}" ] || continue
    resource="$(host_parent_resource_for "${node}")"
    [ -n "${resource}" ] || continue
    reconcile_template="$(host_parent_reconcile_template_for "${node}")"
    settle_template="$(host_parent_settle_template_for "${node}")"
    group_key="${parent}"$'\t'"${reconcile_template}"$'\t'"${settle_template}"

    if [ -z "${grouped_resources["${group_key}"]+x}" ]; then
      group_order+=("${group_key}")
      grouped_resources["${group_key}"]=""
      grouped_parents["${group_key}"]="${parent}"
      grouped_reconcile_templates["${group_key}"]="${reconcile_template}"
      grouped_settle_templates["${group_key}"]="${settle_template}"
    fi

    case " ${grouped_resources["${group_key}"]} " in
      *" ${resource} "*) ;;
      *)
        grouped_resources["${group_key}"]+="${grouped_resources["${group_key}"]:+ }${resource}"
        ;;
    esac
  done

  for group_key in "${group_order[@]}"; do
    IFS=' ' read -r -a resources <<<"${grouped_resources["${group_key}"]}"
    [ "${#resources[@]}" -gt 0 ] || continue

    rendered_resource_args=""
    for resource in "${resources[@]}"; do
      [ -n "${resource}" ] || continue
      rendered_resource_args+="${rendered_resource_args:+, }${resource}"
    done

    log_subsection "Parent Readiness: ${grouped_parents["${group_key}"]} -> ${rendered_resource_args}"
    prepare_deploy_context "${grouped_parents["${group_key}"]}" || return 1
    if parent_template_supports_batching "${grouped_reconcile_templates["${group_key}"]}" \
      && parent_template_supports_batching "${grouped_settle_templates["${group_key}"]}"; then
      resource_args="$(build_parent_resource_args "${resources[@]}")"
      reconcile_cmd="$(
        render_parent_command_template \
          "${grouped_reconcile_templates["${group_key}"]}" \
          "${resource_args}" \
          "${resources[0]}"
      )"
      validate_rendered_parent_command "${reconcile_cmd}" || return 1
      settle_cmd="$(
        render_parent_command_template \
          "${grouped_settle_templates["${group_key}"]}" \
        "${resource_args}" \
        "${resources[0]}"
      )"
      validate_rendered_parent_command "${settle_cmd}" || return 1
      run_named_prepared_root_command \
        "reconcile" \
        "${grouped_parents["${group_key}"]}" \
        "${rendered_resource_args}" \
        "${reconcile_cmd}" || return 1
      run_named_prepared_root_command \
        "settle" \
        "${grouped_parents["${group_key}"]}" \
        "${rendered_resource_args}" \
        "${settle_cmd}" || return 1
      continue
    fi

    for resource in "${resources[@]}"; do
      [ -n "${resource}" ] || continue
      resource_args="$(build_parent_resource_args "${resource}")"
      reconcile_cmd="$(
        render_parent_command_template \
          "${grouped_reconcile_templates["${group_key}"]}" \
          "${resource_args}" \
          "${resource}"
      )"
      validate_rendered_parent_command "${reconcile_cmd}" || return 1
      settle_cmd="$(
        render_parent_command_template \
          "${grouped_settle_templates["${group_key}"]}" \
          "${resource_args}" \
          "${resource}"
      )"
      validate_rendered_parent_command "${settle_cmd}" || return 1
      run_named_prepared_root_command \
        "reconcile" \
        "${grouped_parents["${group_key}"]}" \
        "${resource}" \
        "${reconcile_cmd}" || return 1
      run_named_prepared_root_command \
        "settle" \
        "${grouped_parents["${group_key}"]}" \
        "${resource}" \
        "${settle_cmd}" || return 1
    done
  done
}

read_prepared_current_system_path() {
  run_prepared_deploy_command_with_retry \
    0 \
    "Current system read for ${PREP_DEPLOY_NODE:-target}" \
    "readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true"
}

##### Host Phases #####

snapshot_host_generation() {
  local node="$1" snapshot_file="$2" remote_current_path=""

  log_host_stage "snapshot" "${node}"
  prepare_deploy_context "${node}" || return 1
  if ! remote_current_path="$(read_prepared_current_system_path)"; then
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

  local node=""

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
  local -n wfjs_active_jobs_inout_ref="$1"
  local max_jobs="$2" wait_rc=0

  if [ "${wfjs_active_jobs_inout_ref}" -ge "${max_jobs}" ]; then
    if wait -n; then
      :
    else
      wait_rc="$?"
      if is_signal_exit_status "${wait_rc}"; then
        return "${wait_rc}"
      fi
    fi
    wfjs_active_jobs_inout_ref=$((wfjs_active_jobs_inout_ref - 1))
  fi
}

drain_job_slots() {
  local -n djs_active_jobs_inout_ref="$1"
  local wait_rc=0

  while [ "${djs_active_jobs_inout_ref}" -gt 0 ]; do
    if wait -n; then
      :
    else
      wait_rc="$?"
      if is_signal_exit_status "${wait_rc}"; then
        return "${wait_rc}"
      fi
    fi
    djs_active_jobs_inout_ref=$((djs_active_jobs_inout_ref - 1))
  done
}

run_streamed_host_command() {
  local node="$1" log_file="${2:-}"
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
  local node="$1" out_file="$2" status_file="$3" log_file="${4:-}" built_out_path="" rc=""

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
  local node="$1" status_file="$2"
  local -n rps_success_hosts_out_ref="$3" rps_failed_hosts_out_ref="$4"
  local rc=""

  if ! rc="$(read_status_file "${status_file}")"; then
    rps_failed_hosts_out_ref+=("${node}")
    return 1
  fi
  if [ "${rc}" != "0" ]; then
    rps_failed_hosts_out_ref+=("${node}")
    if is_signal_exit_status "${rc}"; then
      return "${rc}"
    fi
    return 1
  fi

  rps_success_hosts_out_ref+=("${node}")
  return 0
}

resolve_deploy_phase_result() {
  local node="$1" status_file="$2"
  local result_kind="" status=""

  result_kind=""
  status=""

  if ! status="$(read_status_file "${status_file}")"; then
    result_kind="fail"
    printf '%s\n%s\n' "${result_kind}" "${status}"
    return 0
  fi

  case "${status}" in
    0)
      result_kind="success"
      ;;
    skip)
      result_kind="skip"
      ;;
    *)
      if is_signal_exit_status "${status}"; then
        result_kind="signal"
      elif host_optional_deploy_enabled "${node}"; then
        result_kind="optional-fail"
      else
        result_kind="fail"
      fi
      ;;
  esac

  printf '%s\n%s\n' "${result_kind}" "${status}"
}

process_completed_deploy_job() {
  local node="$1" status_file="$2" snapshot_dir="$3" rollback_log_dir="$4" rollback_status_dir="$5"
  # shellcheck disable=SC2178
  local -n pcdj_success_hosts_out_ref="$6" pcdj_skipped_hosts_out_ref="$7"
  # shellcheck disable=SC2178
  local -n pcdj_failed_hosts_out_ref="$8"
  local result_kind="" status=""

  {
    read -r result_kind
    read -r status
  } < <(resolve_deploy_phase_result "${node}" "${status_file}")

  case "${result_kind}" in
    success)
      pcdj_success_hosts_out_ref+=("${node}")
      return 0
      ;;
    skip)
      pcdj_skipped_hosts_out_ref+=("${node}")
      return 0
      ;;
    optional-fail)
      rollback_optional_deploy_host "${node}" "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}"
      return 0
      ;;
    signal)
      return "${status}"
      ;;
    fail)
      pcdj_failed_hosts_out_ref+=("${node}")
      return 1
      ;;
    *)
      die "Unsupported deploy phase result for ${node}: ${result_kind}"
      ;;
  esac
}

append_unique_array_item() {
  # shellcheck disable=SC2178
  local -n auai_array_out_ref="$1"
  local item="$2"

  array_contains "${item}" "${auai_array_out_ref[@]}" || auai_array_out_ref+=("${item}")
}

collect_completed_deploy_wave_statuses() {
  local deploy_status_dir="$1"
  # shellcheck disable=SC2178,SC2034
  local -n ccdws_success_hosts_out_ref="$2"
  # shellcheck disable=SC2178,SC2034
  local -n ccdws_skipped_hosts_out_ref="$3"
  # shellcheck disable=SC2178,SC2034
  local -n ccdws_failed_hosts_out_ref="$4"
  shift 4

  local node="" status_file="" status=""

  for node in "$@"; do
    [ -n "${node}" ] || continue
    status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
    if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
      continue
    fi
    case "${status}" in
      0)
        append_unique_array_item ccdws_success_hosts_out_ref "${node}"
        ;;
      skip)
        append_unique_array_item ccdws_skipped_hosts_out_ref "${node}"
        ;;
      *)
        append_unique_array_item ccdws_failed_hosts_out_ref "${node}"
        ;;
    esac
  done
}

handle_deploy_interrupt() {
  local interrupt_rc="$1" snapshot_dir="$2" deploy_status_dir="$3"
  local rollback_log_dir="$4" rollback_status_dir="$5"
  local success_hosts_out_name="$6" skipped_hosts_out_name="$7" failed_hosts_out_name="$8"
  # shellcheck disable=SC2178
  local -n hdi_success_hosts_out_ref="${success_hosts_out_name}"
  shift 8

  terminate_background_jobs
  # Forward the original target names, not this helper's local nameref aliases.
  collect_completed_deploy_wave_statuses \
    "${deploy_status_dir}" \
    "${success_hosts_out_name}" \
    "${skipped_hosts_out_name}" \
    "${failed_hosts_out_name}" \
    "$@"
  maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${hdi_success_hosts_out_ref[@]}"
  return "${interrupt_rc}"
}

abort_deploy_on_signal() {
  local phase_rc="$1" snapshot_dir="$2" deploy_status_dir="$3"
  local rollback_log_dir="$4" rollback_status_dir="$5"
  local success_hosts_out_name="$6" skipped_hosts_out_name="$7" failed_hosts_out_name="$8"
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
    "${success_hosts_out_name}" \
    "${skipped_hosts_out_name}" \
    "${failed_hosts_out_name}" \
    "$@"
}

log_snapshot_retry_transition() {
  local snapshot_dir="$1" level_index="$2"
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
  local node="$1" out_file="$2" status_file="$3" log_file="${4:-}" built_out_path="" rc="" skip_marker=""

  wait_before_host_phase "${node}" "deploy"

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
  local heading="$1" mode="${2:-plain}" log_dir="${3:-}" status_dir=""

  if [ "${mode}" = "build" ]; then
    status_dir="${4:-}"
    shift 4
  else
    shift 3
  fi

  local -a failed_hosts=("$@")
  local node="" status_file="" log_file="" rc=""

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
  local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
  shift 3

  local -a successful_hosts=("$@")

  if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
    rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts[@]}" || true
  fi
}

resolve_snapshot_wave_host_result() {
  local snapshot_dir="$1" node="$2"
  local result_kind="ok"

  if ! snapshot_exists "${snapshot_dir}/${node}.path"; then
    if host_optional_deploy_enabled "${node}"; then
      result_kind="optional-missing"
    else
      result_kind="fatal-missing"
    fi
  fi

  printf '%s\n' "${result_kind}"
}

process_snapshot_wave_results() {
  local snapshot_dir="$1"
  local -n pswr_snapshot_failed_hosts_out_ref="$2"
  # shellcheck disable=SC2178
  local -n pswr_deploy_failed_hosts_out_ref="$3"
  # shellcheck disable=SC2178,SC2034
  local -n pswr_deploy_skipped_hosts_out_ref="$4"
  shift 4

  local node="" result_kind="" fatal_failure=0

  for node in "$@"; do
    [ -n "${node}" ] || continue
    result_kind="$(resolve_snapshot_wave_host_result "${snapshot_dir}" "${node}")"
    case "${result_kind}" in
      ok)
        ;;
      optional-missing)
        echo "Unable to record pre-deploy generation for optional host ${node}; skipping deploy" >&2
        append_unique_array_item OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS "${node}"
        append_unique_array_item pswr_deploy_skipped_hosts_out_ref "${node}"
        ;;
      fatal-missing)
        pswr_snapshot_failed_hosts_out_ref+=("${node}")
        pswr_deploy_failed_hosts_out_ref+=("${node}")
        fatal_failure=1
        ;;
      *)
        die "Unsupported snapshot wave result for ${node}: ${result_kind}"
        ;;
    esac
  done

  [ "${fatal_failure}" -eq 0 ]
}

snapshot_host_with_retry() {
  local node="$1" snapshot_file="$2"
  local parent_host="" ready_timeout=0 ready_interval_secs=0 max_attempts=0 attempt=0

  [ "${DRY_RUN}" -eq 0 ] || return 0
  [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 0

  if snapshot_exists "${snapshot_file}"; then
    return 0
  fi

  wait_before_host_phase "${node}" "snapshot"
  parent_host="$(host_parent_for "${node}")"
  if [ -z "${parent_host}" ]; then
    snapshot_host_generation "${node}" "${snapshot_file}"
    return "$?"
  fi

  ready_timeout="${NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT}"
  ready_interval_secs="${NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS}"
  if [ "${ready_interval_secs}" -lt 1 ]; then
    ready_interval_secs=1
  fi
  max_attempts=$((((ready_timeout - 1) / ready_interval_secs) + 1))
  attempt=1

  while ! snapshot_host_generation "${node}" "${snapshot_file}"; do
    if [ "${attempt}" -ge "${max_attempts}" ]; then
      return 1
    fi

    echo "[${node}] snapshot | attempt ${attempt}/${max_attempts} failed after parent barrier (${parent_host}); retrying in ${ready_interval_secs}s" >&2
    sleep "${ready_interval_secs}"
    attempt=$((attempt + 1))
  done

  return 0
}

run_snapshot_job() {
  local node="$1" snapshot_file="$2" status_file="${3:-}" log_file="${4:-}" rc=0

  (
    set +e
    if [ -n "${status_file}" ]; then
      rm -f "${status_file}"
    fi
    if [ -n "${log_file}" ]; then
      run_streamed_host_command "${node}" "${log_file}" snapshot_host_with_retry "${node}" "${snapshot_file}"
      rc="$?"
    else
      snapshot_host_with_retry "${node}" "${snapshot_file}"
      rc="$?"
    fi
    log_group_end_host_stage "snapshot"
    if [ -n "${status_file}" ]; then
      write_status_file "${status_file}" "${rc}"
    fi
    exit "${rc}"
  )
}

run_initial_snapshot_wave() {
  local level_group="$1" snapshot_dir="$2" snapshot_log_dir="$3" snapshot_status_dir="$4"
  local snapshot_parallel="${5:-0}" snapshot_parallel_jobs="${6:-1}"
  local -a level_hosts=()
  local node="" active_jobs=0 status_file="" log_file="" status=""

  [ -n "${level_group}" ] || return 0

  mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
  log_subsection "Snapshot Wave 0: $(join_by_comma "${level_hosts[@]}")"
  for node in "${level_hosts[@]}"; do
    [ -n "${node}" ] || continue
    if [ "${snapshot_parallel}" -eq 1 ]; then
      status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
      log_file="$(phase_dir_item_log_file "${snapshot_log_dir}" "${node}")"
      run_snapshot_job "${node}" "${snapshot_dir}/${node}.path" "${status_file}" "${log_file}" &
      active_jobs=$((active_jobs + 1))
      wait_for_job_slot active_jobs "${snapshot_parallel_jobs}" || return "$?"
      continue
    fi

    if ! run_snapshot_job "${node}" "${snapshot_dir}/${node}.path"; then
      echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
    fi
  done

  if [ "${snapshot_parallel}" -eq 1 ]; then
    drain_job_slots active_jobs || return "$?"
    for node in "${level_hosts[@]}"; do
      [ -n "${node}" ] || continue
      status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
      if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
        echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
        continue
      fi
      if [ "${status}" != "0" ]; then
        echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
      fi
    done
  fi
}

ensure_wave_snapshots() {
  local snapshot_dir="$1" snapshot_log_dir="$2" snapshot_status_dir="$3"
  local snapshot_parallel="${4:-0}" snapshot_parallel_jobs="${5:-1}"
  shift 5

  local node="" snapshot_file="" rc=0 active_jobs=0 status_file="" log_file="" status=""

  [ "${DRY_RUN}" -eq 0 ] || return 0
  [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 0
  [ "$#" -gt 0 ] || return 0

  for node in "$@"; do
    [ -n "${node}" ] || continue
    snapshot_file="${snapshot_dir}/${node}.path"
    if snapshot_exists "${snapshot_file}"; then
      continue
    fi

    if [ "${snapshot_parallel}" -eq 1 ]; then
      status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
      log_file="$(phase_dir_item_log_file "${snapshot_log_dir}" "${node}")"
      run_snapshot_job "${node}" "${snapshot_file}" "${status_file}" "${log_file}" &
      active_jobs=$((active_jobs + 1))
      wait_for_job_slot active_jobs "${snapshot_parallel_jobs}" || return "$?"
      continue
    fi

    if ! run_snapshot_job "${node}" "${snapshot_file}"; then
      echo "Unable to record pre-deploy generation for ${node}; refusing deploy without rollback snapshot" >&2
      rc=1
    fi
  done

  if [ "${snapshot_parallel}" -eq 1 ]; then
    drain_job_slots active_jobs || return "$?"
    for node in "$@"; do
      [ -n "${node}" ] || continue
      snapshot_file="${snapshot_dir}/${node}.path"
      if snapshot_exists "${snapshot_file}"; then
        continue
      fi
      status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
      if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
        echo "Unable to record pre-deploy generation for ${node}; refusing deploy without rollback snapshot" >&2
        rc=1
        continue
      fi
      if [ "${status}" != "0" ]; then
        echo "Unable to record pre-deploy generation for ${node}; refusing deploy without rollback snapshot" >&2
        rc=1
      fi
    done
  fi

  return "${rc}"
}

rollback_host_to_snapshot() {
  local node="$1" snapshot_path="$2" rollback_cmd="" deploy_user=""
  local using_bootstrap_fallback="" sudo_tty_mode=0
  local rollback_rc=0
  local -a sudo_policy=()

  [ -n "${snapshot_path}" ] || {
    echo "Rollback snapshot is empty for ${node}" >&2
    return 1
  }

  log_host_stage "rollback" "${node}"
  prepare_deploy_context "${node}" || return 1
  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  mapfile -t sudo_policy < <(
    resolve_target_sudo_policy \
      "${PREP_DEPLOY_LOCAL_EXEC}" \
      "${PREP_DEPLOY_SSH_TARGET}" \
      "${using_bootstrap_fallback}"
  )
  deploy_user="${sudo_policy[0]:-}"
  sudo_tty_mode="${sudo_policy[2]:-0}"

  # shellcheck disable=SC2016
  rollback_cmd='set -euo pipefail; snap="'"${snapshot_path}"'"; if [ ! -x "${snap}/bin/switch-to-configuration" ]; then echo "snapshot is not activatable: ${snap}" >&2; exit 1; fi; if [ "$(id -u)" -eq 0 ]; then "${snap}/bin/switch-to-configuration" switch; elif command -v sudo >/dev/null 2>&1; then sudo "${snap}/bin/switch-to-configuration" switch; else echo "sudo is required for rollback as non-root user" >&2; exit 1; fi'

  echo "${snapshot_path}" >&2
  [ -n "${deploy_user}" ] || die "Unable to resolve deploy user for rollback target ${node}"
  if run_prepared_deploy_command "${sudo_tty_mode}" "${rollback_cmd}"; then
    return 0
  fi
  rollback_rc="$?"

  echo "==> Rollback transport closed or failed for ${node}; verifying target state" >&2
  if verify_rollback_target_state "${node}" "${snapshot_path}"; then
    echo "==> Rollback for ${node} completed despite transport disconnect" >&2
    return 0
  fi

  return "${rollback_rc}"
}

verify_rollback_target_state() {
  local node="$1" snapshot_path="$2" remote_current_path="" attempt="" max_attempts=15

  for ((attempt=1; attempt<=max_attempts; attempt++)); do
    sleep 2

    if ! prepare_deploy_context "${node}" primary-only >/dev/null 2>&1; then
      continue
    fi

    remote_current_path="$(read_prepared_current_system_path 2>/dev/null || true)"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${snapshot_path}" ]; then
      return 0
    fi
  done

  return 1
}

rollback_successful_hosts() {
  local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
  shift 3

  local -a successful_hosts=("$@")
  local node="" status_file="" log_file="" rc="" rollback_rc=0
  ROLLBACK_OK_HOSTS=()
  ROLLBACK_FAILED_HOSTS=()

  [ "${#successful_hosts[@]}" -gt 0 ] || return 0

  # Reverse the host order so rollback undoes deploys in the opposite sequence.
  # This ensures containers are rolled back before the hosts they run on.
  local -a reversed_hosts=()
  local i
  for (( i=${#successful_hosts[@]}-1; i>=0; i-- )); do
    reversed_hosts+=("${successful_hosts[i]}")
  done
  successful_hosts=("${reversed_hosts[@]}")

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

rollback_optional_deploy_host() {
  local node="$1" snapshot_dir="$2" rollback_log_dir="$3" rollback_status_dir="$4"
  local status_file="" log_file="" snapshot_path="" rc=""

  status_file="$(phase_dir_item_status_file "${rollback_status_dir}" "${node}")"
  log_file="$(phase_dir_item_log_file "${rollback_log_dir}" "${node}")"
  snapshot_path="${snapshot_dir}/${node}.path"

  echo "Optional deploy failed for ${node}; attempting host-only rollback" >&2
  if ! snapshot_exists "${snapshot_path}"; then
    echo "Optional deploy rollback unavailable for ${node}: no rollback snapshot recorded" >&2
    write_status_file "${status_file}" "snapshot-missing"
    append_unique_array_item OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS "${node}"
    return 0
  fi

  if run_streamed_host_command "${node}" "${log_file}" rollback_host_to_snapshot "${node}" "$(cat "${snapshot_path}")"; then
    write_status_file "${status_file}" 0
    append_unique_array_item OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS "${node}"
  else
    rc="$?"
    write_status_file "${status_file}" "${rc}"
    append_unique_array_item OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS "${node}"
  fi

  return 0
}

deploy_host() {
  local node="$1" built_out_path="$2" skip_marker="${3:-}"
  local remote_current_path="" nix_sshopts=""
  local using_bootstrap_fallback="" age_identity_key="" build_host=""
  local ask_sudo_password=0
  local -a rebuild_cmd=() sudo_policy=() age_identity_inject_args=()

  log_host_stage "deploy" "${node}" "${GOAL}"
  prepare_deploy_context "${node}" || return 1
  nix_sshopts="${PREP_DEPLOY_NIX_SSHOPTS}"
  using_bootstrap_fallback="${PREP_USING_BOOTSTRAP_FALLBACK}"
  age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"
  age_identity_inject_args=(
    "${node}"
    "${PREP_DEPLOY_LOCAL_EXEC}"
    "${PREP_DEPLOY_SSH_TARGET}"
    "${age_identity_key}"
    "${PREP_USING_BOOTSTRAP_FALLBACK}"
    0
    "${PREP_DEPLOY_SSH_OPTS[@]}"
  )

  if [ "${NIXBOT_IF_CHANGED}" -eq 1 ]; then
    remote_current_path="$(read_prepared_current_system_path)"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "[${node}] deploy | skip" >&2
      echo "${built_out_path}" >&2
      if [ -n "${skip_marker}" ]; then
        : > "${skip_marker}"
      fi
      return 0
    fi
  fi

  inject_host_age_identity_key \
    "${age_identity_inject_args[@]}" || return 1
  mapfile -t sudo_policy < <(
    resolve_target_sudo_policy \
      "${PREP_DEPLOY_LOCAL_EXEC}" \
      "${PREP_DEPLOY_SSH_TARGET}" \
      "${using_bootstrap_fallback}"
  )
  ask_sudo_password="${sudo_policy[1]:-0}"

  case "${BUILD_HOST}" in
    local)
      if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 0 ] && { [ "${using_bootstrap_fallback}" -eq 1 ] || { [ -n "${NIXBOT_USER_OVERRIDE}" ] && [ "${PREP_DEPLOY_SSH_TARGET%%@*}" != "root" ]; }; }; then
        build_host="${PREP_DEPLOY_SSH_TARGET}"
      fi
      ;;
    target)
      if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 0 ]; then
        build_host="${PREP_DEPLOY_SSH_TARGET}"
      fi
      ;;
    *)
      build_host="${BUILD_HOST}"
      ;;
  esac

  rebuild_cmd=(
    nixos-rebuild-ng
    --flake "path:.#${node}"
    --sudo
  )

  if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 0 ]; then
    rebuild_cmd+=(--target-host "${PREP_DEPLOY_SSH_TARGET}")
  fi

  if [ "${ask_sudo_password}" -eq 1 ]; then
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

  # The first injection happens before deploy setup so bootstrap state exists
  # for any intermediate target operations. Re-check immediately before
  # activation because first-switch Incus guests can lose /var/lib/nixbot/.age
  # state between the initial probe and agenix decrypt.
  inject_host_age_identity_key \
    "${node}" \
    "${PREP_DEPLOY_LOCAL_EXEC}" \
    "${PREP_DEPLOY_SSH_TARGET}" \
    "${age_identity_key}" \
    "${PREP_USING_BOOTSTRAP_FALLBACK}" \
    1 \
    "${PREP_DEPLOY_SSH_OPTS[@]}" || return 1
  wait_for_prepared_host_age_identity_activation_visibility "${node}" "${age_identity_key}" || return 1

  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '%q ' "${rebuild_cmd[@]}"
    echo
  else
    "${rebuild_cmd[@]}"
  fi
}

run_bootstrap_key_checks() {
  local selected_json="$1"
  local -n rbkc_bootstrap_ok_hosts_out_ref="$2" rbkc_bootstrap_failed_hosts_out_ref="$3"
  local node="" target_info="" bootstrap_key="" bootstrap_key_file="" fpr="" rc=0
  local -a selected_hosts=()

  rbkc_bootstrap_ok_hosts_out_ref=()
  rbkc_bootstrap_failed_hosts_out_ref=()

  json_array_to_bash_array "${selected_json}" selected_hosts

  log_section "Phase: Bootstrap Key Check"
  ensure_tmp_dir
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue

    target_info="$(resolve_deploy_target "${node}")"
    bootstrap_key="$(jq -r '.bootstrapKey // empty' <<<"${target_info}")"

    if [ -z "${bootstrap_key}" ]; then
      echo "==> ${node}: no bootstrapKey configured"
      rbkc_bootstrap_ok_hosts_out_ref+=("${node}")
      continue
    fi

    if ! bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key}")"; then
      rc=1
      rbkc_bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "==> ${node}: bootstrap key missing: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      rbkc_bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi

    fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2 || true)"
    if [ -z "${fpr}" ]; then
      echo "==> ${node}: bootstrap key unreadable: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      rbkc_bootstrap_failed_hosts_out_ref+=("${node}")
      continue
    fi

    echo "==> ${node}: bootstrap key OK (${fpr})"
    rbkc_bootstrap_ok_hosts_out_ref+=("${node}")
  done

  return "${rc}"
}

##### Host Phase Artifacts #####

init_run_dirs() {
  local base_dir="$1"
  local -n ird_build_log_dir_out_ref="$2" ird_build_status_dir_out_ref="$3"
  local -n ird_snapshot_log_dir_out_ref="$4" ird_snapshot_status_dir_out_ref="$5"
  local -n ird_deploy_log_dir_out_ref="$6" ird_deploy_status_dir_out_ref="$7"
  local -n ird_build_out_dir_out_ref="$8" ird_snapshot_dir_out_ref="$9"
  local -n ird_rollback_log_dir_out_ref="${10}" ird_rollback_status_dir_out_ref="${11}"

  # shellcheck disable=SC2034
  {
    ird_build_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "build")"
    ird_build_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "build")"
    ird_snapshot_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "snapshot")"
    ird_snapshot_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "snapshot")"
    ird_deploy_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "deploy")"
    ird_deploy_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "deploy")"
    ird_build_out_dir_out_ref="${base_dir}/build-outs"
    ird_snapshot_dir_out_ref="${base_dir}/snapshots"
    ird_rollback_log_dir_out_ref="$(phase_log_dir_path "${base_dir}" "rollback")"
    ird_rollback_status_dir_out_ref="$(phase_status_dir_path "${base_dir}" "rollback")"
  }

  ensure_phase_runtime_dirs "${base_dir}" build snapshot deploy rollback
  mkdir -p "${ird_build_out_dir_out_ref}" "${ird_snapshot_dir_out_ref}"
}

phase_dir_path() {
  local base_dir="$1" kind="$2" phase="$3"

  printf '%s/%s.%s\n' "${base_dir}" "${kind}" "${phase}"
}

phase_log_dir_path() {
  phase_dir_path "$1" "logs" "$2"
}

phase_status_dir_path() {
  phase_dir_path "$1" "status" "$2"
}

phase_item_name() {
  local phase="$1" item="$2" subitem="${3:-}"

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
  local base_dir="$1" phase="$2" item="$3" subitem="${4:-}"

  printf '%s/%s.log\n' "$(phase_log_dir_path "${base_dir}" "${phase}")" "$(phase_item_name "${phase}" "${item}" "${subitem}")"
}

phase_item_status_file() {
  local base_dir="$1" phase="$2" item="$3" subitem="${4:-}"

  printf '%s/%s.rc\n' "$(phase_status_dir_path "${base_dir}" "${phase}")" "$(phase_item_name "${phase}" "${item}" "${subitem}")"
}

phase_dir_item_log_file() {
  local log_dir="$1" item="$2"

  printf '%s/%s.log\n' "${log_dir}" "${item}"
}

phase_dir_item_status_file() {
  local status_dir="$1" item="$2"

  printf '%s/%s.rc\n' "${status_dir}" "${item}"
}

write_status_file() {
  local status_file="$1" rc="$2"

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
  local base_dir="$1" phase="$2"

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
  local node="$1" out_path=""

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
  local node="$1" out_path=""

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
  local build_jobs="$1" build_parallel="$2" prioritize_bastion="$3" bastion_host="$4"
  local build_log_dir="$5" build_status_dir="$6" build_out_dir="$7" built_hosts_out_name="$9"
  local -n rbp_build_hosts_in_ref="$8"
  # shellcheck disable=SC2178
  local -n rbp_failed_hosts_out_ref="${10}"

  local node="" active_jobs=0 status_file="" out_file="" log_file=""
  local build_sync_leading_bastion=0 host_grouping=0 phase_rc=0

  if [ "${build_parallel}" -eq 0 ] && [ "${#rbp_build_hosts_in_ref[@]}" -gt 1 ]; then
    host_grouping=1
    log_grouped_phase_section "Phase: Build" "build" 1
  else
    log_grouped_phase_section "Phase: Build" "build" 0
  fi

  if [ "${build_parallel}" -eq 1 ] && [ "${prioritize_bastion}" -eq 1 ] \
    && [ "${#rbp_build_hosts_in_ref[@]}" -gt 0 ] && [ "${rbp_build_hosts_in_ref[0]}" = "${bastion_host}" ]; then
    build_sync_leading_bastion=1
    node="${bastion_host}"
    status_file="$(phase_dir_item_status_file "${build_status_dir}" "${node}")"
    out_file="${build_out_dir}/${node}.path"
    run_build_job "${node}" "${out_file}" "${status_file}"
    if record_phase_status "${node}" "${status_file}" "${built_hosts_out_name}" "${10}"; then
      :
    else
      phase_rc="$?"
      if is_signal_exit_status "${phase_rc}"; then
        log_group_scope_end
        return "${phase_rc}"
      fi
    fi
  fi

  for node in "${rbp_build_hosts_in_ref[@]}"; do
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
      if wait_for_job_slot active_jobs "${build_jobs}"; then
        :
      else
        phase_rc="$?"
        log_group_scope_end
        return "${phase_rc}"
      fi
      continue
    fi

    run_build_job "${node}" "${out_file}" "${status_file}"
    if record_phase_status "${node}" "${status_file}" "${built_hosts_out_name}" "${10}"; then
      :
    else
      phase_rc="$?"
      if is_signal_exit_status "${phase_rc}"; then
        log_group_scope_end
        return "${phase_rc}"
      fi
      break
    fi
  done

  if [ "${build_parallel}" -eq 1 ]; then
    if drain_job_slots active_jobs; then
      :
    else
      phase_rc="$?"
      log_group_scope_end
      return "${phase_rc}"
    fi
    for node in "${rbp_build_hosts_in_ref[@]}"; do
      [ -n "${node}" ] || continue
      status_file="$(phase_dir_item_status_file "${build_status_dir}" "${node}")"
      if [ "${build_sync_leading_bastion}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
        continue
      fi
      if record_phase_status "${node}" "${status_file}" "${built_hosts_out_name}" "${10}"; then
        :
      else
        phase_rc="$?"
        if is_signal_exit_status "${phase_rc}"; then
          log_group_scope_end
          return "${phase_rc}"
        fi
      fi
    done
  fi

  if [ "${#rbp_failed_hosts_out_ref[@]}" -gt 0 ]; then
    print_host_failures "Build phase failed" build "${build_log_dir}" "${build_status_dir}" "${rbp_failed_hosts_out_ref[@]}"
    log_group_scope_end
    return 1
  fi

  log_group_scope_end
  return 0
}

##### Deploy Phase #####

run_deploy_phase() {
  local deploy_parallel="$1" deploy_parallel_jobs="$2" snapshot_dir="$3"
  local snapshot_log_dir="$4" snapshot_status_dir="$5"
  local deploy_log_dir="$6" deploy_status_dir="$7" build_out_dir="$8"
  local rollback_log_dir="$9" rollback_status_dir="${10}"
  local deploy_skipped_hosts_out_name="${13}" snapshot_failed_hosts_out_name="${14}"
  local -n rdp_level_groups_in_ref="${11}" rdp_successful_hosts_out_ref="${12}"
  # shellcheck disable=SC2178
  local -n rdp_deploy_failed_hosts_out_ref="${15}"

  local level_group="" node="" active_jobs="" level_index=0
  local -a level_hosts=() deploy_level_hosts=()
  local status_file="" out_file="" log_file="" snapshot_retry_logged=0
  local deploy_wave_failed=0 total_deploy_hosts=0 level_group_size=0 host_grouping=0 phase_rc=0
  local wave_deploy_parallel=0 shared_parent=""
  declare -A wave_parent_seen=()

  local _success_hosts_out_name="${12}" _failed_hosts_out_name="${15}"

  # Invoke abort_deploy_on_signal with the fixed context for this deploy phase.
  _try_abort_wave() {
    local rc="$1"
    abort_deploy_on_signal \
      "${rc}" \
      "${snapshot_dir}" \
      "${deploy_status_dir}" \
      "${rollback_log_dir}" \
      "${rollback_status_dir}" \
      "${_success_hosts_out_name}" \
      "${deploy_skipped_hosts_out_name}" \
      "${_failed_hosts_out_name}" \
      "${deploy_level_hosts[@]}"
  }

  for level_group in "${rdp_level_groups_in_ref[@]}"; do
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

  for level_group in "${rdp_level_groups_in_ref[@]}"; do
    mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
    deploy_level_hosts=()
    for node in "${level_hosts[@]}"; do
      [ -n "${node}" ] || continue
      if host_deploy_stage_skipped "${node}"; then
        append_unique_array_item "${deploy_skipped_hosts_out_name}" "${node}"
        continue
      fi
      deploy_level_hosts+=("${node}")
    done
    wave_deploy_parallel="${deploy_parallel}"
    if [ "${wave_deploy_parallel}" -eq 1 ] && [ "${#deploy_level_hosts[@]}" -gt 1 ]; then
      wave_parent_seen=()
      for node in "${deploy_level_hosts[@]}"; do
        [ -n "${node}" ] || continue
        shared_parent="$(host_parent_for "${node}")"
        [ -n "${shared_parent}" ] || continue
        if [ -n "${wave_parent_seen["${shared_parent}"]+x}" ]; then
          wave_deploy_parallel=0
          break
        fi
        wave_parent_seen["${shared_parent}"]=1
      done
    fi
    snapshot_retry_logged=0
    if log_snapshot_retry_transition "${snapshot_dir}" "${level_index}" "${deploy_level_hosts[@]}"; then
      snapshot_retry_logged=1
    fi
    if ! ensure_deploy_wave_parent_readiness "${deploy_level_hosts[@]}"; then
      for node in "${deploy_level_hosts[@]}"; do
        append_unique_array_item "${_failed_hosts_out_name}" "${node}"
      done
      echo "Deploy phase failed while waiting on parent readiness barriers" >&2
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${rdp_successful_hosts_out_ref[@]}"
      log_group_scope_end
      return 1
    fi
    if ! ensure_wave_snapshots \
      "${snapshot_dir}" \
      "${snapshot_log_dir}" \
      "${snapshot_status_dir}" \
      "${deploy_parallel}" \
      "${deploy_parallel_jobs}" \
      "${deploy_level_hosts[@]}"; then
      if ! process_snapshot_wave_results "${snapshot_dir}" "${snapshot_failed_hosts_out_name}" "${_failed_hosts_out_name}" "${deploy_skipped_hosts_out_name}" "${deploy_level_hosts[@]}"; then
        print_host_failures "Deploy phase failed" snapshot "" "${rdp_deploy_failed_hosts_out_ref[@]}"
        maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${rdp_successful_hosts_out_ref[@]}"
        log_group_scope_end
        return 1
      fi
    fi
    if [ "${snapshot_retry_logged}" -eq 1 ]; then
      log_grouped_phase_section "Phase: Deploy" "deploy" "${host_grouping}"
    fi

    log_subsection "Deploy Wave: $(join_by_comma "${deploy_level_hosts[@]}")"
    deploy_wave_failed=0
    active_jobs=0

    for node in "${deploy_level_hosts[@]}"; do
      [ -n "${node}" ] || continue
      if array_contains "${node}" "${OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS[@]}"; then
        continue
      fi

      status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
      out_file="${build_out_dir}/${node}.path"
      log_file=""
      if [ "${wave_deploy_parallel}" -eq 1 ]; then
        log_file="$(phase_dir_item_log_file "${deploy_log_dir}" "${node}")"
        run_deploy_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
        active_jobs=$((active_jobs + 1))
        if wait_for_job_slot active_jobs "${deploy_parallel_jobs}"; then
          :
        else
          phase_rc="$?"
          _try_abort_wave "${phase_rc}"; phase_rc="$?"
          log_group_scope_end
          return "${phase_rc}"
        fi
        continue
      fi

      run_deploy_job "${node}" "${out_file}" "${status_file}"
      if process_completed_deploy_job "${node}" "${status_file}" "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${_success_hosts_out_name}" "${deploy_skipped_hosts_out_name}" "${_failed_hosts_out_name}"; then
        :
      else
        phase_rc="$?"
        _try_abort_wave "${phase_rc}"; phase_rc="$?"
        if is_signal_exit_status "${phase_rc}"; then
          log_group_scope_end
          return "${phase_rc}"
        fi
        deploy_wave_failed=1
        break
      fi
    done

    if [ "${wave_deploy_parallel}" -eq 1 ]; then
      if drain_job_slots active_jobs; then
        :
      else
        phase_rc="$?"
        _try_abort_wave "${phase_rc}"; phase_rc="$?"
        log_group_scope_end
        return "${phase_rc}"
      fi
      for node in "${deploy_level_hosts[@]}"; do
        [ -n "${node}" ] || continue
        if array_contains "${node}" "${OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS[@]}"; then
          continue
        fi
        status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
        if process_completed_deploy_job "${node}" "${status_file}" "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${_success_hosts_out_name}" "${deploy_skipped_hosts_out_name}" "${_failed_hosts_out_name}"; then
          :
        else
          phase_rc="$?"
          _try_abort_wave "${phase_rc}"; phase_rc="$?"
          if is_signal_exit_status "${phase_rc}"; then
            log_group_scope_end
            return "${phase_rc}"
          fi
        fi
      done
      if [ "${#rdp_deploy_failed_hosts_out_ref[@]}" -gt 0 ]; then
        deploy_wave_failed=1
      fi
    fi

    if [ "${deploy_wave_failed}" -eq 1 ]; then
      if [ "${wave_deploy_parallel}" -eq 1 ]; then
        print_host_failures "Deploy phase failed" deploy "${deploy_log_dir}" "${rdp_deploy_failed_hosts_out_ref[@]}"
      else
        print_host_failures "Deploy phase failed" plain "" "${rdp_deploy_failed_hosts_out_ref[@]}"
      fi
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${rdp_successful_hosts_out_ref[@]}"
      log_group_scope_end
      return 1
    fi

    level_index=$((level_index + 1))
  done

  log_group_scope_end
  return 0
}

capture_current_run_summary_state() {
  local action="$1" selected_hosts_name="$2"
  local build_ok_hosts_name="$3" build_failed_hosts_name="$4" snapshot_failed_hosts_name="$5"
  local deploy_ok_hosts_name="$6" deploy_skipped_hosts_name="$7" deploy_failed_hosts_name="$8"

  set_run_summary_host_state \
    "${action}" \
    "${selected_hosts_name}" \
    FULLY_SKIPPED_HOSTS \
    "${build_ok_hosts_name}" \
    "${build_failed_hosts_name}" \
    "${snapshot_failed_hosts_name}" \
    "${deploy_ok_hosts_name}" \
    "${deploy_skipped_hosts_name}" \
    "${deploy_failed_hosts_name}" \
    OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS \
    OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS \
    OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS \
    ROLLBACK_OK_HOSTS \
    ROLLBACK_FAILED_HOSTS
}

run_hosts() {
  local selected_json="$1" runnable_selected_json="" bastion_host="${BASTION_TRIGGER_HOST}"
  # shellcheck disable=SC2034
  local -a selected_hosts=() failed_hosts=() successful_hosts=() built_hosts=()
  # shellcheck disable=SC2034
  local -a snapshot_failed_hosts=() deploy_skipped_hosts=() deploy_failed_hosts=()
  # shellcheck disable=SC2034
  local -a build_hosts=() level_groups=() bootstrap_ok_hosts=() bootstrap_failed_hosts=()

  local build_log_dir="" build_status_dir="" snapshot_log_dir="" snapshot_status_dir=""
  local deploy_log_dir="" deploy_status_dir="" build_out_dir="" snapshot_dir=""
  local rollback_log_dir="" rollback_status_dir=""
  local levels_json="" final_rc=0 build_parallel=0 deploy_parallel=0 snapshot_parallel=0

  FULLY_SKIPPED_HOSTS=()
  # shellcheck disable=SC2034
  OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=()
  # shellcheck disable=SC2034
  OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
  # shellcheck disable=SC2034
  OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=()
  runnable_selected_json="$(filter_runnable_hosts_json "${selected_json}")"

  if is_bootstrap_check_action; then
    json_array_to_bash_array "${selected_json}" selected_hosts
    if ! run_bootstrap_key_checks "${runnable_selected_json}" bootstrap_ok_hosts bootstrap_failed_hosts; then
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
  levels_json="$(selected_host_levels_json "${runnable_selected_json}")"
  mapfile -t level_groups < <(jq -c '.[]' <<<"${levels_json}")
  # shellcheck disable=SC2034
  json_array_to_bash_array "${runnable_selected_json}" build_hosts
  if [ "${BUILD_JOBS}" -gt 1 ]; then
    build_parallel=1
  fi
  if [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ]; then
    deploy_parallel=1
    snapshot_parallel=1
  fi

  ensure_tmp_dir
  init_run_dirs \
    "${NIXBOT_TMP_DIR}" \
    build_log_dir \
    build_status_dir \
    snapshot_log_dir \
    snapshot_status_dir \
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
      run_initial_snapshot_wave \
        "${level_groups[0]}" \
        "${snapshot_dir}" \
        "${snapshot_log_dir}" \
        "${snapshot_status_dir}" \
        "${snapshot_parallel}" \
        "${NIXBOT_PARALLEL_JOBS}"
    fi
  fi

  failed_hosts=()
  successful_hosts=()

  if ! run_deploy_phase \
    "${deploy_parallel}" \
    "${NIXBOT_PARALLEL_JOBS}" \
    "${snapshot_dir}" \
    "${snapshot_log_dir}" \
    "${snapshot_status_dir}" \
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

load_cloudflare_tf_backend_runtime_secrets() {
  load_env_value_from_secret_file_if_unset "R2_ACCOUNT_ID" "${TF_R2_ACCOUNT_ID_PATH}"
  load_env_value_from_secret_file_if_unset "R2_STATE_BUCKET" "${TF_R2_STATE_BUCKET_PATH}"
  load_env_value_from_secret_file_if_unset "R2_ACCESS_KEY_ID" "${TF_R2_ACCESS_KEY_ID_PATH}"
  load_env_value_from_secret_file_if_unset "R2_SECRET_ACCESS_KEY" "${TF_R2_SECRET_ACCESS_KEY_PATH}"
}

load_cloudflare_tf_runtime_secrets() {
  load_env_value_from_secret_file_if_unset "CLOUDFLARE_API_TOKEN" "${TF_CLOUDFLARE_API_TOKEN_PATH}"
}

load_gcp_tf_backend_runtime_secrets() {
  load_env_value_from_secret_file_if_unset "GCP_STATE_BUCKET" "${TF_GCP_STATE_BUCKET_PATH}"
  load_env_value_from_secret_file_if_unset "GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT" "${TF_GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT_PATH}"
}

load_gcp_tf_runtime_secrets() {
  load_env_path_from_secret_file_if_unset "GOOGLE_APPLICATION_CREDENTIALS" "${TF_GCP_APPLICATION_CREDENTIALS_PATH}"
}

tf_backend_kind_for_project() {
  local project_name="$1" provider_name="${2:-}"

  if [ -z "${provider_name}" ]; then
    provider_name="$(tf_project_provider_from_name "${project_name}")"
  fi

  case "${project_name}" in
    gcp-bootstrap)
      printf 'r2\n'
      return 0
      ;;
  esac

  case "${provider_name}" in
    cloudflare)
      printf 'r2\n'
      ;;
    gcp)
      printf 'gcs\n'
      ;;
    *)
      printf '\n'
      ;;
  esac
}

load_tf_backend_runtime_secrets_for_kind() {
  local backend_kind="${1:-}"

  case "${backend_kind}" in
    r2)
      load_cloudflare_tf_backend_runtime_secrets
      ;;
    gcs)
      load_gcp_tf_backend_runtime_secrets
      ;;
  esac
}

load_tf_provider_runtime_secrets() {
  local provider_name="${1:-}"

  case "${provider_name}" in
    cloudflare)
      load_cloudflare_tf_runtime_secrets
      ;;
    gcp)
      load_gcp_tf_runtime_secrets
      ;;
  esac
}

require_tf_backend_runtime_env_for_kind() {
  local backend_kind="${1:-}"

  case "${backend_kind}" in
    r2)
      require_nonempty_env_var "R2_ACCOUNT_ID"
      require_nonempty_env_var "R2_STATE_BUCKET"
      require_nonempty_env_var "R2_ACCESS_KEY_ID"
      require_nonempty_env_var "R2_SECRET_ACCESS_KEY"
      ;;
    gcs)
      require_nonempty_env_var "GCP_STATE_BUCKET"
      ;;
  esac
}

require_tf_provider_runtime_env() {
  local provider_name="${1:-}"

  case "${provider_name}" in
    cloudflare)
      require_nonempty_env_var "CLOUDFLARE_API_TOKEN"
      ;;
    gcp)
      require_existing_file_env_var "GOOGLE_APPLICATION_CREDENTIALS"
      ;;
  esac
}

require_supported_tf_backend_for_project() {
  local project_name="$1" provider_name="${2:-}" backend_kind=""

  backend_kind="$(tf_backend_kind_for_project "${project_name}" "${provider_name}")"
  [ -n "${backend_kind}" ] || die "Unsupported Terraform backend for project: ${project_name}"
}

resolve_tf_backend_context_for_project() {
  local project_name="$1" provider_name="$2"
  local backend_kind="" backend_detail_1="" backend_detail_2=""

  backend_kind="$(tf_backend_kind_for_project "${project_name}" "${provider_name}")"

  case "${backend_kind}" in
    r2)
      backend_detail_1="$(tf_state_key_for_project "${project_name}")"
      backend_detail_2="$(tf_backend_endpoint)"
      ;;
    gcs)
      backend_detail_1="$(gcp_state_prefix_for_project "${project_name}")"
      backend_detail_2="${GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT:-}"
      ;;
  esac

  printf '%s\n%s\n%s\n' "${backend_kind}" "${backend_detail_1}" "${backend_detail_2}"
}

append_tf_backend_config_args_for_project() {
  local -n atbcapfp_cmd_inout_ref="$1"
  local project_name="$2" provider_name="$3" backend_kind="" backend_detail_1="" backend_detail_2=""

  {
    read -r backend_kind
    read -r backend_detail_1
    read -r backend_detail_2
  } < <(resolve_tf_backend_context_for_project "${project_name}" "${provider_name}")

  case "${backend_kind}" in
    r2)
      atbcapfp_cmd_inout_ref+=(
        -backend-config="bucket=${R2_STATE_BUCKET}"
        -backend-config="key=${backend_detail_1}"
        -backend-config="region=auto"
        -backend-config="endpoint=${backend_detail_2}"
        -backend-config="access_key=${R2_ACCESS_KEY_ID}"
        -backend-config="secret_key=${R2_SECRET_ACCESS_KEY}"
        -backend-config="skip_credentials_validation=true"
        -backend-config="skip_region_validation=true"
        -backend-config="skip_requesting_account_id=true"
        -backend-config="use_path_style=true"
      )
      ;;
    gcs)
      atbcapfp_cmd_inout_ref+=(
        -backend-config="bucket=${GCP_STATE_BUCKET}"
        -backend-config="prefix=${backend_detail_1}"
      )
      if [ -n "${backend_detail_2}" ]; then
        atbcapfp_cmd_inout_ref+=(-backend-config="impersonate_service_account=${backend_detail_2}")
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

tf_project_name_from_dir() {
  basename "$1"
}

tf_project_provider_from_name() {
  local project_name="$1"
  printf '%s\n' "${project_name%-*}"
}

tf_project_names_for_phase() {
  local phase="$1" project_name=""

  if [ -n "${TF_WORK_DIR}" ]; then
    project_name="$(tf_project_name_from_dir "${TF_WORK_DIR}")"
    if [[ "${project_name}" == *-"${phase}" ]]; then
      printf '%s\n' "${project_name}"
    fi
    return 0
  fi

  for project_name in "${TF_PROJECT_NAMES[@]}"; do
    [ "$(tf_project_phase_from_name "${project_name}")" = "${phase}" ] || continue
    printf '%s\n' "${project_name}"
  done
}

tf_project_dir_from_name() {
  local project_name="$1"
  printf 'tf/%s\n' "${project_name}"
}

tf_project_dir_from_action() {
  local action="$1" project_name=""

  project_name="$(tf_action_project_name "${action}")" || return 1
  tf_project_dir_from_name "${project_name}"
}

tf_project_dirs_for_phase() {
  local phase="$1" project_name="" project_dir=""

  while IFS= read -r project_name; do
    [ -n "${project_name}" ] || continue
    project_dir="$(tf_project_dir_from_name "${project_name}")"
    [ -d "${project_dir}" ] || die "Configured Terraform project directory not found: ${project_dir}"
    printf '%s\n' "${project_dir}"
  done < <(tf_project_names_for_phase "${phase}")
}

tf_state_key_for_project() {
  local project_name="$1"

  if [ -n "${R2_STATE_KEY:-}" ]; then
    printf '%s\n' "${R2_STATE_KEY}"
    return 0
  fi

  printf '%s/terraform.tfstate\n' "${project_name}"
}

gcp_state_prefix_for_project() {
  local project_name="$1"

  if [ -n "${GCP_STATE_PREFIX:-}" ]; then
    printf '%s\n' "${GCP_STATE_PREFIX}"
    return 0
  fi

  printf '%s/terraform.tfstate\n' "${project_name}"
}

emit_tf_secret_paths_for_project() {
  local project_name="$1" provider_name=""

  provider_name="$(tf_project_provider_from_name "${project_name}")"

  [ -f "${TF_SECRETS_DIR}/${provider_name}.tfvars.age" ] && printf '%s\n' "${TF_SECRETS_DIR}/${provider_name}.tfvars.age"
  [ -d "${TF_SECRETS_DIR}/${provider_name}" ] && find "${TF_SECRETS_DIR}/${provider_name}" -type f -name '*.tfvars.age' | sort

  [ -f "${TF_SECRETS_DIR}/${project_name}.tfvars.age" ] && printf '%s\n' "${TF_SECRETS_DIR}/${project_name}.tfvars.age"
  [ -d "${TF_SECRETS_DIR}/${project_name}" ] && find "${TF_SECRETS_DIR}/${project_name}" -type f -name '*.tfvars.age' | sort
}

load_tf_runtime_secrets_for_project() {
  local project_name="$1" provider_name="" backend_kind=""

  provider_name="$(tf_project_provider_from_name "${project_name}")"
  backend_kind="$(tf_backend_kind_for_project "${project_name}" "${provider_name}")"
  load_tf_backend_runtime_secrets_for_kind "${backend_kind}"
  load_tf_provider_runtime_secrets "${provider_name}"
}

require_tf_runtime_env_for_project() {
  local project_name="$1" provider_name="" backend_kind=""

  provider_name="$(tf_project_provider_from_name "${project_name}")"
  backend_kind="$(tf_backend_kind_for_project "${project_name}" "${provider_name}")"
  require_tf_backend_runtime_env_for_kind "${backend_kind}"
  require_tf_provider_runtime_env "${provider_name}"
}

is_tf_candidate_path_for_project() {
  local phase="$1" project_name="$2" path="$3" provider_name=""

  provider_name="$(tf_project_provider_from_name "${project_name}")"

  case "${path}" in
    "tf/${project_name}"|"tf/${project_name}/"*) return 0 ;;
    "tf/modules/${provider_name}"|"tf/modules/${provider_name}/"*) return 0 ;;
    "data/secrets/${provider_name}"|"data/secrets/${provider_name}/"*) return 0 ;;
    "data/secrets/tf/${provider_name}.tfvars.age") return 0 ;;
    "data/secrets/tf/${provider_name}"|"data/secrets/tf/${provider_name}/"*) return 0 ;;
    "data/secrets/tf/${project_name}.tfvars.age") return 0 ;;
    "data/secrets/tf/${project_name}"|"data/secrets/tf/${project_name}/"*) return 0 ;;
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
  local input_dir="$1" require_repo_project="${2:-1}"
  local project_dir="" project_name="" provider_name=""

  project_dir="$(resolve_tf_project_dir "${input_dir}")"

  project_name="$(tf_project_name_from_dir "${project_dir}")"
  if [[ "${project_name}" != *-* ]] || [ "$(basename "$(dirname "${project_dir}")")" != "tf" ]; then
    [ "${require_repo_project}" -eq 1 ] && return 1
    printf '%s\n%s\n%s\n' "${project_dir}" "" ""
    return 0
  fi

  provider_name="$(tf_project_provider_from_name "${project_name}")"
  printf '%s\n%s\n%s\n' "${project_dir}" "${project_name}" "${provider_name}"
}

prepare_tf_project_runtime() {
  local project_name="$1" provider_name=""

  provider_name="$(tf_project_provider_from_name "${project_name}")"

  prepare_tf_apps_project_runtime "${project_name}"
  require_supported_tf_backend_for_project "${project_name}" "${provider_name}"
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
  local project_name="$1" project_pkg_dir=""

  if ! project_pkg_dir="$(tf_project_apps_package_dir "${project_name}")"; then
    return 0
  fi

  echo "Preparing Terraform apps package build: ${project_name}" >&2
  nix build "path:${project_pkg_dir}#build" --no-link
}

emit_tf_var_secret_paths_for_project() {
  local project_name="$1" log_discovered_paths="${2:-0}" tf_var_path=""

  while IFS= read -r tf_var_path; do
    [ -n "${tf_var_path}" ] || continue
    if [ "${log_discovered_paths}" -eq 1 ]; then
      echo "Sensitive tfvars: ${tf_var_path}" >&2
    fi
    printf '%s\n' "${tf_var_path}"
  done < <(emit_tf_secret_paths_for_project "${project_name}" | sort -u)
}

materialize_tf_var_files_for_project() {
  local project_name="$1"
  local -n mtvffp_tf_var_files_out_ref="$2" mtvffp_discovered_tf_var_files_out_ref="$3"
  local log_discovered_paths="${4:-0}" tf_var_path="" resolved_tf_var_file=""

  mtvffp_tf_var_files_out_ref=()
  mtvffp_discovered_tf_var_files_out_ref=0

  ensure_tmp_dir
  while IFS= read -r tf_var_path; do
    mtvffp_discovered_tf_var_files_out_ref=$((mtvffp_discovered_tf_var_files_out_ref + 1))
    resolved_tf_var_file="$(resolve_runtime_key_file "${tf_var_path}")"
    if [ -f "${resolved_tf_var_file}" ]; then
      mtvffp_tf_var_files_out_ref+=("${resolved_tf_var_file}")
    elif [ "${log_discovered_paths}" -eq 1 ]; then
      echo "Sensitive tfvars: ${tf_var_path} not present" >&2
    fi
  done < <(emit_tf_var_secret_paths_for_project "${project_name}" "${log_discovered_paths}")
}

append_tf_var_files_to_cmd() {
  # shellcheck disable=SC2178
  local -n atvftc_cmd_inout_ref="$1"
  shift
  local tf_var_file=""

  for tf_var_file in "$@"; do
    atvftc_cmd_inout_ref+=("-var-file=${tf_var_file}")
  done
}

tf_backend_endpoint() {
  printf 'https://%s.r2.cloudflarestorage.com\n' "${R2_ACCOUNT_ID}"
}

evaluate_tf_project_action_need() {
  local phase="$1" project_name="$2"
  local decision="" detail="" target_ref="" base_ref="" diff_output="" diff_status=0 path="" status_output="" status_path=""

  if [ "${TF_IF_CHANGED}" -eq 0 ]; then
    decision="run-force"
    printf '%s\n%s\n' "${decision}" "${detail}"
    return 0
  fi

  target_ref="${SHA:-HEAD}"
  if ! git rev-parse --verify "${target_ref}" >/dev/null 2>&1; then
    decision="run-target-unavailable"
    detail="${target_ref}"
    printf '%s\n%s\n' "${decision}" "${detail}"
    return 0
  fi

  if ! base_ref="$(resolve_tf_change_base_ref "${target_ref}")"; then
    decision="run-base-unavailable"
    detail="${target_ref}"
    printf '%s\n%s\n' "${decision}" "${detail}"
    return 0
  fi

  diff_output="$(git diff --name-only "${base_ref}" "${target_ref}" -- 2>/dev/null)" || diff_status=$?
  if [ "${diff_status}" -ne 0 ]; then
    decision="run-diff-failed"
    detail="${base_ref}..${target_ref}"
    printf '%s\n%s\n' "${decision}" "${detail}"
    return 0
  fi

  while IFS= read -r path; do
    [ -n "${path}" ] || continue
    if is_tf_candidate_path_for_project "${phase}" "${project_name}" "${path}"; then
      decision="run-diff-changed"
      detail="${path}"
      printf '%s\n%s\n' "${decision}" "${detail}"
      return 0
    fi
  done <<< "${diff_output}"

  status_output="$(git status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
  while IFS= read -r status_path; do
    [ -n "${status_path}" ] || continue
    status_path="${status_path#?? }"
    status_path="${status_path##* -> }"
    if is_tf_candidate_path_for_project "${phase}" "${project_name}" "${status_path}"; then
      decision="run-worktree-changed"
      detail="${status_path}"
      printf '%s\n%s\n' "${decision}" "${detail}"
      return 0
    fi
  done <<< "${status_output}"

  decision="skip-unchanged"
  printf '%s\n%s\n' "${decision}" "${detail}"
}

resolve_tf_change_base_ref() {
  local target_ref="${1:-HEAD}" target_commit="" base_commit=""

  target_commit="$(git rev-parse --verify "${target_ref}" 2>/dev/null)" || return 1

  if [ -n "${TF_CHANGE_BASE_REF}" ] && base_commit="$(git rev-parse --verify "${TF_CHANGE_BASE_REF}" 2>/dev/null)"; then
    if [ "${base_commit}" != "${target_commit}" ]; then
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
  local i="" arg=""

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
  local arg=""

  for arg in "$@"; do
    case "${arg}" in
      -var|-var=*|-var-file|-var-file=*)
        return 0
        ;;
    esac
  done

  return 1
}

tofu_args_have_explicit_backend_config() {
  local arg=""

  for arg in "$@"; do
    case "${arg}" in
      -backend-config|-backend-config=*)
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
  local subcommand=""

  if ! subcommand="$(tofu_args_extract_subcommand "$@")"; then
    return 1
  fi

  if ! tofu_subcommand_supports_var_files "${subcommand}"; then
    return 1
  fi

  if tofu_args_have_explicit_vars "$@"; then
    return 1
  fi

  printf '%s\n' "${subcommand}"
}

_exec_tofu_cmd() {
  local project_name="${1:-}"
  shift
  local subcommand="" discovered_tf_var_files=0
  local -a cmd=() tf_var_files=()

  cmd=(tofu "$@")

  if [ -n "${project_name}" ] && subcommand="$(resolve_tofu_auto_var_file_subcommand "$@")"; then
    materialize_tf_var_files_for_project "${project_name}" tf_var_files discovered_tf_var_files 1

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
  local tf_dir="$1" backend_kind="$2" backend_detail_1="$3" backend_detail_2="$4"

  echo "Working dir: ${tf_dir}" >&2

  case "${backend_kind}" in
    r2)
      echo "State bucket: ${R2_STATE_BUCKET}" >&2
      echo "State key: ${backend_detail_1}" >&2
      echo "Endpoint: ${backend_detail_2}" >&2
      ;;
    gcs)
      echo "State bucket: ${GCP_STATE_BUCKET}" >&2
      echo "State prefix: ${backend_detail_1}" >&2
      if [ -n "${backend_detail_2}" ]; then
        echo "Backend impersonation: ${backend_detail_2}" >&2
      fi
      ;;
  esac
}

run_tf_action() {
  local project_dir="$1" project_name="" provider_name=""
  local tf_dir="" plan_file="" backend_kind="" backend_detail_1="" backend_detail_2=""
  local -a init_cmd=()

  if ! {
    read -r tf_dir
    read -r project_name
    read -r provider_name
  } < <(resolve_tf_project_context "${project_dir}" 1); then
    return 1
  fi
  prepare_tf_project_runtime "${project_name}"

  if ! {
    read -r backend_kind
    read -r backend_detail_1
    read -r backend_detail_2
  } < <(resolve_tf_backend_context_for_project "${project_name}" "${provider_name}"); then
    return 1
  fi

  log_tf_action_context "${tf_dir}" "${backend_kind}" "${backend_detail_1}" "${backend_detail_2}"
  init_cmd=(tofu -chdir="${tf_dir}" init -lockfile=readonly)
  append_tf_backend_config_args_for_project init_cmd "${project_name}" "${provider_name}"
  if ! run_with_combined_output "${init_cmd[@]}"; then
    return 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    if ! _exec_tofu_cmd "${project_name}" -chdir="${tf_dir}" plan -input=false; then
      return 1
    fi
    return
  fi

  ensure_tmp_dir
  plan_file="$(tmp_runtime_mktemp tf "tfplan.XXXXXX")"
  if ! _exec_tofu_cmd "${project_name}" -chdir="${tf_dir}" plan -input=false -out="${plan_file}"; then
    return 1
  fi
  # Apply saved plan (no var-file injection)
  if ! _exec_tofu_cmd "" -chdir="${tf_dir}" apply -input=false -auto-approve "${plan_file}"; then
    return 1
  fi
}

log_tf_project_status() {
  local project_name="$1" status="$2"

  echo "Terraform ${project_name}: ${status}" >&2
}

run_tf_project_action() {
  local phase="$1" project_name="$2" project_dir="$3" log_file="" status_file="" rc=0

  log_grouped_nested_item_start "$(log_group_tf_project_title "${phase}" "${project_name}")"
  log_subsection "Terraform Project: ${project_name}"
  ensure_tmp_dir
  log_file="$(phase_item_log_file "${NIXBOT_TMP_DIR}" "tf" "${phase}" "${project_name}")"
  status_file="$(phase_item_status_file "${NIXBOT_TMP_DIR}" "tf" "${phase}" "${project_name}")"
  if run_tf_action "${project_dir}" > >(tee -a "${log_file}") 2>&1; then
    write_status_file "${status_file}" 0
  else
    rc="$?"
    write_status_file "${status_file}" "${rc}"
  fi
  log_grouped_item_end
  [ "${rc}" -eq 0 ]
}

run_requested_tf_project_by_name() {
  local phase="$1" project_name="$2" project_dir="$3" action_need="" action_detail=""

  if ! {
    read -r action_need
    read -r action_detail
  } < <(evaluate_tf_project_action_need "${phase}" "${project_name}"); then
    return 1
  fi

  case "${action_need}" in
    run-force)
      echo "Terraform change detection bypassed by --force" >&2
      ;;
    run-target-unavailable)
      echo "Terraform change detection unavailable for ${action_detail}; running TF ${phase}" >&2
      ;;
    run-base-unavailable)
      echo "Terraform change base unavailable for ${action_detail}; running TF ${phase}" >&2
      ;;
    run-diff-failed)
      echo "Terraform change detection failed for ${action_detail}; running TF ${phase}" >&2
      ;;
    run-diff-changed)
      echo "Terraform ${project_name} change detected: ${action_detail}" >&2
      ;;
    run-worktree-changed)
      echo "Terraform ${project_name} working tree change detected: ${action_detail}" >&2
      ;;
    skip-unchanged)
      echo "Terraform ${project_name} unchanged; skipping TF action" >&2
      log_tf_project_status "${project_name}" "skip"
      record_tf_run_summary "${phase}" "${project_name}" "skip"
      return 0
      ;;
    *)
      die "Unsupported Terraform action evaluation for ${project_name}: ${action_need}"
      ;;
  esac

  if run_tf_project_action "${phase}" "${project_name}" "${project_dir}"; then
    log_tf_project_status "${project_name}" "ok"
    record_tf_run_summary "${phase}" "${project_name}" "ok"
    return 0
  fi

  log_tf_project_status "${project_name}" "fail"
  record_tf_run_summary "${phase}" "${project_name}" "fail"
  return 1
}

tofu_wrapper_extract_chdir() {
  local -a args=("$@")
  local i="" arg=""

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
  local chdir_arg="" input_dir=""

  chdir_arg="$(tofu_wrapper_extract_chdir "$@" || true)"
  input_dir="${chdir_arg:-$(pwd -P)}"
  resolve_tf_project_context "${input_dir}" 0
}

run_tofu_wrapper() {
  local -a tofu_args=("$@")
  local project_dir="" project_name="" provider_name="" subcommand=""
  local -a cmd=()

  [ "${#tofu_args[@]}" -gt 0 ] || die "Usage: nixbot tofu <tofu-args...>"
  [ -z "${SSH_ORIGINAL_COMMAND:-}" ] || die "The nixbot tofu wrapper is local-only and cannot run via SSH forced-command/bastion trigger."

  if {
    read -r project_dir
    read -r project_name
    read -r provider_name
  } < <(resolve_tofu_wrapper_context "${tofu_args[@]}") && [ -n "${project_name}" ]; then
    prepare_tf_project_runtime "${project_name}"
    echo "Terraform wrapper project: ${project_name} (${provider_name})" >&2
  fi

  subcommand="$(tofu_args_extract_subcommand "${tofu_args[@]}" || true)"
  if [ -n "${project_name}" ] && [ "${subcommand}" = "init" ] && ! tofu_args_have_explicit_backend_config "${tofu_args[@]}"; then
    cmd=(tofu "${tofu_args[@]}")
    append_tf_backend_config_args_for_project cmd "${project_name}" "${provider_name}" \
      || die "Unsupported Terraform backend for wrapper init: ${project_name}"
    run_with_combined_output "${cmd[@]}"
    return
  fi

  _exec_tofu_cmd "${project_name}" "${tofu_args[@]}"
}

run_requested_tf_phase() {
  local phase="$1" project_dir="" found=0 project_name="" project_rc=0

  log_section "Phase: Terraform (${phase})"

  while IFS= read -r project_dir; do
    [ -n "${project_dir}" ] || continue
    found=1
    project_name="$(tf_project_name_from_dir "${project_dir}")"
    project_rc=0

    run_requested_tf_project_by_name "${phase}" "${project_name}" "${project_dir}" || project_rc=1

    if [ "${project_rc}" -ne 0 ]; then
      return 1
    fi
  done < <(tf_project_dirs_for_phase "${phase}")

  if [ "${found}" -eq 0 ]; then
    echo "No Terraform ${phase} projects found; skipping" >&2
  fi
}

run_requested_tf_project() {
  local action="$1" project_name="" phase="" project_dir=""

  project_name="$(tf_action_project_name "${action}")" || die "Unsupported Terraform project action: ${action}"
  tf_project_name_is_configured "${project_name}" || die "Unsupported Terraform project action: ${action}"
  phase="$(tf_project_phase_from_name "${project_name}")" || die "Unable to determine Terraform phase for project: ${project_name}"
  project_dir="$(tf_project_dir_from_name "${project_name}")"
  [ -d "${project_dir}" ] || die "Configured Terraform project directory not found: ${project_dir}"

  log_section "Phase: Terraform (${phase})"
  run_requested_tf_project_by_name "${phase}" "${project_name}" "${project_dir}"
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
    tf/*)
      run_requested_tf_project "${ACTION}"
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
  local level="$1" title="$2" group_mode="${3:-auto}"

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
  local title="$1" group_mode="${2:-auto}"

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
  local title="$1" group_mode="${2:-auto}"

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
  local phase="$1" project_name="$2"

  printf 'Phase: Terraform (%s) / %s\n' "${phase}" "${project_name}"
}

log_host_stage() {
  local phase="$1" node="$2" extra="${3:-}" border=""

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
  local title="$1" scope="$2" grouped="$3"

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
  local phase="$1" node="$2" phase_title=""

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
  local item=""

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
  local item=""

  for item in "$@"; do
    [ "${item}" = "${needle}" ] && return 0
  done

  return 1
}

host_final_status() {
  local action="$1" node="$2"
  local fully_skipped_hosts_name="$3" build_ok_hosts_name="$4" build_failed_hosts_name="$5"
  local snapshot_failed_hosts_name="$6" deploy_ok_hosts_name="$7"
  local deploy_skipped_hosts_name="$8" deploy_failed_hosts_name="$9"
  local optional_snapshot_skipped_hosts_name="${10}" optional_rollback_ok_hosts_name="${11}"
  local optional_rollback_failed_hosts_name="${12}"
  local rollback_ok_hosts_name="${13}" rollback_failed_hosts_name="${14}"
  local -n hfs_fully_skipped_hosts_in_ref="${fully_skipped_hosts_name}"
  local -n hfs_build_ok_hosts_in_ref="${build_ok_hosts_name}"
  local -n hfs_build_failed_hosts_in_ref="${build_failed_hosts_name}"
  # shellcheck disable=SC2178
  local -n hfs_snapshot_failed_hosts_in_ref="${snapshot_failed_hosts_name}"
  local -n hfs_deploy_ok_hosts_in_ref="${deploy_ok_hosts_name}"
  local -n hfs_deploy_skipped_hosts_in_ref="${deploy_skipped_hosts_name}"
  # shellcheck disable=SC2178
  local -n hfs_deploy_failed_hosts_in_ref="${deploy_failed_hosts_name}"
  local -n hfs_optional_snapshot_skipped_hosts_in_ref="${optional_snapshot_skipped_hosts_name}"
  local -n hfs_optional_rollback_ok_hosts_in_ref="${optional_rollback_ok_hosts_name}"
  local -n hfs_optional_rollback_failed_hosts_in_ref="${optional_rollback_failed_hosts_name}"
  local -n hfs_rollback_ok_hosts_in_ref="${rollback_ok_hosts_name}"
  local -n hfs_rollback_failed_hosts_in_ref="${rollback_failed_hosts_name}"

  if array_contains "${node}" "${hfs_build_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (build)'
    return
  fi

  if array_contains "${node}" "${hfs_fully_skipped_hosts_in_ref[@]}"; then
    printf '%s' 'skip'
    return
  fi

  if [ "${action}" = "build" ] || [ "${action}" = "check-bootstrap" ]; then
    if array_contains "${node}" "${hfs_build_ok_hosts_in_ref[@]}"; then
      printf '%s' 'ok'
    else
      printf '%s' 'FAIL'
    fi
    return
  fi

  if array_contains "${node}" "${hfs_optional_rollback_failed_hosts_in_ref[@]}"; then
    printf '%s' 'optional (rollback failed)'
  elif array_contains "${node}" "${hfs_optional_snapshot_skipped_hosts_in_ref[@]}"; then
    printf '%s' 'optional (snapshot skipped)'
  elif array_contains "${node}" "${hfs_optional_rollback_ok_hosts_in_ref[@]}"; then
    printf '%s' 'optional (rolled back)'
  elif array_contains "${node}" "${hfs_rollback_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (rollback)'
  elif array_contains "${node}" "${hfs_snapshot_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (snapshot)'
  elif array_contains "${node}" "${hfs_deploy_failed_hosts_in_ref[@]}"; then
    printf '%s' 'FAIL (deploy)'
  elif array_contains "${node}" "${hfs_rollback_ok_hosts_in_ref[@]}"; then
    printf '%s' 'rolled back'
  elif array_contains "${node}" "${hfs_deploy_skipped_hosts_in_ref[@]}"; then
    printf '%s' 'ok (skip)'
  elif array_contains "${node}" "${hfs_deploy_ok_hosts_in_ref[@]}"; then
    printf '%s' 'ok'
  elif array_contains "${node}" "${hfs_build_ok_hosts_in_ref[@]}"; then
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
  local tf_status=""

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
  local final_rc="$1" node="" status=""
  local -a failed_summary_hosts=()
  local tf_label="" tf_status="" tf_display_status=""
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
      RUN_SUMMARY_FULLY_SKIPPED_HOSTS \
      RUN_SUMMARY_BUILD_OK_HOSTS \
      RUN_SUMMARY_BUILD_FAILED_HOSTS \
      RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS \
      RUN_SUMMARY_DEPLOY_OK_HOSTS \
      RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS \
      RUN_SUMMARY_DEPLOY_FAILED_HOSTS \
      RUN_SUMMARY_OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS \
      RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS \
      RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS \
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
  if [ "${#failed_summary_hosts[@]}" -gt 0 ] || [ "${#failed_summary_tf[@]}" -gt 0 ]; then
    printf '\n!!!!!!!!!! FAILURE !!!!!!!!!!\n' >&2
    for node in "${failed_summary_hosts[@]}"; do
      echo "  - ${node}" >&2
    done
    for tf_label in "${failed_summary_tf[@]}"; do
      echo "  - ${tf_label}" >&2
    done
  fi
  printf '\nResult: %s\n' "$([ "${final_rc}" -eq 0 ] && printf 'success' || printf 'failure')" >&2
}

clear_run_summary_state() {
  RUN_SUMMARY_ACTION=""
  RUN_SUMMARY_SELECTED_HOSTS=()
  RUN_SUMMARY_FULLY_SKIPPED_HOSTS=()
  RUN_SUMMARY_BUILD_OK_HOSTS=()
  RUN_SUMMARY_BUILD_FAILED_HOSTS=()
  RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS=()
  RUN_SUMMARY_DEPLOY_OK_HOSTS=()
  RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS=()
  RUN_SUMMARY_DEPLOY_FAILED_HOSTS=()
  RUN_SUMMARY_OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=()
  RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
  RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=()
  RUN_SUMMARY_ROLLBACK_OK_HOSTS=()
  RUN_SUMMARY_ROLLBACK_FAILED_HOSTS=()
  RUN_SUMMARY_TF_LABELS=()
  RUN_SUMMARY_TF_STATUSES=()
}

set_run_summary_host_state() {
  local action="$1" selected_hosts_name="$2"
  local fully_skipped_hosts_name="$3" build_ok_hosts_name="$4" build_failed_hosts_name="$5"
  local snapshot_failed_hosts_name="$6" deploy_ok_hosts_name="$7"
  local deploy_skipped_hosts_name="$8" deploy_failed_hosts_name="$9"
  local optional_snapshot_skipped_hosts_name="${10}" optional_rollback_ok_hosts_name="${11}"
  local optional_rollback_failed_hosts_name="${12}"
  local rollback_ok_hosts_name="${13}" rollback_failed_hosts_name="${14}"
  local -n srshs_selected_hosts_in_ref="${selected_hosts_name}"
  local -n srshs_fully_skipped_hosts_in_ref="${fully_skipped_hosts_name}"
  local -n srshs_build_ok_hosts_in_ref="${build_ok_hosts_name}"
  local -n srshs_build_failed_hosts_in_ref="${build_failed_hosts_name}"
  # shellcheck disable=SC2178
  local -n srshs_snapshot_failed_hosts_in_ref="${snapshot_failed_hosts_name}"
  local -n srshs_deploy_ok_hosts_in_ref="${deploy_ok_hosts_name}"
  local -n srshs_deploy_skipped_hosts_in_ref="${deploy_skipped_hosts_name}"
  # shellcheck disable=SC2178
  local -n srshs_deploy_failed_hosts_in_ref="${deploy_failed_hosts_name}"
  local -n srshs_optional_snapshot_skipped_hosts_in_ref="${optional_snapshot_skipped_hosts_name}"
  local -n srshs_optional_rollback_ok_hosts_in_ref="${optional_rollback_ok_hosts_name}"
  local -n srshs_optional_rollback_failed_hosts_in_ref="${optional_rollback_failed_hosts_name}"
  local -n srshs_rollback_ok_hosts_in_ref="${rollback_ok_hosts_name}"
  local -n srshs_rollback_failed_hosts_in_ref="${rollback_failed_hosts_name}"

  # shellcheck disable=SC2034
  {
    RUN_SUMMARY_ACTION="${action}"
    RUN_SUMMARY_SELECTED_HOSTS=("${srshs_selected_hosts_in_ref[@]}")
    RUN_SUMMARY_FULLY_SKIPPED_HOSTS=("${srshs_fully_skipped_hosts_in_ref[@]}")
    RUN_SUMMARY_BUILD_OK_HOSTS=("${srshs_build_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_BUILD_FAILED_HOSTS=("${srshs_build_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS=("${srshs_snapshot_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_OK_HOSTS=("${srshs_deploy_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_SKIPPED_HOSTS=("${srshs_deploy_skipped_hosts_in_ref[@]}")
    RUN_SUMMARY_DEPLOY_FAILED_HOSTS=("${srshs_deploy_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=("${srshs_optional_snapshot_skipped_hosts_in_ref[@]}")
    RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=("${srshs_optional_rollback_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=("${srshs_optional_rollback_failed_hosts_in_ref[@]}")
    RUN_SUMMARY_ROLLBACK_OK_HOSTS=("${srshs_rollback_ok_hosts_in_ref[@]}")
    RUN_SUMMARY_ROLLBACK_FAILED_HOSTS=("${srshs_rollback_failed_hosts_in_ref[@]}")
  }
}

record_tf_run_summary() {
  local phase="$1" project_name="$2" status="$3"

  RUN_SUMMARY_TF_LABELS+=("${phase}/${project_name}")
  RUN_SUMMARY_TF_STATUSES+=("${status}")
}

# End logging helpers.

##### Dispatch #####

ensure_runtime_shell() {
  local script_path="" script_dir="" flake_path=""
  local -a nix_shell_cmd=()

  if [ "${RUNTIME_SHELL_FLAG}" = "1" ]; then
    return
  fi

  require_cmds nix

  script_path="${BASH_SOURCE[0]:-$0}"
  script_dir="$(cd "$(dirname "${script_path}")" && pwd -P)"
  if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    nix_shell_cmd=(nix shell "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
  else
    flake_path="$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "${flake_path}" ]; then
      flake_path="$(cd "${script_dir}/../.." && pwd -P)"
    fi
    nix_shell_cmd=(nix shell --inputs-from "${flake_path}" "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
  fi

  exec "${nix_shell_cmd[@]}" -c env NIXBOT_IN_NIX_SHELL=1 bash "${script_path}" "$@"
}

ensure_runtime_tools() {
  require_cmds "${NIXBOT_RUNTIME_COMMANDS[@]}"
}

ensure_runtime_ready() {
  ensure_runtime_shell "$@"
  ensure_runtime_tools
}

run_deps_action() {
  ensure_runtime_ready "$@"
}

run_check_deps_action() {
  ensure_runtime_tools
}

run_version_action() {
  printf '%s\n' "${NIXBOT_VERSION}"
}

deps_action_help_requested() {
  [ "$#" -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }
}

require_no_extra_action_args() {
  local action_name="$1"
  shift

  [ "$#" -eq 0 ] || die "${action_name} does not accept additional arguments"
}

hydrate_request_args_from_ssh_command() {
  local -n hrafsc_request_args_out_ref="$1"
  local encoded_prefix="${NIXBOT_SSH_ARGV_PREFIX} "
  local encoded_args=""

  if [ "${#hrafsc_request_args_out_ref[@]}" -ne 0 ] || [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then
    return
  fi

  if [[ "${SSH_ORIGINAL_COMMAND}" == "${encoded_prefix}"* ]]; then
    encoded_args="${SSH_ORIGINAL_COMMAND#"${encoded_prefix}"}"
    [ -n "${encoded_args}" ] || die "Empty forced-command argv payload"
    mapfile -d '' -t hrafsc_request_args_out_ref < <(decode_ssh_command_args "${encoded_args}") \
      || die "Failed to decode forced-command argv payload"
    return
  fi

  case "${SSH_ORIGINAL_COMMAND}" in
    *[\`\$\(\)\{\}\;\&\|\<\>\\\'\"]*)
      die "Unsupported SSH forced-command syntax. Use nixbot --bastion-trigger or an unquoted simple argv form."
      ;;
  esac

  read -r -a hrafsc_request_args_out_ref <<<"${SSH_ORIGINAL_COMMAND}"
  if [ "${#hrafsc_request_args_out_ref[@]}" -gt 0 ] && [ "${hrafsc_request_args_out_ref[0]}" = "--" ]; then
    hrafsc_request_args_out_ref=("${hrafsc_request_args_out_ref[@]:1}")
  fi
  if [ "${#hrafsc_request_args_out_ref[@]}" -gt 0 ]; then
    case "${hrafsc_request_args_out_ref[0]}" in
      nixbot|*/nixbot|nixbot.sh|*/nixbot.sh)
        hrafsc_request_args_out_ref=("${hrafsc_request_args_out_ref[@]:1}")
        ;;
    esac
  fi
}

run_deploy_request_action() {
  local selected_json="$1"

  if [ "${ACTION}" = "run" ]; then
    run_all_action "${selected_json}"
  elif action_is_tf_only "${ACTION}"; then
    run_tf_only_action
  else
    run_hosts "${selected_json}"
  fi
}

run_all_action() {
  local selected_json="$1"

  run_tf_phases dns platform || return
  run_hosts "${selected_json}" || return
  run_tf_phases apps || return
}

run_requested_action() {
  local selected_json="" action_rc=0

  if action_is_tf_only "${ACTION}"; then
    log_section "nixbot"
    echo "Version: ${NIXBOT_VERSION}" >&2
    echo "Action: ${ACTION}" >&2
  else
    prepare_run_context selected_json
    log_run_context "${selected_json}"
  fi

  run_deploy_request_action "${selected_json}" || action_rc="$?"

  if [ "${action_rc}" -eq 0 ] && run_summary_has_failures; then
    action_rc=1
  fi

  print_run_summary "${action_rc}"
  return "${action_rc}"
}

##### Main #####

main() {
  local -a request_args=("$@")

  init_vars
  trap cleanup EXIT
  cleanup_stale_runtime_dirs

  hydrate_request_args_from_ssh_command request_args

  if [ "${#request_args[@]}" -eq 0 ]; then
    usage
    return 0
  fi

  case "${request_args[0]}" in
    deps)
      if deps_action_help_requested "${request_args[@]:1}"; then
        usage
        return 0
      fi
      require_no_extra_action_args "deps" "${request_args[@]:1}"
      run_deps_action "$@"
      return
      ;;
    check-deps)
      if deps_action_help_requested "${request_args[@]:1}"; then
        usage
        return 0
      fi
      require_no_extra_action_args "check-deps" "${request_args[@]:1}"
      run_check_deps_action
      return
      ;;
    version)
      if deps_action_help_requested "${request_args[@]:1}"; then
        usage
        return 0
      fi
      require_no_extra_action_args "version" "${request_args[@]:1}"
      run_version_action
      return
      ;;
    run|deploy|build|tf|tf-dns|tf-platform|tf-apps|check-bootstrap|tf/*)
      ACTION="${request_args[0]}"
      request_args=("${request_args[@]:1}")
      ;;
    tofu)
      ensure_runtime_ready "$@"
      run_tofu_wrapper "${request_args[@]:1}"
      return
      ;;
    help|-h|--help)
      usage
      return 0
      ;;
    *)
      usage
      die "Unknown subcommand: ${request_args[0]}"
      ;;
  esac

  ensure_runtime_ready "$@"
  parse_args "${request_args[@]}"
  if [ "${BASTION_TRIGGER}" -eq 1 ]; then
    run_bastion_trigger
    return
  fi

  prepare_repo_worktree
  reexec_repo_script_if_needed "${ACTION}" "${request_args[@]}"

  run_requested_action
}

main "$@"
