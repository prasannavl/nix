#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Usage:
  scripts/nixbot-deploy.sh [--sha <commit>] [--hosts "host1,host2|all"] [--action build|deploy|check-bootstrap] [--goal <goal>] [--build-host <local|target|host>] [--jobs <n>] [--force] [--dry] [--no-rollback] [--ssh-key <path>] [--config <path>]

Options:
  --sha            Optional commit to checkout before running deploy workflow
  --hosts          Comma/space-separated host list, or `all` (default: all)
  --action         build|deploy|check-bootstrap (default: deploy)
  --goal           switch|boot|test|dry-activate (default: switch, deploy only)
  --build-host     local|target|<ssh-host> (default: local)
  --jobs           Number of hosts to process in parallel (default: 1)
  --force          Deploy even when built path matches remote /run/current-system
  --dry            Print deploy command instead of executing deploy step
  --no-rollback    Disable rollback of successful hosts when any deploy fails
  --ssh-key        SSH key path for deploy target auth (must be .age when explicitly set)
  --config         Nix deploy config path (default: hosts/nixbot.nix)

Environment:
  AGE_KEY_FILE                Age/SSH identity file used for decrypting *.age secrets (default: ~/.ssh/id_ed25519)
  DEPLOY_USER                 Optional default user override
  DEPLOY_SSH_KEY_PATH         Optional .age key file path override for all hosts
  DEPLOY_SSH_KNOWN_HOSTS      Optional known_hosts override for all hosts
  DEPLOY_BASTION_SSH_KEY_PATH Optional .age key file path override for forced-command bootstrap checks
  DEPLOY_REPO_URL             Repo URL used when --sha requires cloning missing checkout
  DEPLOY_REPO_PATH            Repo checkout path used for --sha workflow
USAGE
}

die() {
  echo "$*" >&2
  exit 1
}

init_vars() {
  HOSTS_RAW="all"
  ACTION="deploy"
  GOAL="switch"
  BUILD_HOST="local"
  JOBS=1
  DEPLOY_IF_CHANGED=1
  DRY_RUN=0
  ROLLBACK_ON_FAILURE=1
  DEPLOY_CONFIG_PATH="hosts/nixbot.nix"
  SHA=""

  DEPLOY_USER_OVERRIDE="${DEPLOY_USER:-}"
  DEPLOY_KEY_PATH_OVERRIDE="${DEPLOY_SSH_KEY_PATH:-}"
  DEPLOY_KNOWN_HOSTS_OVERRIDE="${DEPLOY_SSH_KNOWN_HOSTS:-}"
  DEPLOY_BASTION_KEY_PATH_OVERRIDE="${DEPLOY_BASTION_SSH_KEY_PATH:-}"
  DEPLOY_KEY_OVERRIDE_EXPLICIT=0

  if [ -n "${DEPLOY_SSH_KEY_PATH:-}" ]; then
    DEPLOY_KEY_OVERRIDE_EXPLICIT=1
  fi

  DEPLOY_DEFAULT_USER="root"
  DEPLOY_DEFAULT_KEY_PATH=""
  DEPLOY_DEFAULT_KNOWN_HOSTS=""
  DEPLOY_HOSTS_JSON='{}'

  DEPLOY_TMP_DIR=""
  DEPLOY_CONFIG_DIR=""
  BOOTSTRAP_READY_NODES=""

  REPO_BASE="/var/lib/nixbot"
  REPO_PATH="${DEPLOY_REPO_PATH:-${REPO_BASE}/nix}"
  REPO_URL="${DEPLOY_REPO_URL:-ssh://git@github.com/prasannavl/nix.git}"
  REPO_SSH_KEY_PATH="${REPO_BASE}/.ssh/id_ed25519"
  REPO_GIT_SSH_COMMAND="ssh -i ${REPO_SSH_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

  # Prepared per-node context.
  PREP_DEPLOY_SSH_TARGET=""
  PREP_DEPLOY_NIX_SSHOPTS=""
  PREP_USING_BOOTSTRAP_FALLBACK=0
  PREP_DEPLOY_SSH_OPTS=()
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
      --jobs)
        [ "$#" -ge 2 ] || die "Missing value for --jobs"
        JOBS="${2:-}"
        shift 2
        ;;
      --jobs=*)
        JOBS="${1#--jobs=}"
        shift
        ;;
      --force)
        DEPLOY_IF_CHANGED=0
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
      --config)
        [ "$#" -ge 2 ] || die "Missing value for --config"
        DEPLOY_CONFIG_PATH="${2:-}"
        shift 2
        ;;
      --config=*)
        DEPLOY_CONFIG_PATH="${1#--config=}"
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

  [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --jobs: ${JOBS} (must be a positive integer)"
  if [ -n "${SHA}" ] && ! [[ "${SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
    die "Unsupported --sha: ${SHA}"
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
    DEPLOY_TMP_DIR="$(mktemp -d /dev/shm/nixbot-deploy.XXXXXX)"
  else
    DEPLOY_TMP_DIR="$(mktemp -d)"
  fi
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

  if [ -n "${DEPLOY_REPO_PATH:-}" ]; then
    REPO_PATH="${DEPLOY_REPO_PATH}"
  elif [ -d ".git" ]; then
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

  [ -f "${REPO_PATH}/scripts/nixbot-deploy.sh" ] || die "deploy script missing in repo checkout: ${REPO_PATH}/scripts/nixbot-deploy.sh"

  cd "${REPO_PATH}"
  if [ -f "${REPO_SSH_KEY_PATH}" ]; then
    GIT_SSH_COMMAND="${REPO_GIT_SSH_COMMAND}" git fetch --prune origin
  else
    git fetch --prune origin
  fi
  git checkout --detach "${SHA}"
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
  local src_path out_file age_key_file

  src_path="$(resolve_key_source_path "${key_path}")"
  if [ ! -f "${src_path}" ]; then
    printf '%s\n' "${src_path}"
    return
  fi

  if [ "${require_age}" -eq 1 ] && [[ "${src_path}" != *.age ]]; then
    die "Provided key path must point to an .age file: ${key_path} (resolved: ${src_path})"
  fi

  if [[ "${src_path}" = *.age ]]; then
    age_key_file="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
    echo "Using decrypt identity: ${age_key_file} for ${src_path}" >&2
    [ -f "${age_key_file}" ] || die "Decrypt identity file not found: ${age_key_file}"
    ensure_tmp_dir
    out_file="$(mktemp "${DEPLOY_TMP_DIR}/key.XXXXXX")"
    age --decrypt -i "${age_key_file}" -o "${out_file}" "${src_path}"
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
    | tr ', ' '\n\n' \
    | sed '/^$/d' \
    | sort -u \
    | jq -R . \
    | jq -s .
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
  local host_cfg user target key_path known_hosts bootstrap_nixbot_key bootstrap_user bootstrap_key_path

  host_cfg="$(jq -c --arg h "${node}" '.[$h] // {}' <<<"${DEPLOY_HOSTS_JSON}")"

  user="$(jq -r '.user // empty' <<<"${host_cfg}")"
  target="$(jq -r '.target // empty' <<<"${host_cfg}")"
  key_path="$(jq -r '.key // empty' <<<"${host_cfg}")"
  known_hosts="$(jq -r '.knownHosts // empty' <<<"${host_cfg}")"
  bootstrap_nixbot_key="$(jq -r '.bootstrapNixbotKey // empty' <<<"${host_cfg}")"
  bootstrap_user="$(jq -r '.bootstrapUser // empty' <<<"${host_cfg}")"
  bootstrap_key_path="$(jq -r '.bootstrapKeyPath // .bootstrapKey // empty' <<<"${host_cfg}")"

  [ -n "${user}" ] || user="${DEPLOY_DEFAULT_USER}"
  [ -n "${target}" ] || target="${node}"
  [ -n "${key_path}" ] || key_path="${DEPLOY_DEFAULT_KEY_PATH}"
  [ -n "${known_hosts}" ] || known_hosts="${DEPLOY_DEFAULT_KNOWN_HOSTS}"
  [ -n "${bootstrap_user}" ] || bootstrap_user="root"

  jq -cn \
    --arg user "${user}" \
    --arg target "${target}" \
    --arg keyPath "${key_path}" \
    --arg knownHosts "${known_hosts}" \
    --arg bootstrapNixbotKey "${bootstrap_nixbot_key}" \
    --arg bootstrapUser "${bootstrap_user}" \
    --arg bootstrapKeyPath "${bootstrap_key_path}" \
    '{user: $user, target: $target, keyPath: $keyPath, knownHosts: $knownHosts, bootstrapNixbotKey: $bootstrapNixbotKey, bootstrapUser: $bootstrapUser, bootstrapKeyPath: $bootstrapKeyPath}'
}

build_host() {
  local node="$1"
  local out_path

  echo "==> Building ${node}" >&2
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

ensure_known_hosts_file() {
  local node="$1"
  local known_hosts="$2"
  local safe_node known_hosts_file

  ensure_tmp_dir
  safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
  known_hosts_file="${DEPLOY_TMP_DIR}/known_hosts.${safe_node}"

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
    check_key_file="$(resolve_runtime_key_file "${DEPLOY_BASTION_KEY_PATH_OVERRIDE}" 1)"
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

  if [ -n "${check_sha}" ]; then
    if check_output="$(ssh "${check_ssh_opts[@]}" -- "${ssh_target}" --sha "${check_sha}" --hosts "${node}" --action check-bootstrap --config "${remote_config_path}" 2>&1)"; then
      echo "==> Bootstrap key validated via forced command for ${node}"
      return 0
    fi
  elif check_output="$(ssh "${check_ssh_opts[@]}" -- "${ssh_target}" --hosts "${node}" --action check-bootstrap --config "${remote_config_path}" 2>&1)"; then
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
  local bootstrap_dest="/var/lib/nixbot/.ssh/bootstrap_id_ed25519"

  if [ -z "${bootstrap_nixbot_key_path}" ]; then
    return
  fi

  bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_nixbot_key_path}")"
  [ -f "${bootstrap_key_file}" ] || die "Bootstrap nixbot key not found for ${node}: ${bootstrap_nixbot_key_path} (resolved: ${bootstrap_key_file})"

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "DRY: would inject bootstrap nixbot key ${bootstrap_key_file} -> ${bootstrap_ssh_target}:${bootstrap_dest}"
    return
  fi

  expected_bootstrap_fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2)"
  [ -n "${expected_bootstrap_fpr}" ] || die "Unable to compute bootstrap key fingerprint from ${bootstrap_key_file}"

  remote_has_key_cmd='dest="'"${bootstrap_dest}"'"; want="'"${expected_bootstrap_fpr}"'"; get_fpr() { if [ "$(id -u)" -eq 0 ]; then ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; elif command -v sudo >/dev/null 2>&1; then sudo -n ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; else ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; fi; }; [ "$(get_fpr || true)" = "$want" ]'
  if ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_has_key_cmd}" >/dev/null 2>&1; then
    echo "==> Skipping bootstrap nixbot key for ${node}; matching key already present on target"
    return
  fi

  remote_tmp="$(ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" 'umask 077; mktemp /tmp/nixbot-bootstrap-key.XXXXXX')"
  [ -n "${remote_tmp}" ] || die "Failed to allocate remote temporary file for bootstrap key on ${node}"

  scp "${bootstrap_ssh_opts[@]}" "${bootstrap_key_file}" "${bootstrap_ssh_target}:${remote_tmp}"

  remote_install_cmd='if [ "$(id -u)" -eq 0 ]; then install -d -m 0755 /var/lib/nixbot && install -d -m 0700 /var/lib/nixbot/.ssh && install -m 0400 '"${remote_tmp}"' '"${bootstrap_dest}"' && rm -f '"${remote_tmp}"' && if id -u nixbot >/dev/null 2>&1; then chown -R nixbot:nixbot /var/lib/nixbot/.ssh; fi; elif command -v sudo >/dev/null 2>&1; then sudo install -d -m 0755 /var/lib/nixbot && sudo install -d -m 0700 /var/lib/nixbot/.ssh && sudo install -m 0400 '"${remote_tmp}"' '"${bootstrap_dest}"' && rm -f '"${remote_tmp}"' && if id -u nixbot >/dev/null 2>&1; then sudo chown -R nixbot:nixbot /var/lib/nixbot/.ssh; fi; else echo "sudo is required to install '"${bootstrap_dest}"' as non-root" >&2; exit 1; fi'

  echo "==> Injecting bootstrap nixbot key for ${node}"
  if ! ssh -tt "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_install_cmd}" </dev/tty; then
    ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    exit 1
  fi
}

prepare_deploy_context() {
  local node="$1"
  local target_info user host key_path known_hosts bootstrap_nixbot_key bootstrap_user bootstrap_key_path
  local known_hosts_file key_file bootstrap_key_file
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
  bootstrap_nixbot_key="$(jq -r '.bootstrapNixbotKey // empty' <<<"${target_info}")"
  bootstrap_user="$(jq -r '.bootstrapUser // empty' <<<"${target_info}")"
  bootstrap_key_path="$(jq -r '.bootstrapKeyPath // empty' <<<"${target_info}")"

  ssh_target="${user}@${host}"
  bootstrap_ssh_target="${bootstrap_user}@${host}"

  if [ "${DRY_RUN}" -eq 0 ]; then
    known_hosts_file="$(ensure_known_hosts_file "${node}" "${known_hosts}")"
    ensure_known_host "${host}" "${known_hosts}" "${known_hosts_file}"

    ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
    nix_sshopts="-o BatchMode=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"

    bootstrap_ssh_opts=(-o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
    bootstrap_nix_sshopts="-o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"
  fi

  if [ -n "${key_path}" ]; then
    key_file="$(resolve_runtime_key_file "${key_path}" "${DEPLOY_KEY_OVERRIDE_EXPLICIT}")"
    [ -f "${key_file}" ] || die "Deploy SSH key file not found: ${key_path} (resolved: ${key_file})"
    ssh_opts=(-i "${key_file}" -o IdentitiesOnly=yes "${ssh_opts[@]}")
    if [ -n "${nix_sshopts}" ]; then
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes ${nix_sshopts}"
    else
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes"
    fi
  fi

  if [ -n "${bootstrap_key_path}" ]; then
    bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key_path}")"
    [ -f "${bootstrap_key_file}" ] || die "Bootstrap SSH key file not found: ${bootstrap_key_path} (resolved: ${bootstrap_key_file})"

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

  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
      if ! ssh "${ssh_opts[@]}" "${ssh_target}" "true" >/dev/null 2>&1; then
        local validated_via_forced_command=0

        if is_bootstrap_ready "${node}"; then
          echo "==> Reusing bootstrap readiness for ${node} from earlier step"
          validated_via_forced_command=1
        else
          if [ -n "${bootstrap_nixbot_key}" ] && check_bootstrap_via_forced_command "${node}" "${ssh_target}" "${ssh_opts[@]}"; then
            validated_via_forced_command=1
          else
            inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
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
      inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
    fi
  elif [ -n "${bootstrap_nixbot_key}" ]; then
    inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
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

  prepare_deploy_context "${node}"
  remote_current_path="$(ssh "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" 'readlink -f /run/current-system 2>/dev/null || true')"

  if [ -z "${remote_current_path}" ]; then
    echo "Unable to snapshot current generation for ${node} on ${PREP_DEPLOY_SSH_TARGET}" >&2
    return 1
  fi

  printf '%s\n' "${remote_current_path}" > "${snapshot_file}"
  echo "==> Snapshot ${node}: ${remote_current_path}"
}

rollback_host_to_snapshot() {
  local node="$1"
  local snapshot_path="$2"
  local rollback_cmd deploy_user

  [ -n "${snapshot_path}" ] || {
    echo "Rollback snapshot is empty for ${node}" >&2
    return 1
  }

  prepare_deploy_context "${node}"
  deploy_user="${PREP_DEPLOY_SSH_TARGET%%@*}"

  rollback_cmd='set -euo pipefail; snap="'"${snapshot_path}"'"; if [ ! -x "${snap}/bin/switch-to-configuration" ]; then echo "snapshot is not activatable: ${snap}" >&2; exit 1; fi; if [ "$(id -u)" -eq 0 ]; then "${snap}/bin/switch-to-configuration" switch; elif command -v sudo >/dev/null 2>&1; then sudo "${snap}/bin/switch-to-configuration" switch; else echo "sudo is required for rollback as non-root user" >&2; exit 1; fi'

  echo "==> Rolling back ${node} on ${PREP_DEPLOY_SSH_TARGET} to ${snapshot_path}"
  if should_ask_sudo_password "${deploy_user}" "${PREP_USING_BOOTSTRAP_FALLBACK}"; then
    ssh -tt "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "${rollback_cmd}" </dev/tty
  else
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

  [ "${#successful_hosts[@]}" -gt 0 ] || return 0

  echo "==> Rolling back ${#successful_hosts[@]} successful host(s) to pre-deploy generations"

  for node in "${successful_hosts[@]}"; do
    status_file="${rollback_status_dir}/${node}.rc"
    log_file="${rollback_log_dir}/${node}.log"

    if rollback_host_to_snapshot "${node}" "$(cat "${snapshot_dir}/${node}.path")" > >(sed -u "s/^/[${node}] /" | tee -a "${log_file}") \
      2> >(sed -u "s/^/[${node}] /" | tee -a "${log_file}" >&2); then
      printf '0\n' > "${status_file}"
    else
      rc="$?"
      printf '%s\n' "${rc}" > "${status_file}"
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

  prepare_deploy_context "${node}"

  deploy_user="${PREP_DEPLOY_SSH_TARGET%%@*}"

  if [ "${DEPLOY_IF_CHANGED}" -eq 1 ]; then
    remote_current_path="$(ssh "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" 'readlink -f /run/current-system 2>/dev/null || true')"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "==> Skipping ${node}; already on ${built_out_path}"
      return 0
    fi
  fi

  echo "==> Deploying ${node} to ${PREP_DEPLOY_SSH_TARGET} (goal=${GOAL})"

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
  local node target_info bootstrap_nixbot_key bootstrap_key_file
  local fpr=""
  local rc=0
  local -a selected_hosts=()

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue

    target_info="$(resolve_deploy_target "${node}")"
    bootstrap_nixbot_key="$(jq -r '.bootstrapNixbotKey // empty' <<<"${target_info}")"

    if [ -z "${bootstrap_nixbot_key}" ]; then
      echo "==> ${node}: no bootstrapNixbotKey configured"
      continue
    fi

    bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_nixbot_key}")"
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "==> ${node}: bootstrap key missing: ${bootstrap_nixbot_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      continue
    fi

    fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2 || true)"
    if [ -z "${fpr}" ]; then
      echo "==> ${node}: bootstrap key unreadable: ${bootstrap_nixbot_key} (resolved: ${bootstrap_key_file})" >&2
      rc=1
      continue
    fi

    echo "==> ${node}: bootstrap key OK (${fpr})"
  done

  if [ "${rc}" -ne 0 ]; then
    exit "${rc}"
  fi
}

run_hosts() {
  local selected_json="$1"
  local node active_jobs
  local -a selected_hosts=()
  local -a failed_hosts=()
  local -a failed_codes=()
  local -a successful_hosts=()

  local build_log_dir build_status_dir deploy_log_dir deploy_status_dir
  local build_out_dir snapshot_dir rollback_log_dir rollback_status_dir
  local log_file status_file out_file rc built_out_path

  if [ "${ACTION}" = "check-bootstrap" ]; then
    run_bootstrap_key_checks "${selected_json}"
    return
  fi

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  ensure_tmp_dir
  build_log_dir="${DEPLOY_TMP_DIR}/logs.build"
  build_status_dir="${DEPLOY_TMP_DIR}/status.build"
  deploy_log_dir="${DEPLOY_TMP_DIR}/logs.deploy"
  deploy_status_dir="${DEPLOY_TMP_DIR}/status.deploy"
  build_out_dir="${DEPLOY_TMP_DIR}/build-outs"
  snapshot_dir="${DEPLOY_TMP_DIR}/snapshots"
  rollback_log_dir="${DEPLOY_TMP_DIR}/logs.rollback"
  rollback_status_dir="${DEPLOY_TMP_DIR}/status.rollback"

  mkdir -p "${build_log_dir}" "${build_status_dir}" "${deploy_log_dir}" "${deploy_status_dir}" "${build_out_dir}" "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}"

  # Build phase.
  if [ "${JOBS}" -eq 1 ]; then
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      out_file="${build_out_dir}/${node}.path"
      if ! built_out_path="$(build_host "${node}")"; then
        return 1
      fi
      printf '%s\n' "${built_out_path}" > "${out_file}"
    done
  else
    active_jobs=0
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      log_file="${build_log_dir}/${node}.log"
      status_file="${build_status_dir}/${node}.rc"
      out_file="${build_out_dir}/${node}.path"

      (
        set +e
        built_out_path="$({
          build_host "${node}";
        } > >(sed -u "s/^/[${node}] /" | tee -a "${log_file}") 2> >(sed -u "s/^/[${node}] /" | tee -a "${log_file}" >&2))"
        rc="$?"
        if [ "${rc}" = "0" ]; then
          printf '%s\n' "${built_out_path}" > "${out_file}"
        fi
        printf '%s\n' "${rc}" > "${status_file}"
        exit "${rc}"
      ) &

      active_jobs=$((active_jobs + 1))
      if [ "${active_jobs}" -ge "${JOBS}" ]; then
        wait -n || true
        active_jobs=$((active_jobs - 1))
      fi
    done

    while [ "${active_jobs}" -gt 0 ]; do
      wait -n || true
      active_jobs=$((active_jobs - 1))
    done

    for node in "${selected_hosts[@]}"; do
      status_file="${build_status_dir}/${node}.rc"
      if [ ! -s "${status_file}" ]; then
        failed_hosts+=("${node}")
        failed_codes+=("missing-status")
        continue
      fi

      rc="$(cat "${status_file}")"
      if [ "${rc}" != "0" ]; then
        failed_hosts+=("${node}")
        failed_codes+=("${rc}")
      fi
    done

    if [ "${#failed_hosts[@]}" -gt 0 ]; then
      echo "Build phase failed for ${#failed_hosts[@]} host(s):" >&2
      for i in "${!failed_hosts[@]}"; do
        echo "  - ${failed_hosts[$i]} (exit=${failed_codes[$i]}, log=${build_log_dir}/${failed_hosts[$i]}.log)" >&2
      done
      exit 1
    fi
  fi

  if [ "${ACTION}" = "build" ]; then
    return
  fi

  # Snapshot phase.
  if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ]; then
    echo "==> Recording current generations before deployment"
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      if ! snapshot_host_generation "${node}" "${snapshot_dir}/${node}.path"; then
        return 1
      fi
    done
  fi

  failed_hosts=()
  failed_codes=()
  successful_hosts=()

  # Deploy phase.
  if [ "${JOBS}" -eq 1 ]; then
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      out_file="${build_out_dir}/${node}.path"
      if [ ! -s "${out_file}" ]; then
        echo "Missing built output path for ${node}: ${out_file}" >&2
        return 1
      fi

      built_out_path="$(cat "${out_file}")"
      if deploy_host "${node}" "${built_out_path}"; then
        successful_hosts+=("${node}")
      else
        failed_hosts+=("${node}")
        failed_codes+=("$?")
        break
      fi
    done

    if [ "${#failed_hosts[@]}" -gt 0 ]; then
      echo "Deploy phase failed for ${#failed_hosts[@]} host(s):" >&2
      for i in "${!failed_hosts[@]}"; do
        echo "  - ${failed_hosts[$i]} (exit=${failed_codes[$i]})" >&2
      done
      if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
        rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts[@]}" || true
      fi
      return 1
    fi

    return
  fi

  active_jobs=0
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue

    log_file="${deploy_log_dir}/${node}.log"
    status_file="${deploy_status_dir}/${node}.rc"
    out_file="${build_out_dir}/${node}.path"

    (
      set +e
      if [ ! -s "${out_file}" ]; then
        echo "Missing built output path for ${node}: ${out_file}" >&2
        rc=1
      else
        built_out_path="$(cat "${out_file}")"
        deploy_host "${node}" "${built_out_path}" > >(sed -u "s/^/[${node}] /" | tee -a "${log_file}") \
          2> >(sed -u "s/^/[${node}] /" | tee -a "${log_file}" >&2)
        rc="$?"
      fi
      printf '%s\n' "${rc}" > "${status_file}"
      exit "${rc}"
    ) &

    active_jobs=$((active_jobs + 1))
    if [ "${active_jobs}" -ge "${JOBS}" ]; then
      wait -n || true
      active_jobs=$((active_jobs - 1))
    fi
  done

  while [ "${active_jobs}" -gt 0 ]; do
    wait -n || true
    active_jobs=$((active_jobs - 1))
  done

  for node in "${selected_hosts[@]}"; do
    status_file="${deploy_status_dir}/${node}.rc"
    if [ ! -s "${status_file}" ]; then
      failed_hosts+=("${node}")
      failed_codes+=("missing-status")
      continue
    fi

    rc="$(cat "${status_file}")"
    if [ "${rc}" != "0" ]; then
      failed_hosts+=("${node}")
      failed_codes+=("${rc}")
    else
      successful_hosts+=("${node}")
    fi
  done

  if [ "${#failed_hosts[@]}" -gt 0 ]; then
    echo "Deploy phase failed for ${#failed_hosts[@]} host(s):" >&2
    for i in "${!failed_hosts[@]}"; do
      echo "  - ${failed_hosts[$i]} (exit=${failed_codes[$i]}, log=${deploy_log_dir}/${failed_hosts[$i]}.log)" >&2
    done

    if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
      rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts[@]}" || true
    fi

    exit 1
  fi
}

main() {
  local config_json all_hosts_json selected_json
  local -a request_args=("$@")

  init_vars
  trap cleanup EXIT

  require_cmds jq ssh scp ssh-keygen

  if [ "${#request_args[@]}" -eq 0 ] && [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
    echo "Received SSH_ORIGINAL_COMMAND:"
    echo "${SSH_ORIGINAL_COMMAND}"
    read -r -a request_args <<<"${SSH_ORIGINAL_COMMAND}"
  fi

  parse_args "${request_args[@]}"
  ensure_repo_for_sha

  if [ "${ACTION}" = "deploy" ] || [ "${ACTION}" = "check-bootstrap" ]; then
    require_cmds age
    config_json="$(load_deploy_config_json "${DEPLOY_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  if [ "${ACTION}" = "deploy" ]; then
    require_cmds nixos-rebuild
  fi

  all_hosts_json="$(load_all_hosts_json)"
  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"

  run_hosts "${selected_json}"
}

main "$@"
