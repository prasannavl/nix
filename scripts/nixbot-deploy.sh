#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/nixbot-deploy.sh [--sha <commit>] [--hosts "host1,host2|all"] [--action build|deploy|check-bootstrap] [--goal <goal>] [--build-host <local|target|host>] [--build-jobs <n>] [--deploy-jobs <n>] [--force] [--bootstrap] [--bastion-first] [--dry] [--no-rollback] [--prefix-host-logs] [--user <name>] [--ssh-key <path>] [--known-hosts <contents>] [--config <path>] [--age-key-file <path>] [--repo-url <url>] [--repo-path <path>] [--use-repo-script] [--bastion-check-ssh-key-path <path>] [--bastion-trigger] [--bastion-host <host>] [--bastion-user <user>] [--bastion-ssh-key <key-content>] [--bastion-known-hosts <known-hosts-content>]

Core Workflow Options:
  --action         build|deploy|check-bootstrap (default: deploy)
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

Behavior Options:
  --force          Deploy even when built path matches remote /run/current-system
  --bastion-first  Prioritize bastion host first for build and deploy when selected
  --dry            Print deploy command instead of executing deploy step
  --no-rollback    Disable rollback of successful hosts when any deploy fails
  --prefix-host-logs Always prefix host log lines, even for single-job phases

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
  --repo-url       Repo URL used when --sha requires cloning missing checkout
  --repo-path      Repo checkout path used for --sha workflow
  --use-repo-script Re-exec from checked-out repo script after --sha checkout;
                    keep disabled in CI for security and prefer a two-phase
                    bastion rollout

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
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

resolve_ssh_tty_stdin_path() {
  if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
    printf '/dev/tty\n'
  else
    printf '/dev/null\n'
  fi
}

init_vars() {
  HOSTS_RAW="${DEPLOY_HOSTS:-all}"
  ACTION="${DEPLOY_ACTION:-deploy}"
  GOAL="${DEPLOY_GOAL:-switch}"
  BUILD_HOST="${DEPLOY_BUILD_HOST:-local}"
  BUILD_JOBS="${DEPLOY_BUILD_JOBS:-1}"
  DEPLOY_PARALLEL_JOBS="${DEPLOY_JOBS:-1}"
  DEPLOY_IF_CHANGED=1
  FORCE_BOOTSTRAP_PATH=0
  PRIORITIZE_BASTION_FIRST=0
  DRY_RUN=0
  ROLLBACK_ON_FAILURE=1
  FORCE_PREFIX_HOST_LOGS=0
  PREFIX_HOST_LOGS_EXPLICIT=0
  DEPLOY_CONFIG_PATH="${DEPLOY_CONFIG:-hosts/nixbot.nix}"
  SHA="${DEPLOY_SHA:-}"
  BASTION_TRIGGER=0
  BASTION_TRIGGER_HOST="${DEPLOY_BASTION_HOST:-pvl-x2}"
  BASTION_TRIGGER_USER="${DEPLOY_BASTION_USER:-nixbot}"
  BASTION_TRIGGER_SSH_KEY="${DEPLOY_BASTION_SSH_KEY:-}"
  BASTION_TRIGGER_KNOWN_HOSTS="${DEPLOY_BASTION_KNOWN_HOSTS:-}"
  BASTION_TRIGGER_SSH_OPTS=()
  AGE_DECRYPT_IDENTITY_FILE="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
  REEXEC_FROM_REPO=0

  DEPLOY_USER_OVERRIDE="${DEPLOY_USER:-}"
  DEPLOY_KEY_PATH_OVERRIDE="${DEPLOY_SSH_KEY:-}"
  DEPLOY_KNOWN_HOSTS_OVERRIDE="${DEPLOY_SSH_KNOWN_HOSTS:-}"
  DEPLOY_BASTION_KEY_PATH_OVERRIDE="${DEPLOY_BASTION_SSH_KEY_PATH:-}"
  DEPLOY_KEY_OVERRIDE_EXPLICIT=0

  if [ -n "${DEPLOY_SSH_KEY:-}" ]; then
    DEPLOY_KEY_OVERRIDE_EXPLICIT=1
  fi

  if parse_bool_env "${DEPLOY_FORCE:-0}"; then
    DEPLOY_IF_CHANGED=0
  fi
  if parse_bool_env "${DEPLOY_BASTION_FIRST:-0}"; then
    PRIORITIZE_BASTION_FIRST=1
  fi
  if parse_bool_env "${DEPLOY_BOOTSTRAP:-0}"; then
    FORCE_BOOTSTRAP_PATH=1
  fi
  if parse_bool_env "${DEPLOY_DRY:-0}"; then
    DRY_RUN=1
    DEPLOY_IF_CHANGED=0
  fi
  if parse_bool_env "${DEPLOY_NO_ROLLBACK:-0}"; then
    ROLLBACK_ON_FAILURE=0
  fi
  if [ -n "${DEPLOY_PREFIX_HOST_LOGS:-}" ]; then
    PREFIX_HOST_LOGS_EXPLICIT=1
    if parse_bool_env "${DEPLOY_PREFIX_HOST_LOGS}"; then
      FORCE_PREFIX_HOST_LOGS=1
    else
      FORCE_PREFIX_HOST_LOGS=0
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
  REPO_DEPLOY_SCRIPT_REL="scripts/nixbot-deploy.sh"
  REMOTE_BOOTSTRAP_KEY_TMP_PREFIX="/tmp/nixbot-bootstrap-key."
  REMOTE_AGE_IDENTITY_TMP_PREFIX="/tmp/nixbot-age-identity."

  REPO_BASE="${REMOTE_NIXBOT_BASE}"
  REPO_PATH="${DEPLOY_REPO_PATH:-${REPO_BASE}/nix}"
  REPO_URL="${DEPLOY_REPO_URL:-ssh://git@github.com/prasannavl/nix.git}"
  REPO_SSH_KEY_PATH="${REMOTE_NIXBOT_PRIMARY_KEY}"
  REPO_GIT_SSH_COMMAND="ssh -i ${REPO_SSH_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

  # Prepared per-node context.
  PREP_DEPLOY_SSH_TARGET=""
  PREP_DEPLOY_NIX_SSHOPTS=""
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_AGE_IDENTITY_KEY=""
  PREP_DEPLOY_SSH_OPTS=()
}

parse_bool_env() {
  local raw="${1:-}"
  case "${raw}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    ""|0|false|FALSE|no|NO|off|OFF) return 1 ;;
    *) die "Unsupported boolean value: ${raw}" ;;
  esac
}

normalize_hosts_input() {
  local raw="$1"
  if [ "${raw}" = "all" ]; then
    printf 'all\n'
    return
  fi
  printf '%s' "${raw}" \
    | tr ', ' '\n' \
    | sed '/^$/d' \
    | awk '!seen[$0]++' \
    | paste -sd, -
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sha)
        [ "$#" -ge 2 ] || die "Missing value for --sha"
        SHA="${2:-}"
        shift 2
        ;;
      --sha=*)
        SHA="${1#--sha=}"
        shift
        ;;
      --hosts)
        [ "$#" -ge 2 ] || die "Missing value for --hosts"
        HOSTS_RAW="${2:-}"
        shift 2
        ;;
      --hosts=*)
        HOSTS_RAW="${1#--hosts=}"
        shift
        ;;
      --action)
        [ "$#" -ge 2 ] || die "Missing value for --action"
        ACTION="${2:-}"
        shift 2
        ;;
      --action=*)
        ACTION="${1#--action=}"
        shift
        ;;
      --goal)
        [ "$#" -ge 2 ] || die "Missing value for --goal"
        GOAL="${2:-}"
        shift 2
        ;;
      --goal=*)
        GOAL="${1#--goal=}"
        shift
        ;;
      --build-host)
        [ "$#" -ge 2 ] || die "Missing value for --build-host"
        BUILD_HOST="${2:-}"
        shift 2
        ;;
      --build-host=*)
        BUILD_HOST="${1#--build-host=}"
        shift
        ;;
      --build-jobs)
        [ "$#" -ge 2 ] || die "Missing value for --build-jobs"
        BUILD_JOBS="${2:-}"
        shift 2
        ;;
      --build-jobs=*)
        BUILD_JOBS="${1#--build-jobs=}"
        shift
        ;;
      --deploy-jobs)
        [ "$#" -ge 2 ] || die "Missing value for --deploy-jobs"
        DEPLOY_PARALLEL_JOBS="${2:-}"
        shift 2
        ;;
      --deploy-jobs=*)
        DEPLOY_PARALLEL_JOBS="${1#--deploy-jobs=}"
        shift
        ;;
      --force)
        DEPLOY_IF_CHANGED=0
        shift
        ;;
      --bootstrap)
        FORCE_BOOTSTRAP_PATH=1
        shift
        ;;
      --bastion-first)
        PRIORITIZE_BASTION_FIRST=1
        shift
        ;;
      --dry)
        DRY_RUN=1
        DEPLOY_IF_CHANGED=0
        shift
        ;;
      --no-rollback)
        ROLLBACK_ON_FAILURE=0
        shift
        ;;
      --prefix-host-logs)
        FORCE_PREFIX_HOST_LOGS=1
        PREFIX_HOST_LOGS_EXPLICIT=1
        shift
        ;;
      --user)
        [ "$#" -ge 2 ] || die "Missing value for --user"
        DEPLOY_USER_OVERRIDE="${2:-}"
        shift 2
        ;;
      --user=*)
        DEPLOY_USER_OVERRIDE="${1#--user=}"
        shift
        ;;
      --ssh-key)
        [ "$#" -ge 2 ] || die "Missing value for --ssh-key"
        DEPLOY_KEY_PATH_OVERRIDE="${2:-}"
        DEPLOY_KEY_OVERRIDE_EXPLICIT=1
        shift 2
        ;;
      --ssh-key=*)
        DEPLOY_KEY_PATH_OVERRIDE="${1#--ssh-key=}"
        DEPLOY_KEY_OVERRIDE_EXPLICIT=1
        shift
        ;;
      --known-hosts)
        [ "$#" -ge 2 ] || die "Missing value for --known-hosts"
        DEPLOY_KNOWN_HOSTS_OVERRIDE="${2:-}"
        shift 2
        ;;
      --known-hosts=*)
        DEPLOY_KNOWN_HOSTS_OVERRIDE="${1#--known-hosts=}"
        shift
        ;;
      --config)
        [ "$#" -ge 2 ] || die "Missing value for --config"
        DEPLOY_CONFIG_PATH="${2:-}"
        shift 2
        ;;
      --config=*)
        DEPLOY_CONFIG_PATH="${1#--config=}"
        shift
        ;;
      --age-key-file)
        [ "$#" -ge 2 ] || die "Missing value for --age-key-file"
        AGE_DECRYPT_IDENTITY_FILE="${2:-}"
        shift 2
        ;;
      --age-key-file=*)
        AGE_DECRYPT_IDENTITY_FILE="${1#--age-key-file=}"
        shift
        ;;
      --repo-url)
        [ "$#" -ge 2 ] || die "Missing value for --repo-url"
        REPO_URL="${2:-}"
        shift 2
        ;;
      --repo-url=*)
        REPO_URL="${1#--repo-url=}"
        shift
        ;;
      --repo-path)
        [ "$#" -ge 2 ] || die "Missing value for --repo-path"
        REPO_PATH="${2:-}"
        shift 2
        ;;
      --repo-path=*)
        REPO_PATH="${1#--repo-path=}"
        shift
        ;;
      --use-repo-script)
        REEXEC_FROM_REPO=1
        shift
        ;;
      --bastion-check-ssh-key-path)
        [ "$#" -ge 2 ] || die "Missing value for --bastion-check-ssh-key-path"
        DEPLOY_BASTION_KEY_PATH_OVERRIDE="${2:-}"
        shift 2
        ;;
      --bastion-check-ssh-key-path=*)
        DEPLOY_BASTION_KEY_PATH_OVERRIDE="${1#--bastion-check-ssh-key-path=}"
        shift
        ;;
      --bastion-trigger)
        BASTION_TRIGGER=1
        shift
        ;;
      --bastion-host)
        [ "$#" -ge 2 ] || die "Missing value for --bastion-host"
        BASTION_TRIGGER_HOST="${2:-}"
        shift 2
        ;;
      --bastion-host=*)
        BASTION_TRIGGER_HOST="${1#--bastion-host=}"
        shift
        ;;
      --bastion-user)
        [ "$#" -ge 2 ] || die "Missing value for --bastion-user"
        BASTION_TRIGGER_USER="${2:-}"
        shift 2
        ;;
      --bastion-user=*)
        BASTION_TRIGGER_USER="${1#--bastion-user=}"
        shift
        ;;
      --bastion-ssh-key)
        [ "$#" -ge 2 ] || die "Missing value for --bastion-ssh-key"
        BASTION_TRIGGER_SSH_KEY="${2:-}"
        shift 2
        ;;
      --bastion-ssh-key=*)
        BASTION_TRIGGER_SSH_KEY="${1#--bastion-ssh-key=}"
        shift
        ;;
      --bastion-known-hosts)
        [ "$#" -ge 2 ] || die "Missing value for --bastion-known-hosts"
        BASTION_TRIGGER_KNOWN_HOSTS="${2:-}"
        shift 2
        ;;
      --bastion-known-hosts=*)
        BASTION_TRIGGER_KNOWN_HOSTS="${1#--bastion-known-hosts=}"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage
        die "Unknown argument: $1"
        ;;
    esac
  done

  [ -n "${HOSTS_RAW}" ] || die "--hosts cannot be empty"

  case "${ACTION}" in
    build|deploy|check-bootstrap) ;;
    *) die "Unsupported --action: ${ACTION}" ;;
  esac

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
  if [ -n "${DEPLOY_TMP_DIR}" ] && [ -d "${DEPLOY_TMP_DIR}" ]; then
    rm -rf "${DEPLOY_TMP_DIR}"
  fi
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
}

configure_bastion_trigger_ssh_opts() {
  local key_file known_hosts_file scanned_known_hosts default_bastion_key_path

  BASTION_TRIGGER_SSH_OPTS=()

  ensure_tmp_dir

  if [ -z "${BASTION_TRIGGER_SSH_KEY}" ]; then
    default_bastion_key_path="${BASTION_TRIGGER_KEY_PATH}"
    if key_file="$(resolve_key_source_path "${default_bastion_key_path}")" && [ -f "${key_file}" ] && [ -f "${AGE_DECRYPT_IDENTITY_FILE}" ]; then
      require_cmds age
      if BASTION_TRIGGER_SSH_KEY="$(age --decrypt -i "${AGE_DECRYPT_IDENTITY_FILE}" "${key_file}" 2>/dev/null)"; then
        :
      else
        BASTION_TRIGGER_SSH_KEY=""
      fi
    fi
  fi

  if [ -n "${BASTION_TRIGGER_SSH_KEY}" ]; then
    key_file="$(mktemp "${DEPLOY_TMP_DIR}/bastion-key.XXXXXX")"
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

  known_hosts_file="$(mktemp "${DEPLOY_TMP_DIR}/${BASTION_KNOWN_HOSTS_PREFIX}.XXXXXX")"
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

  case "${ACTION}" in
    build|deploy|check-bootstrap) ;;
    *) die "Unsupported --action for --bastion-trigger: ${ACTION}" ;;
  esac

  trigger_hosts="$(normalize_hosts_input "${HOSTS_RAW}")"
  [ -n "${trigger_hosts}" ] || die "No valid hosts after normalization"

  configure_bastion_trigger_ssh_opts

  log_section "Phase: Remote Trigger"
  echo "Bastion: ${BASTION_TRIGGER_USER}@${BASTION_TRIGGER_HOST}" >&2
  echo "Action: ${ACTION}" >&2
  echo "Hosts: ${trigger_hosts}" >&2
  echo "SHA: ${trigger_sha}" >&2
  remote_command="--sha ${trigger_sha} --hosts ${trigger_hosts} --action ${ACTION}"
  if [ "${DEPLOY_IF_CHANGED}" -eq 0 ]; then
    remote_command="${remote_command} --force"
    echo "Force: true" >&2
  fi
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

ensure_repo_for_sha() {
  if [ -z "${SHA}" ]; then
    return
  fi

  if [ -d ".git" ]; then
    REPO_PATH="$(pwd -P)"
  fi

  mkdir -p "$(dirname "${REPO_PATH}")"

  if [ ! -d "${REPO_PATH}/.git" ]; then
    if [ -f "${REPO_SSH_KEY_PATH}" ]; then
      GIT_SSH_COMMAND="${REPO_GIT_SSH_COMMAND}" git clone "${REPO_URL}" "${REPO_PATH}"
    else
      git clone "${REPO_URL}" "${REPO_PATH}"
    fi
  fi

  [ -f "${REPO_PATH}/${REPO_DEPLOY_SCRIPT_REL}" ] || die "deploy script missing in repo checkout: ${REPO_PATH}/${REPO_DEPLOY_SCRIPT_REL}"

  cd "${REPO_PATH}"
  if [ -f "${REPO_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="${REPO_GIT_SSH_COMMAND}" git fetch --prune origin
  else
    git fetch --prune origin
  fi
  git checkout --detach "${SHA}"
}

reexec_repo_script_if_needed() {
  local current_script repo_script current_resolved repo_resolved
  local -a request_args=("$@")

  [ -n "${SHA}" ] || return 0
  [ "${REEXEC_FROM_REPO}" -eq 1 ] || return 0
  [ "${NIXBOT_REEXECED_FROM_REPO:-0}" != "1" ] || return 0

  current_script="${BASH_SOURCE[0]:-$0}"
  repo_script="${REPO_PATH%/}/${REPO_DEPLOY_SCRIPT_REL}"

  [ -f "${repo_script}" ] || die "Repo deploy script missing after checkout: ${repo_script}"

  current_resolved="$(readlink -f "${current_script}" 2>/dev/null || printf '%s\n' "${current_script}")"
  repo_resolved="$(readlink -f "${repo_script}" 2>/dev/null || printf '%s\n' "${repo_script}")"

  if [ "${current_resolved}" = "${repo_resolved}" ]; then
    return 0
  fi

  log_section "Phase: Repo Re-exec"
  echo "Re-executing deploy from checked-out repo script:" >&2
  echo "${repo_script}" >&2
  exec env NIXBOT_REEXECED_FROM_REPO=1 bash "${repo_script}" "${request_args[@]}"
}

load_deploy_config_json() {
  local path="$1"
  [ -f "${path}" ] || die "Deploy config not found: ${path}"
  require_cmds nix
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
  local src_path out_file

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
    echo "Using decrypt identity: ${AGE_DECRYPT_IDENTITY_FILE} for ${src_path}" >&2
    if [ ! -f "${AGE_DECRYPT_IDENTITY_FILE}" ]; then
      echo "Decrypt identity file not found: ${AGE_DECRYPT_IDENTITY_FILE}" >&2
      return 1
    fi
    ensure_tmp_dir
    out_file="$(mktemp "${DEPLOY_TMP_DIR}/key.XXXXXX")"
    if ! age --decrypt -i "${AGE_DECRYPT_IDENTITY_FILE}" -o "${out_file}" "${src_path}"; then
      rm -f "${out_file}"
      return 1
    fi
    chmod 600 "${out_file}"
    printf '%s\n' "${out_file}"
    return
  fi

  printf '%s\n' "${src_path}"
}

load_all_hosts_json() {
  nix flake show --json --no-write-lock-file 2>/dev/null | jq -c '.nixosConfigurations | keys'
}

select_hosts_json() {
  local all_hosts_json="$1"

  if [ "${HOSTS_RAW}" = "all" ]; then
    printf '%s\n' "${all_hosts_json}"
    return
  fi

  printf '%s' "${HOSTS_RAW}" \
    | tr ', ' '\n' \
    | sed '/^$/d' \
    | awk '!seen[$0]++' \
    | jq -R . \
    | jq -s .
}

expand_selected_hosts_json() {
  local selected_json="$1"
  local all_hosts_json="$2"
  local node dep
  local -a queue=()
  local -a expanded_hosts=()
  declare -A all_host_set=()
  declare -A seen_host_set=()

  for node in $(jq -r '.[]' <<<"${all_hosts_json}"); do
    [ -n "${node}" ] || continue
    all_host_set["${node}"]=1
  done

  mapfile -t queue < <(jq -r '.[]' <<<"${selected_json}")

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
    done < <(jq -r --arg h "${node}" '.[$h].deps // [] | .[]' <<<"${DEPLOY_HOSTS_JSON}")
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

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  for node in $(jq -r '.[]' <<<"${all_hosts_json}"); do
    [ -n "${node}" ] || continue
    all_host_set["${node}"]=1
  done

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    selected_host_set["${node}"]=1
    indegree["${node}"]=0
  done

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    mapfile -t deps < <(jq -r --arg h "${node}" '.[$h].deps // [] | .[]' <<<"${DEPLOY_HOSTS_JSON}")
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

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    selected_host_set["${node}"]=1
  done

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
    done < <(jq -r --arg h "${node}" '.[$h].deps // [] | .[]' <<<"${DEPLOY_HOSTS_JSON}")

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

build_host() {
  local node="$1"
  local out_path

  log_host_stage "build" "${node}"
  echo "Starting local build" >&2
  if ! out_path="$(nix build --print-out-paths ".#nixosConfigurations.${node}.config.system.build.toplevel")"; then
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
  if ! out_path="$(nix eval --raw ".#nixosConfigurations.${node}.config.system.build.toplevel.outPath")"; then
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

  if [ "${ACTION}" = "deploy" ] && [ "${BUILD_HOST}" != "local" ]; then
    eval_host_out_path "${node}"
  else
    build_host "${node}"
  fi
}

ensure_known_hosts_file() {
  local node="$1"
  local known_hosts="$2"
  local safe_node known_hosts_file

  ensure_tmp_dir
  safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
  known_hosts_file="${DEPLOY_TMP_DIR}/${NODE_KNOWN_HOSTS_PREFIX}.${safe_node}"

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
    remote_config_path="${REPO_PATH%/}/${DEPLOY_CONFIG_PATH}"
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

  # shellcheck disable=SC2029
  remote_tmp="$(ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "umask 077; mktemp ${REMOTE_BOOTSTRAP_KEY_TMP_PREFIX}XXXXXX")"
  if [ -z "${remote_tmp}" ]; then
    echo "Failed to allocate remote temporary file for bootstrap key on ${node}" >&2
    return 1
  fi

  if ! scp "${bootstrap_ssh_opts[@]}" "${bootstrap_key_file}" "${bootstrap_ssh_target}:${remote_tmp}"; then
    # shellcheck disable=SC2029
    ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    return 1
  fi

  remote_install_cmd="$(build_remote_bootstrap_install_cmd "${remote_tmp}" "${bootstrap_dest}" "${bootstrap_legacy_dest}")"

  echo "==> Injecting bootstrap nixbot key for ${node}"
  if ! ssh -tt "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_install_cmd}" <"$(resolve_ssh_tty_stdin_path)"; then
    # shellcheck disable=SC2029
    ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    return 1
  fi
}

build_remote_bootstrap_install_cmd() {
  local remote_tmp="$1"
  local bootstrap_dest="$2"
  local bootstrap_legacy_dest="$3"

  cat <<EOF
install_bootstrap_key() {
  remote_tmp='${remote_tmp}'
  bootstrap_dest='${bootstrap_dest}'
  bootstrap_legacy_dest='${bootstrap_legacy_dest}'

  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install \${bootstrap_dest}" >&2
    return 1
  fi

  sudo install -d -m 0755 ${REMOTE_NIXBOT_BASE}
  sudo install -d -m 0700 ${REMOTE_NIXBOT_SSH_DIR}
  if sudo test -f "\${bootstrap_dest}"; then
    sudo install -m 0400 "\${bootstrap_dest}" "\${bootstrap_legacy_dest}"
  fi
  sudo install -m 0400 "\${remote_tmp}" "\${bootstrap_dest}"
  rm -f "\${remote_tmp}"

  if sudo id -u nixbot >/dev/null 2>&1; then
    sudo chown -R nixbot:nixbot ${REMOTE_NIXBOT_SSH_DIR}
  fi

  return 0
}
install_bootstrap_key
EOF
}

build_remote_has_bootstrap_key_cmd() {
  local bootstrap_dest="$1"
  local expected_bootstrap_fpr="$2"

  cat <<EOF
dest='${bootstrap_dest}'
want='${expected_bootstrap_fpr}'
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to validate \${dest}" >&2
  exit 1
fi
[ "\$(sudo -n ssh-keygen -lf "\${dest}" 2>/dev/null | tr -s " " | cut -d " " -f2 || true)" = "\${want}" ]
EOF
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

  remote_has_cmd="$(cat <<EOF
dest='${remote_dest}'
want='${expected_sha}'
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required to validate \${dest}" >&2
  exit 1
fi
[ "\$(sudo -n sha256sum "\${dest}" 2>/dev/null | awk '{print \$1}' || true)" = "\${want}" ]
EOF
)"
  # shellcheck disable=SC2029
  if ssh "${ssh_opts[@]}" "${ssh_target}" "${remote_has_cmd}" >/dev/null 2>&1; then
    echo "==> Skipping host age identity for ${node}; matching key already present on target"
    return
  fi

  # shellcheck disable=SC2029
  remote_tmp="$(ssh "${ssh_opts[@]}" "${ssh_target}" "umask 077; mktemp ${REMOTE_AGE_IDENTITY_TMP_PREFIX}XXXXXX")"
  if [ -z "${remote_tmp}" ]; then
    echo "Failed to allocate remote temporary file for host age identity on ${node}" >&2
    return 1
  fi

  if ! scp "${ssh_opts[@]}" "${age_identity_key_file}" "${ssh_target}:${remote_tmp}"; then
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    return 1
  fi

  remote_install_cmd="$(cat <<EOF
install_age_identity() {
  remote_tmp='${remote_tmp}'
  remote_dest='${remote_dest}'

  if ! command -v sudo >/dev/null 2>&1; then
    echo "sudo is required to install \${remote_dest}" >&2
    return 1
  fi

  sudo install -d -m 0755 ${REMOTE_NIXBOT_BASE}
  sudo install -d -m 0700 ${REMOTE_NIXBOT_AGE_DIR}
  sudo install -m 0400 "\${remote_tmp}" "\${remote_dest}"
  sudo chown root:root "\${remote_dest}"
  rm -f "\${remote_tmp}"
  return 0
}
install_age_identity
EOF
)"

  echo "==> Injecting host age identity for ${node}"
  if ! ssh -tt "${ssh_opts[@]}" "${ssh_target}" "${remote_install_cmd}" <"$(resolve_ssh_tty_stdin_path)"; then
    # shellcheck disable=SC2029
    ssh "${ssh_opts[@]}" "${ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    return 1
  fi
}

prepare_deploy_context() {
  local node="$1"
  local target_info user host key_path known_hosts bootstrap_key bootstrap_user bootstrap_key_path age_identity_key
  local known_hosts_file key_file bootstrap_key_file build_host_host=""
  local ssh_target bootstrap_ssh_target
  local -a ssh_opts=()
  local -a bootstrap_ssh_opts=()
  local nix_sshopts=""
  local bootstrap_nix_sshopts=""

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

  if [ "${DRY_RUN}" -eq 0 ]; then
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

    ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
    nix_sshopts="-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"

    bootstrap_ssh_opts=(-o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
    bootstrap_nix_sshopts="-o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"
  fi

  if [ -n "${key_path}" ]; then
    if ! key_file="$(resolve_runtime_key_file "${key_path}" "${DEPLOY_KEY_OVERRIDE_EXPLICIT}")"; then
      return 1
    fi
    if [ ! -f "${key_file}" ]; then
      echo "Deploy SSH key file not found: ${key_path} (resolved: ${key_file})" >&2
      return 1
    fi
    ssh_opts=(-i "${key_file}" -o IdentitiesOnly=yes "${ssh_opts[@]}")
    if [ -n "${nix_sshopts}" ]; then
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes ${nix_sshopts}"
    else
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes"
    fi
  fi

  if [ -n "${bootstrap_key_path}" ]; then
    if ! bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key_path}")"; then
      return 1
    fi
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "Bootstrap SSH key file not found: ${bootstrap_key_path} (resolved: ${bootstrap_key_file})" >&2
      return 1
    fi

    if [ "${DRY_RUN}" -eq 0 ]; then
      bootstrap_ssh_opts=(-i "${bootstrap_key_file}" -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
      bootstrap_nix_sshopts="-i ${bootstrap_key_file} -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"
    else
      bootstrap_ssh_opts=(-i "${bootstrap_key_file}" -o IdentitiesOnly=yes)
      bootstrap_nix_sshopts="-i ${bootstrap_key_file} -o IdentitiesOnly=yes"
    fi
  fi

  PREP_DEPLOY_SSH_TARGET="${ssh_target}"
  PREP_DEPLOY_SSH_OPTS=("${ssh_opts[@]}")
  PREP_DEPLOY_NIX_SSHOPTS="${nix_sshopts}"
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_AGE_IDENTITY_KEY="${age_identity_key}"

  if [ "${FORCE_BOOTSTRAP_PATH}" -eq 1 ]; then
    echo "==> Forcing bootstrap path for ${node}: ${bootstrap_ssh_target}"
    PREP_DEPLOY_SSH_TARGET="${bootstrap_ssh_target}"
    PREP_DEPLOY_SSH_OPTS=("${bootstrap_ssh_opts[@]}")
    PREP_DEPLOY_NIX_SSHOPTS="${bootstrap_nix_sshopts}"
    PREP_USING_BOOTSTRAP_FALLBACK=1

    if [ -n "${bootstrap_key}" ]; then
      if is_bootstrap_ready "${node}"; then
        echo "==> Reusing bootstrap readiness for ${node} from earlier step"
      else
        inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
        mark_bootstrap_ready "${node}"
      fi
    fi
    return
  fi

  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
      if ! ssh "${ssh_opts[@]}" "${ssh_target}" "true" >/dev/null 2>&1; then
        local validated_via_forced_command=0

        if is_bootstrap_ready "${node}"; then
          echo "==> Reusing bootstrap readiness for ${node} from earlier step"
          validated_via_forced_command=1
        else
          if [ -n "${bootstrap_key}" ] && check_bootstrap_via_forced_command "${node}" "${ssh_target}" "${ssh_opts[@]}"; then
            validated_via_forced_command=1
          else
            inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
          fi
        fi

        if [ "${validated_via_forced_command}" -eq 1 ]; then
          echo "==> Primary deploy target ${ssh_target} is forced-command-only for ingress checks; using bootstrap target ${bootstrap_ssh_target} for nixos-rebuild"
        else
          echo "==> Primary deploy target ${ssh_target} is unavailable; falling back to bootstrap target ${bootstrap_ssh_target} for this run"
        fi

        PREP_DEPLOY_SSH_TARGET="${bootstrap_ssh_target}"
        PREP_DEPLOY_SSH_OPTS=("${bootstrap_ssh_opts[@]}")
        PREP_DEPLOY_NIX_SSHOPTS="${bootstrap_nix_sshopts}"
        PREP_USING_BOOTSTRAP_FALLBACK=1

        mark_bootstrap_ready "${node}"
      fi
    else
      if is_bootstrap_ready "${node}"; then
        echo "==> Reusing bootstrap readiness for ${node} from earlier step"
      else
        inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
        mark_bootstrap_ready "${node}"
      fi
    fi
  elif [ -n "${bootstrap_key}" ]; then
    inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
  fi
}

should_ask_sudo_password() {
  local deploy_user="$1"
  local using_bootstrap_fallback="$2"

  if [ "${using_bootstrap_fallback}" -eq 1 ] || { [ "${deploy_user}" != "root" ] && [ "${deploy_user}" != "nixbot" ]; }; then
    return 0
  fi

  return 1
}

snapshot_host_generation() {
  local node="$1"
  local snapshot_file="$2"
  local remote_current_path

  log_host_stage "snapshot" "${node}"
  prepare_deploy_context "${node}" || return 1
  # shellcheck disable=SC2029
  if ! remote_current_path="$(ssh "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true")"; then
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
  local -n active_jobs_ref="$1"
  local max_jobs="$2"

  if [ "${active_jobs_ref}" -ge "${max_jobs}" ]; then
    wait -n || true
    active_jobs_ref=$((active_jobs_ref - 1))
  fi
}

drain_job_slots() {
  local -n active_jobs_ref="$1"

  while [ "${active_jobs_ref}" -gt 0 ]; do
    wait -n || true
    active_jobs_ref=$((active_jobs_ref - 1))
  done
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
    printf '%s\n' "${rc}" > "${status_file}"
    exit "${rc}"
  )
}

record_build_status() {
  local node="$1"
  local status_file="$2"
  local -n built_hosts_target="$3"
  local -n failed_hosts_target="$4"
  local rc

  if [ ! -s "${status_file}" ]; then
    failed_hosts_target+=("${node}")
    return 1
  fi

  rc="$(cat "${status_file}")"
  if [ "${rc}" != "0" ]; then
    failed_hosts_target+=("${node}")
    return 1
  fi

  built_hosts_target+=("${node}")
  return 0
}

print_build_failures() {
  local build_log_dir="$1"
  local build_status_dir="$2"
  shift
  shift

  local -a failed_hosts=("$@")
  local node status_file log_file rc

  [ "${#failed_hosts[@]}" -gt 0 ] || return 0

  echo "Build phase failed for ${#failed_hosts[@]} host(s):" >&2
  for node in "${failed_hosts[@]}"; do
    status_file="${build_status_dir}/${node}.rc"
    log_file="${build_log_dir}/${node}.log"
    rc="unknown"
    if [ -s "${status_file}" ]; then
      rc="$(cat "${status_file}")"
    fi

    if [ -f "${log_file}" ]; then
      echo "  - ${node} (exit=${rc}, log=${log_file})" >&2
    else
      echo "  - ${node} (exit=${rc})" >&2
    fi
  done
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
  local built_out_path rc

  (
    set +e
    if [ ! -s "${out_file}" ]; then
      echo "Missing built output path for ${node}: ${out_file}" >&2
      rc=1
    else
      built_out_path="$(cat "${out_file}")"
      if [ -n "${log_file}" ]; then
        deploy_host "${node}" "${built_out_path}" \
          > >(host_log_filter "${node}" | tee -a "${log_file}") \
          2>&1
      elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
        deploy_host "${node}" "${built_out_path}" \
          > >(host_log_filter "${node}") \
          2>&1
      else
        deploy_host "${node}" "${built_out_path}"
      fi
      rc="$?"
    fi
    printf '%s\n' "${rc}" > "${status_file}"
    exit "${rc}"
  )
}

record_deploy_status() {
  local node="$1"
  local status_file="$2"
  local -n successful_hosts_target="$3"
  local -n deploy_failed_hosts_target="$4"
  local rc

  if [ ! -s "${status_file}" ]; then
    deploy_failed_hosts_target+=("${node}")
    return 1
  fi

  rc="$(cat "${status_file}")"
  if [ "${rc}" != "0" ]; then
    deploy_failed_hosts_target+=("${node}")
    return 1
  fi

  successful_hosts_target+=("${node}")
  return 0
}

print_host_failures() {
  local heading="$1"
  local mode="${2:-plain}"
  local log_dir="${3:-}"
  shift 3

  local -a failed_hosts=("$@")
  local node

  [ "${#failed_hosts[@]}" -gt 0 ] || return 0

  echo "${heading} for ${#failed_hosts[@]} host(s):" >&2
  for node in "${failed_hosts[@]}"; do
    case "${mode}" in
      deploy)
        echo "  - ${node} (log=${log_dir}/${node}.log)" >&2
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
  local -n snapshot_failed_hosts_target="$2"
  # shellcheck disable=SC2178
  local -n deploy_failed_hosts_target="$3"
  shift 3

  local node
  for node in "$@"; do
    [ -n "${node}" ] || continue
    if ! snapshot_exists "${snapshot_dir}/${node}.path"; then
      snapshot_failed_hosts_target+=("${node}")
      deploy_failed_hosts_target+=("${node}")
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
  local rollback_cmd deploy_user

  [ -n "${snapshot_path}" ] || {
    echo "Rollback snapshot is empty for ${node}" >&2
    return 1
  }

  log_host_stage "rollback" "${node}"
  prepare_deploy_context "${node}" || return 1
  deploy_user="${PREP_DEPLOY_SSH_TARGET%%@*}"

  # shellcheck disable=SC2016
  rollback_cmd='set -euo pipefail; snap="'"${snapshot_path}"'"; if [ ! -x "${snap}/bin/switch-to-configuration" ]; then echo "snapshot is not activatable: ${snap}" >&2; exit 1; fi; if [ "$(id -u)" -eq 0 ]; then "${snap}/bin/switch-to-configuration" switch; elif command -v sudo >/dev/null 2>&1; then sudo "${snap}/bin/switch-to-configuration" switch; else echo "sudo is required for rollback as non-root user" >&2; exit 1; fi'

  echo "${snapshot_path}" >&2
  if should_ask_sudo_password "${deploy_user}" "${PREP_USING_BOOTSTRAP_FALLBACK}"; then
    ssh -tt "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "${rollback_cmd}" <"$(resolve_ssh_tty_stdin_path)"
  else
    # shellcheck disable=SC2029
    ssh "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "${rollback_cmd}"
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
    status_file="${rollback_status_dir}/${node}.rc"
    log_file="${rollback_log_dir}/${node}.log"

    if rollback_host_to_snapshot "${node}" "$(cat "${snapshot_dir}/${node}.path")" \
      > >(host_log_filter "${node}" rollback | tee -a "${log_file}") \
      2>&1; then
      printf '0\n' > "${status_file}"
      ROLLBACK_OK_HOSTS+=("${node}")
    else
      rc="$?"
      printf '%s\n' "${rc}" > "${status_file}"
      ROLLBACK_FAILED_HOSTS+=("${node}")
      rollback_rc=1
    fi
  done

  if [ "${rollback_rc}" -ne 0 ]; then
    echo "Rollback failed for one or more hosts. Check logs under ${rollback_log_dir}" >&2
  fi

  return "${rollback_rc}"
}

deploy_host() {
  local node="$1"
  local built_out_path="$2"
  local remote_current_path
  local deploy_user build_host=""
  local -a rebuild_cmd=()

  log_host_stage "deploy" "${node}" "${GOAL}"
  prepare_deploy_context "${node}" || return 1
  inject_host_age_identity_key "${node}" "${PREP_DEPLOY_SSH_TARGET}" "${PREP_DEPLOY_AGE_IDENTITY_KEY}" "${PREP_DEPLOY_SSH_OPTS[@]}" || return 1

  deploy_user="${PREP_DEPLOY_SSH_TARGET%%@*}"

  if [ "${DEPLOY_IF_CHANGED}" -eq 1 ]; then
    # shellcheck disable=SC2029
    remote_current_path="$(ssh "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true")"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "[${node}] deploy | skip" >&2
      echo "${built_out_path}" >&2
      return 0
    fi
  fi

  case "${BUILD_HOST}" in
    local)
      if [ "${PREP_USING_BOOTSTRAP_FALLBACK}" -eq 1 ] || { [ -n "${DEPLOY_USER_OVERRIDE}" ] && [ "${PREP_DEPLOY_SSH_TARGET%%@*}" != "root" ]; }; then
        build_host="${PREP_DEPLOY_SSH_TARGET}"
      fi
      ;;
    target)
      build_host="${PREP_DEPLOY_SSH_TARGET}"
      ;;
    *)
      build_host="${BUILD_HOST}"
      ;;
  esac

  rebuild_cmd=(
    nixos-rebuild
    --flake ".#${node}"
    --target-host "${PREP_DEPLOY_SSH_TARGET}"
    --sudo
  )

  if should_ask_sudo_password "${deploy_user}" "${PREP_USING_BOOTSTRAP_FALLBACK}"; then
    rebuild_cmd+=(--ask-sudo-password)
  fi

  if [ "${PREP_USING_BOOTSTRAP_FALLBACK}" -eq 1 ]; then
    rebuild_cmd+=(--use-substitutes)
  fi

  rebuild_cmd+=("${GOAL}")

  if [ -n "${build_host}" ]; then
    rebuild_cmd+=(--build-host "${build_host}")
  fi

  if [ -n "${PREP_DEPLOY_NIX_SSHOPTS}" ]; then
    rebuild_cmd=(env "NIX_SSHOPTS=${PREP_DEPLOY_NIX_SSHOPTS}" "${rebuild_cmd[@]}")
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
  local node target_info bootstrap_key bootstrap_key_file
  local fpr=""
  local rc=0
  local -a selected_hosts=()

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  log_section "Phase: Bootstrap Key Check"
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue

    target_info="$(resolve_deploy_target "${node}")"
    bootstrap_key="$(jq -r '.bootstrapKey // empty' <<<"${target_info}")"

    if [ -z "${bootstrap_key}" ]; then
      echo "==> ${node}: no bootstrapKey configured"
      continue
    fi

    if ! bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key}")"; then
      rc=1
      continue
    fi
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "==> ${node}: bootstrap key missing: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      continue
    fi

    fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2 || true)"
    if [ -z "${fpr}" ]; then
      echo "==> ${node}: bootstrap key unreadable: ${bootstrap_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      continue
    fi

    echo "==> ${node}: bootstrap key OK (${fpr})"
  done

  return "${rc}"
}

init_run_dirs() {
  local base_dir="$1"
  local -n build_log_dir_out="$2"
  local -n build_status_dir_out="$3"
  local -n deploy_log_dir_out="$4"
  local -n deploy_status_dir_out="$5"
  local -n build_out_dir_out="$6"
  local -n snapshot_dir_out="$7"
  local -n rollback_log_dir_out="$8"
  local -n rollback_status_dir_out="$9"

  build_log_dir_out="${base_dir}/logs.build"
  build_status_dir_out="${base_dir}/status.build"
  deploy_log_dir_out="${base_dir}/logs.deploy"
  deploy_status_dir_out="${base_dir}/status.deploy"
  build_out_dir_out="${base_dir}/build-outs"
  snapshot_dir_out="${base_dir}/snapshots"
  rollback_log_dir_out="${base_dir}/logs.rollback"
  rollback_status_dir_out="${base_dir}/status.rollback"

  mkdir -p \
    "${build_log_dir_out}" \
    "${build_status_dir_out}" \
    "${deploy_log_dir_out}" \
    "${deploy_status_dir_out}" \
    "${build_out_dir_out}" \
    "${snapshot_dir_out}" \
    "${rollback_log_dir_out}" \
    "${rollback_status_dir_out}"
}

run_build_phase() {
  local build_jobs="$1"
  local build_parallel="$2"
  local prioritize_bastion="$3"
  local bastion_host="$4"
  local build_log_dir="$5"
  local build_status_dir="$6"
  local build_out_dir="$7"
  local -n build_hosts_ref="$8"
  # shellcheck disable=SC2034
  local -n built_hosts_ref="$9"
  local -n failed_hosts_ref="${10}"

  local node active_jobs=0
  local status_file out_file log_file
  local build_sync_leading_bastion=0

  log_section "Phase: Build"

  if [ "${build_parallel}" -eq 1 ] && [ "${prioritize_bastion}" -eq 1 ] \
    && [ "${#build_hosts_ref[@]}" -gt 0 ] && [ "${build_hosts_ref[0]}" = "${bastion_host}" ]; then
    build_sync_leading_bastion=1
    node="${bastion_host}"
    status_file="${build_status_dir}/${node}.rc"
    out_file="${build_out_dir}/${node}.path"
    run_build_job "${node}" "${out_file}" "${status_file}"
    record_build_status "${node}" "${status_file}" built_hosts_ref failed_hosts_ref || true
  fi

  for node in "${build_hosts_ref[@]}"; do
    [ -n "${node}" ] || continue
    if [ "${build_sync_leading_bastion}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
      continue
    fi

    status_file="${build_status_dir}/${node}.rc"
    out_file="${build_out_dir}/${node}.path"
    log_file=""
    if [ "${build_parallel}" -eq 1 ]; then
      log_file="${build_log_dir}/${node}.log"
      run_build_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
      active_jobs=$((active_jobs + 1))
      wait_for_job_slot active_jobs "${build_jobs}"
      continue
    fi

    run_build_job "${node}" "${out_file}" "${status_file}"
    if ! record_build_status "${node}" "${status_file}" built_hosts_ref failed_hosts_ref; then
      break
    fi
  done

  if [ "${build_parallel}" -eq 1 ]; then
    drain_job_slots active_jobs
    for node in "${build_hosts_ref[@]}"; do
      [ -n "${node}" ] || continue
      status_file="${build_status_dir}/${node}.rc"
      if [ "${build_sync_leading_bastion}" -eq 1 ] && [ "${node}" = "${bastion_host}" ]; then
        continue
      fi
      record_build_status "${node}" "${status_file}" built_hosts_ref failed_hosts_ref || true
    done
  fi

  if [ "${#failed_hosts_ref[@]}" -gt 0 ]; then
    print_build_failures "${build_log_dir}" "${build_status_dir}" "${failed_hosts_ref[@]}"
    return 1
  fi

  return 0
}

run_deploy_phase() {
  local deploy_parallel="$1"
  local deploy_parallel_jobs="$2"
  local snapshot_dir="$3"
  local deploy_log_dir="$4"
  local deploy_status_dir="$5"
  local build_out_dir="$6"
  local rollback_log_dir="$7"
  local rollback_status_dir="$8"
  local -n level_groups_ref="$9"
  local -n successful_hosts_ref="${10}"
  # shellcheck disable=SC2034
  local -n snapshot_failed_hosts_ref="${11}"
  local -n deploy_failed_hosts_ref="${12}"

  local level_group node active_jobs level_index=0
  local -a level_hosts=()
  local status_file out_file log_file
  local snapshot_retry_logged=0
  local deploy_wave_failed=0

  log_section "Phase: Deploy"

  for level_group in "${level_groups_ref[@]}"; do
    [ -n "${level_group}" ] || continue
    mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
    snapshot_retry_logged=0
    if log_snapshot_retry_transition "${snapshot_dir}" "${level_index}" "${level_hosts[@]}"; then
      snapshot_retry_logged=1
    fi
    if ! ensure_wave_snapshots "${snapshot_dir}" "${level_hosts[@]}"; then
      record_snapshot_failures_for_wave "${snapshot_dir}" snapshot_failed_hosts_ref deploy_failed_hosts_ref "${level_hosts[@]}"
      print_host_failures "Deploy phase failed" snapshot "" "${deploy_failed_hosts_ref[@]}"
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts_ref[@]}"
      return 1
    fi
    if [ "${snapshot_retry_logged}" -eq 1 ]; then
      log_section "Phase: Deploy"
    fi

    log_subsection "Deploy Wave: $(join_by_comma "${level_hosts[@]}")"
    deploy_wave_failed=0
    active_jobs=0

    for node in "${level_hosts[@]}"; do
      [ -n "${node}" ] || continue

      status_file="${deploy_status_dir}/${node}.rc"
      out_file="${build_out_dir}/${node}.path"
      log_file=""
      if [ "${deploy_parallel}" -eq 1 ]; then
        log_file="${deploy_log_dir}/${node}.log"
        run_deploy_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
        active_jobs=$((active_jobs + 1))
        wait_for_job_slot active_jobs "${deploy_parallel_jobs}"
        continue
      fi

      run_deploy_job "${node}" "${out_file}" "${status_file}"
      if ! record_deploy_status "${node}" "${status_file}" successful_hosts_ref deploy_failed_hosts_ref; then
        deploy_wave_failed=1
        break
      fi
    done

    if [ "${deploy_parallel}" -eq 1 ]; then
      drain_job_slots active_jobs
      for node in "${level_hosts[@]}"; do
        [ -n "${node}" ] || continue
        status_file="${deploy_status_dir}/${node}.rc"
        record_deploy_status "${node}" "${status_file}" successful_hosts_ref deploy_failed_hosts_ref || true
      done
      if [ "${#deploy_failed_hosts_ref[@]}" -gt 0 ]; then
        deploy_wave_failed=1
      fi
    fi

    if [ "${deploy_wave_failed}" -eq 1 ]; then
      if [ "${deploy_parallel}" -eq 1 ]; then
        print_host_failures "Deploy phase failed" deploy "${deploy_log_dir}" "${deploy_failed_hosts_ref[@]}"
      else
        print_host_failures "Deploy phase failed" plain "" "${deploy_failed_hosts_ref[@]}"
      fi
      maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts_ref[@]}"
      return 1
    fi

    level_index=$((level_index + 1))
  done

  return 0
}

run_hosts() {
  local selected_json="$1"
  local bastion_host="${BASTION_TRIGGER_HOST}"
  local -a selected_hosts=()
  local -a failed_hosts=()
  local -a successful_hosts=()
  local -a built_hosts=()
  local -a snapshot_failed_hosts=()
  local -a deploy_failed_hosts=()
  local -a build_hosts=()
  local -a level_groups=()

  local build_log_dir build_status_dir deploy_log_dir deploy_status_dir
  local build_out_dir snapshot_dir rollback_log_dir rollback_status_dir
  local levels_json
  local final_rc=0
  local build_parallel=0
  local deploy_parallel=0

  if [ "${ACTION}" = "check-bootstrap" ]; then
    run_bootstrap_key_checks "${selected_json}"
    return $?
  fi

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")
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

  log_section "nixbot"
  echo "Action: ${ACTION}" >&2
  print_host_block "Hosts" "${selected_hosts[@]}"
  if [ "${ACTION}" = "deploy" ]; then
    echo "Goal: ${GOAL}" >&2
    echo "Build host: ${BUILD_HOST}" >&2
  fi

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

  if [ "${ACTION}" = "build" ] || [ "${final_rc}" -ne 0 ]; then
    print_run_summary \
      "${ACTION}" \
      "${final_rc}" \
      "${#selected_hosts[@]}" \
      "${#built_hosts[@]}" \
      "${#failed_hosts[@]}" \
      0 \
      0 \
      0 \
      0 \
      0 \
      "${selected_hosts[@]}" \
      "${built_hosts[@]}" \
      "${failed_hosts[@]}"
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
    snapshot_failed_hosts \
    deploy_failed_hosts; then
    final_rc=1
  fi

  print_run_summary \
    "${ACTION}" \
    "${final_rc}" \
    "${#selected_hosts[@]}" \
    "${#built_hosts[@]}" \
    "${#failed_hosts[@]}" \
    "${#snapshot_failed_hosts[@]}" \
    "${#successful_hosts[@]}" \
    "${#deploy_failed_hosts[@]}" \
    "${#ROLLBACK_OK_HOSTS[@]}" \
    "${#ROLLBACK_FAILED_HOSTS[@]}" \
    "${selected_hosts[@]}" \
    "${built_hosts[@]}" \
    "${failed_hosts[@]}" \
    "${snapshot_failed_hosts[@]}" \
    "${successful_hosts[@]}" \
    "${deploy_failed_hosts[@]}" \
    "${ROLLBACK_OK_HOSTS[@]}" \
    "${ROLLBACK_FAILED_HOSTS[@]}"
  return "${final_rc}"
}

# Logging helpers.
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

log_section() {
  local title="$1"
  local border='=========='

  printf '\n%s %s %s\n' "${border}" "${title}" "${border}" >&2
}

log_subsection() {
  local title="$1"
  printf -- '--- %s ---\n' "${title}" >&2
}

log_host_stage() {
  local phase="$1"
  local node="$2"
  local extra="${3:-}"
  local border

  border="$(host_phase_border "${phase}")"

  printf '\n%s %s | %s %s\n' "${border}" "${node}" "${phase}" "${border}" >&2
  if [ -n "${extra}" ]; then
    printf '[%s] %s | %s\n' "${node}" "${phase}" "${extra}" >&2
  else
    printf '[%s] %s\n' "${node}" "${phase}" >&2
  fi
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
  shift 2
  local build_ok_count="$1"
  local build_failed_count="$2"
  local snapshot_failed_count="$3"
  local deploy_ok_count="$4"
  local deploy_failed_count="$5"
  local rollback_ok_count="$6"
  local rollback_failed_count="$7"
  shift 7
  local -a build_ok_hosts=("${@:1:${build_ok_count}}")
  shift "${build_ok_count}"
  local -a build_failed_hosts=("${@:1:${build_failed_count}}")
  shift "${build_failed_count}"
  local -a snapshot_failed_hosts=("${@:1:${snapshot_failed_count}}")
  shift "${snapshot_failed_count}"
  local -a deploy_ok_hosts=("${@:1:${deploy_ok_count}}")
  shift "${deploy_ok_count}"
  local -a deploy_failed_hosts=("${@:1:${deploy_failed_count}}")
  shift "${deploy_failed_count}"
  local -a rollback_ok_hosts=("${@:1:${rollback_ok_count}}")
  shift "${rollback_ok_count}"
  local -a rollback_failed_hosts=("${@:1:${rollback_failed_count}}")

  if array_contains "${node}" "${build_failed_hosts[@]}"; then
    printf '%s' 'FAIL (build)'
    return
  fi

  if [ "${action}" = "build" ]; then
    if array_contains "${node}" "${build_ok_hosts[@]}"; then
      printf '%s' 'ok'
    else
      printf '%s' 'FAIL'
    fi
    return
  fi

  if array_contains "${node}" "${rollback_failed_hosts[@]}"; then
    printf '%s' 'FAIL (rollback)'
  elif array_contains "${node}" "${snapshot_failed_hosts[@]}"; then
    printf '%s' 'FAIL (snapshot)'
  elif array_contains "${node}" "${deploy_failed_hosts[@]}"; then
    printf '%s' 'FAIL (deploy)'
  elif array_contains "${node}" "${rollback_ok_hosts[@]}"; then
    printf '%s' 'rolled back'
  elif array_contains "${node}" "${deploy_ok_hosts[@]}"; then
    printf '%s' 'ok'
  elif array_contains "${node}" "${build_ok_hosts[@]}"; then
    printf '%s' 'built'
  else
    printf '%s' 'FAIL'
  fi
}

print_run_summary() {
  local action="$1"
  local final_rc="$2"
  local selected_count="$3"
  local build_ok_count="$4"
  local build_failed_count="$5"
  local snapshot_failed_count="$6"
  local deploy_ok_count="$7"
  local deploy_failed_count="$8"
  local rollback_ok_count="$9"
  local rollback_failed_count="${10}"
  shift 10
  local -a selected_hosts=("${@:1:${selected_count}}")
  shift "${selected_count}"
  local -a build_ok_hosts=("${@:1:${build_ok_count}}")
  shift "${build_ok_count}"
  local -a build_failed_hosts=("${@:1:${build_failed_count}}")
  shift "${build_failed_count}"
  local -a snapshot_failed_hosts=("${@:1:${snapshot_failed_count}}")
  shift "${snapshot_failed_count}"
  local -a deploy_ok_hosts=("${@:1:${deploy_ok_count}}")
  shift "${deploy_ok_count}"
  local -a deploy_failed_hosts=("${@:1:${deploy_failed_count}}")
  shift "${deploy_failed_count}"
  local -a rollback_ok_hosts=("${@:1:${rollback_ok_count}}")
  shift "${rollback_ok_count}"
  local -a rollback_failed_hosts=("${@:1:${rollback_failed_count}}")
  local node status
  local -a failed_summary_hosts=()

  log_section "Phase: Summary"
  echo "Action: ${action}" >&2
  echo "Hosts:" >&2
  for node in "${selected_hosts[@]}"; do
    status="$(host_final_status \
      "${action}" \
      "${node}" \
      "${#build_ok_hosts[@]}" \
      "${#build_failed_hosts[@]}" \
      "${#snapshot_failed_hosts[@]}" \
      "${#deploy_ok_hosts[@]}" \
      "${#deploy_failed_hosts[@]}" \
      "${#rollback_ok_hosts[@]}" \
      "${#rollback_failed_hosts[@]}" \
      "${build_ok_hosts[@]}" \
      "${build_failed_hosts[@]}" \
      "${snapshot_failed_hosts[@]}" \
      "${deploy_ok_hosts[@]}" \
      "${deploy_failed_hosts[@]}" \
      "${rollback_ok_hosts[@]}" \
      "${rollback_failed_hosts[@]}")"
    echo "  - ${node}: ${status}" >&2
    if [[ "${status}" == FAIL* ]]; then
      failed_summary_hosts+=("${node}: ${status}")
    fi
  done
  if [ "${#failed_summary_hosts[@]}" -gt 0 ]; then
    printf '\n!!!!!!!!!! FAILURE !!!!!!!!!!\n' >&2
    for node in "${failed_summary_hosts[@]}"; do
      echo "  - ${node}" >&2
    done
  fi
  printf '\nResult: %s\n' "$([ "${final_rc}" -eq 0 ] && printf 'success' || printf 'failure')" >&2
}
# End logging helpers.

main() {
  local config_json="" all_hosts_json="" selected_json=""
  local -a request_args=("$@")

  init_vars
  trap cleanup EXIT

  require_cmds jq ssh scp ssh-keygen

  if [ "${#request_args[@]}" -eq 0 ] && [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    echo "Received SSH_ORIGINAL_COMMAND:"
    echo "${SSH_ORIGINAL_COMMAND}"
    read -r -a request_args <<<"${SSH_ORIGINAL_COMMAND}"
    if [ "${#request_args[@]}" -gt 0 ] && [ "${request_args[0]}" = "--" ]; then
      request_args=("${request_args[@]:1}")
    fi
    if [ "${#request_args[@]}" -gt 0 ]; then
      case "${request_args[0]}" in
        nixbot-deploy.sh|*/nixbot-deploy.sh)
          request_args=("${request_args[@]:1}")
          ;;
      esac
    fi
  fi

  parse_args "${request_args[@]}"
  if [ "${BASTION_TRIGGER}" -eq 1 ]; then
    run_bastion_trigger
    return
  fi

  ensure_repo_for_sha
  reexec_repo_script_if_needed "${request_args[@]}"

  if [ "${ACTION}" = "deploy" ] || [ "${ACTION}" = "check-bootstrap" ]; then
    require_cmds age
  fi

  if [ -f "${DEPLOY_CONFIG_PATH}" ]; then
    config_json="$(load_deploy_config_json "${DEPLOY_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  if [ "${ACTION}" = "deploy" ]; then
    require_cmds nixos-rebuild
  fi

  all_hosts_json="$(load_all_hosts_json)"
  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"
  selected_json="$(expand_selected_hosts_json "${selected_json}" "${all_hosts_json}")"
  selected_json="$(order_selected_hosts_json "${selected_json}" "${all_hosts_json}")"

  run_hosts "${selected_json}"
}

main "$@"
