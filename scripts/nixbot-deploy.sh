#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/nixbot-deploy.sh [--hosts "host1,host2|all"] [--action build|deploy] [--goal <goal>] [--build-host <local|target|host>] [--jobs <n>] [--force] [--dry] [--config <path>]

Options:
  --hosts          Comma/space-separated host list, or `all` (default: all)
  --action         build|deploy (default: deploy)
  --goal           switch|boot|test|dry-activate (default: switch, deploy only)
  --build-host     local|target|<ssh-host> (default: local)
  --jobs           Number of hosts to process in parallel (default: 1)
  --force          Deploy even when built path matches remote /run/current-system
  --dry            Print deploy command instead of executing deploy step
  --config         Nix deploy config path (default: hosts/nixbot.nix)

Environment:
  AGE_KEY_FILE           Age/SSH identity file used for decrypting *.age secrets (default: ~/.ssh/id_ed25519)
  DEPLOY_USER            Optional default user override
  DEPLOY_SSH_KEY_PATH    Optional encrypted key file path override for all hosts
  DEPLOY_SSH_KNOWN_HOSTS Optional known_hosts override for all hosts
EOF
}

vars() {
  HOSTS_RAW="all"
  ACTION="deploy"
  GOAL="switch"
  BUILD_HOST="local"
  JOBS=1
  DEPLOY_IF_CHANGED=1
  DRY_RUN=0
  DEPLOY_CONFIG_PATH="hosts/nixbot.nix"

  DEPLOY_USER_OVERRIDE="${DEPLOY_USER:-}"
  DEPLOY_KEY_PATH_OVERRIDE="${DEPLOY_SSH_KEY_PATH:-}"
  DEPLOY_KNOWN_HOSTS_OVERRIDE="${DEPLOY_SSH_KNOWN_HOSTS:-}"

  DEPLOY_DEFAULT_USER="root"
  DEPLOY_DEFAULT_KEY_PATH=""
  DEPLOY_DEFAULT_KNOWN_HOSTS=""
  DEPLOY_HOSTS_JSON='{}'
  DEPLOY_TMP_DIR=""
  DEPLOY_CONFIG_DIR=""
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --hosts)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --hosts" >&2
          usage
          exit 1
        fi
        HOSTS_RAW="${2:-}"
        shift 2
        ;;
      --hosts=*)
        HOSTS_RAW="${1#--hosts=}"
        shift
        ;;
      --action)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --action" >&2
          usage
          exit 1
        fi
        ACTION="${2:-}"
        shift 2
        ;;
      --action=*)
        ACTION="${1#--action=}"
        shift
        ;;
      --goal)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --goal" >&2
          usage
          exit 1
        fi
        GOAL="${2:-}"
        shift 2
        ;;
      --goal=*)
        GOAL="${1#--goal=}"
        shift
        ;;
      --build-host)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --build-host" >&2
          usage
          exit 1
        fi
        BUILD_HOST="${2:-}"
        shift 2
        ;;
      --build-host=*)
        BUILD_HOST="${1#--build-host=}"
        shift
        ;;
      --force)
        DEPLOY_IF_CHANGED=0
        shift
        ;;
      --jobs)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --jobs" >&2
          usage
          exit 1
        fi
        JOBS="${2:-}"
        shift 2
        ;;
      --jobs=*)
        JOBS="${1#--jobs=}"
        shift
        ;;
      --dry)
        DRY_RUN=1
        DEPLOY_IF_CHANGED=0
        shift
        ;;
      --config)
        if [ "$#" -lt 2 ]; then
          echo "Missing value for --config" >&2
          usage
          exit 1
        fi
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
        echo "Unknown argument: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [ -z "${HOSTS_RAW}" ]; then
    echo "--hosts cannot be empty" >&2
    usage
    exit 1
  fi

  case "${ACTION}" in
    build|deploy) ;;
    *)
      echo "Unsupported --action: ${ACTION}" >&2
      exit 1
      ;;
  esac

  case "${GOAL}" in
    switch|boot|test|dry-activate) ;;
    *)
      echo "Unsupported --goal: ${GOAL}" >&2
      exit 1
      ;;
  esac

  case "${BUILD_HOST}" in
    local|target) ;;
    *)
      if [ -z "${BUILD_HOST}" ]; then
        echo "Unsupported --build-host: empty value" >&2
        exit 1
      fi
      ;;
  esac

  if ! [[ "${JOBS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "Unsupported --jobs: ${JOBS} (must be a positive integer)" >&2
    exit 1
  fi
}

cleanup() {
  if [ -n "${DEPLOY_TMP_DIR}" ] && [ -d "${DEPLOY_TMP_DIR}" ]; then
    rm -rf "${DEPLOY_TMP_DIR}"
  fi
}

ensure_tmp_dir() {
  if [ -z "${DEPLOY_TMP_DIR}" ]; then
    DEPLOY_TMP_DIR="$(mktemp -d)"
  fi
}

load_deploy_config_json() {
  local path="$1"

  if [ ! -f "${path}" ]; then
    echo "Deploy config not found: ${path}" >&2
    exit 1
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "'nix' command is required to read deploy config: ${path}" >&2
    exit 1
  fi

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
    # If user is overridden but key is not, don't force the default deploy key.
    # This allows SSH agent/default identities for the overridden user.
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
  local src_path out_file age_key_file

  src_path="$(resolve_key_source_path "${key_path}")"
  if [ ! -f "${src_path}" ]; then
    printf '%s\n' "${src_path}"
    return
  fi

  if [[ "${src_path}" = *.age ]]; then
    age_key_file="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
    echo "Using decrypt identity: ${age_key_file} for ${src_path}" >&2
    if [ ! -f "${age_key_file}" ]; then
      echo "Decrypt identity file not found: ${age_key_file}" >&2
      exit 1
    fi
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
  nix flake show --json --no-write-lock-file 2>/dev/null \
    | jq -c '.nixosConfigurations | keys'
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
    echo "Unknown hosts requested: $(jq -r 'join(", ")' <<<"${invalid}")" >&2
    echo "Available hosts: $(jq -r 'join(", ")' <<<"${all_hosts_json}")" >&2
    exit 1
  fi

  if [ "$(jq 'length' <<<"${selected_json}")" -eq 0 ]; then
    echo "No hosts selected" >&2
    exit 1
  fi
}

build_host() {
  local node="$1"
  local out_path

  echo "==> Building ${node}" >&2
  if ! out_path="$(nix build --print-out-paths ".#nixosConfigurations.${node}.config.system.build.toplevel")"; then
    echo "Build failed for ${node}" >&2
    return 1
  fi
  if [ -z "${out_path}" ]; then
    echo "Build produced no output path for ${node}" >&2
    return 1
  fi
  echo "Built out path: ${out_path}" >&2
  if ! nix path-info --closure-size --human-readable "${out_path}" >&2; then
    echo "Unable to resolve closure size for ${node}: ${out_path}" >&2
    return 1
  fi
  printf '%s\n' "${out_path}"
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
  bootstrap_key_path="$(jq -r '.bootstrapKey // empty' <<<"${host_cfg}")"

  if [ -z "${user}" ]; then
    user="${DEPLOY_DEFAULT_USER}"
  fi
  if [ -z "${target}" ]; then
    target="${node}"
  fi

  if [ -z "${key_path}" ]; then
    key_path="${DEPLOY_DEFAULT_KEY_PATH}"
  fi

  if [ -z "${known_hosts}" ]; then
    known_hosts="${DEPLOY_DEFAULT_KNOWN_HOSTS}"
  fi
  if [ -z "${bootstrap_user}" ]; then
    bootstrap_user="root"
  fi
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
  if [ ! -f "${bootstrap_key_file}" ]; then
    echo "Bootstrap nixbot key not found for ${node}: ${bootstrap_nixbot_key_path} (resolved: ${bootstrap_key_file})" >&2
    exit 1
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    echo "DRY: would inject bootstrap nixbot key ${bootstrap_key_file} -> ${bootstrap_ssh_target}:${bootstrap_dest}"
    return
  fi

  expected_bootstrap_fpr="$(ssh-keygen -lf "${bootstrap_key_file}" 2>/dev/null | tr -s ' ' | cut -d ' ' -f2)"
  if [ -z "${expected_bootstrap_fpr}" ]; then
    echo "Unable to compute bootstrap key fingerprint from ${bootstrap_key_file}" >&2
    exit 1
  fi

  remote_has_key_cmd='dest="'"${bootstrap_dest}"'"; want="'"${expected_bootstrap_fpr}"'"; get_fpr() { if [ "$(id -u)" -eq 0 ]; then ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; elif command -v sudo >/dev/null 2>&1; then sudo -n ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; else ssh-keygen -lf "$dest" 2>/dev/null | tr -s " " | cut -d " " -f2; fi; }; [ "$(get_fpr || true)" = "$want" ]'
  if ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_has_key_cmd}" >/dev/null 2>&1; then
    echo "==> Skipping bootstrap nixbot key for ${node}; matching key already present on target"
    return
  fi

  remote_tmp="$(ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" 'umask 077; mktemp /tmp/nixbot-bootstrap-key.XXXXXX')"
  if [ -z "${remote_tmp}" ]; then
    echo "Failed to allocate remote temporary file for bootstrap key on ${node}" >&2
    exit 1
  fi

  scp "${bootstrap_ssh_opts[@]}" "${bootstrap_key_file}" "${bootstrap_ssh_target}:${remote_tmp}"

  remote_install_cmd='if [ "$(id -u)" -eq 0 ]; then install -d -m 0755 /var/lib/nixbot && install -d -m 0700 /var/lib/nixbot/.ssh && install -m 0400 '"${remote_tmp}"' '"${bootstrap_dest}"' && rm -f '"${remote_tmp}"' && if id -u nixbot >/dev/null 2>&1; then chown -R nixbot:nixbot /var/lib/nixbot/.ssh; fi; elif command -v sudo >/dev/null 2>&1; then sudo install -d -m 0755 /var/lib/nixbot && sudo install -d -m 0700 /var/lib/nixbot/.ssh && sudo install -m 0400 '"${remote_tmp}"' '"${bootstrap_dest}"' && rm -f '"${remote_tmp}"' && if id -u nixbot >/dev/null 2>&1; then sudo chown -R nixbot:nixbot /var/lib/nixbot/.ssh; fi; else echo "sudo is required to install '"${bootstrap_dest}"' as non-root" >&2; exit 1; fi'
  echo "==> Injecting bootstrap nixbot key for ${node}"
  if ! ssh -tt "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "${remote_install_cmd}" </dev/tty; then
    ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" "rm -f '${remote_tmp}'" >/dev/null 2>&1 || true
    exit 1
  fi
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
  local target_host="$1"
  local known_hosts="$2"
  local known_hosts_file="$3"

  if [ -n "${known_hosts}" ]; then
    return
  fi

  if ! grep -Fq "${target_host}" "${known_hosts_file}"; then
    ssh-keyscan "${target_host}" >> "${known_hosts_file}" 2>/dev/null || true
  fi
}

deploy_host() {
  local node="$1"
  local built_out_path="$2"
  local target_info user host key_path key_file known_hosts bootstrap_nixbot_key bootstrap_user bootstrap_key_path bootstrap_key_file known_hosts_file ssh_target bootstrap_ssh_target deploy_ssh_target remote_current_path
  local build_host=""
  local -a ssh_opts=()
  local -a bootstrap_ssh_opts=()
  local -a deploy_ssh_opts=()
  local -a rebuild_cmd=()
  local nix_sshopts=""
  local bootstrap_nix_sshopts=""
  local deploy_nix_sshopts=""
  local using_bootstrap_fallback=0
  local deploy_user=""
  local need_ask_sudo_password=0

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
    key_file="$(resolve_runtime_key_file "${key_path}")"
    if [ ! -f "${key_file}" ]; then
      echo "Deploy SSH key file not found: ${key_path} (resolved: ${key_file})" >&2
      exit 1
    fi
    ssh_opts=(-i "${key_file}" -o IdentitiesOnly=yes "${ssh_opts[@]}")
    if [ -n "${nix_sshopts}" ]; then
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes ${nix_sshopts}"
    else
      nix_sshopts="-i ${key_file} -o IdentitiesOnly=yes"
    fi
  fi

  if [ -n "${bootstrap_key_path}" ]; then
    bootstrap_key_file="$(resolve_runtime_key_file "${bootstrap_key_path}")"
    if [ ! -f "${bootstrap_key_file}" ]; then
      echo "Bootstrap SSH key file not found: ${bootstrap_key_path} (resolved: ${bootstrap_key_file})" >&2
      exit 1
    fi
    if [ "${DRY_RUN}" -eq 0 ]; then
      bootstrap_ssh_opts=(-i "${bootstrap_key_file}" -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
      bootstrap_nix_sshopts="-i ${bootstrap_key_file} -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ConnectionAttempts=1 -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"
    else
      bootstrap_ssh_opts=(-i "${bootstrap_key_file}" -o IdentitiesOnly=yes)
      bootstrap_nix_sshopts="-i ${bootstrap_key_file} -o IdentitiesOnly=yes"
    fi
  fi

  deploy_ssh_target="${ssh_target}"
  deploy_ssh_opts=("${ssh_opts[@]}")
  deploy_nix_sshopts="${nix_sshopts}"
  if [ "${DRY_RUN}" -eq 0 ]; then
    if [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
      if ! ssh "${ssh_opts[@]}" "${ssh_target}" "true" >/dev/null 2>&1; then
        inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
        echo "==> Primary deploy target ${ssh_target} is unavailable; falling back to bootstrap target ${bootstrap_ssh_target} for this run"
        deploy_ssh_target="${bootstrap_ssh_target}"
        deploy_ssh_opts=("${bootstrap_ssh_opts[@]}")
        deploy_nix_sshopts="${bootstrap_nix_sshopts}"
        using_bootstrap_fallback=1
      fi
    else
      inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
    fi
  elif [ -n "${bootstrap_nixbot_key}" ]; then
    inject_bootstrap_nixbot_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_nixbot_key}" "${bootstrap_ssh_opts[@]}"
  fi

  deploy_user="${deploy_ssh_target%%@*}"
  if [ "${using_bootstrap_fallback}" -eq 1 ] || { [ "${deploy_user}" != "root" ] && [ "${deploy_user}" != "nixbot" ]; }; then
    need_ask_sudo_password=1
  fi

  if [ "${DEPLOY_IF_CHANGED}" -eq 1 ]; then
    remote_current_path="$(ssh "${deploy_ssh_opts[@]}" "${deploy_ssh_target}" 'readlink -f /run/current-system 2>/dev/null || true')"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "==> Skipping ${node}; already on ${built_out_path}"
      return
    fi
  fi

  echo "==> Deploying ${node} to ${deploy_ssh_target} (goal=${GOAL})"

  case "${BUILD_HOST}" in
    local)
      if [ "${using_bootstrap_fallback}" -eq 1 ] || { [ -n "${DEPLOY_USER_OVERRIDE}" ] && [ "${deploy_ssh_target%%@*}" != "root" ]; }; then
        build_host="${deploy_ssh_target}"
      else
        build_host=""
      fi
      ;;
    target)
      build_host="${deploy_ssh_target}"
      ;;
    *)
      build_host="${BUILD_HOST}"
      ;;
  esac

  rebuild_cmd=(
    nixos-rebuild
    --flake ".#${node}"
    --target-host "${deploy_ssh_target}"
    --sudo
  )

  if [ "${need_ask_sudo_password}" -eq 1 ]; then
    rebuild_cmd+=(--ask-sudo-password)
  fi

  if [ "${using_bootstrap_fallback}" -eq 1 ]; then
    rebuild_cmd+=(--use-substitutes)
  fi

  rebuild_cmd+=("${GOAL}")

  if [ -n "${build_host}" ]; then
    rebuild_cmd+=(--build-host "${build_host}")
  fi

  if [ -n "${deploy_nix_sshopts}" ]; then
    rebuild_cmd=(env "NIX_SSHOPTS=${deploy_nix_sshopts}" "${rebuild_cmd[@]}")
  fi

  if [ "${DRY_RUN}" -eq 1 ]; then
    printf '%q ' "${rebuild_cmd[@]}"
    echo
  else
    "${rebuild_cmd[@]}"
  fi
}

run_hosts() {
  local selected_json="$1"
  local node active_jobs
  local -a selected_hosts=()
  local -a failed_hosts=()
  local -a failed_codes=()
  local build_log_dir build_status_dir deploy_log_dir deploy_status_dir build_out_dir
  local log_file status_file out_file rc built_out_path

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")
  ensure_tmp_dir
  build_log_dir="${DEPLOY_TMP_DIR}/logs.build"
  build_status_dir="${DEPLOY_TMP_DIR}/status.build"
  deploy_log_dir="${DEPLOY_TMP_DIR}/logs.deploy"
  deploy_status_dir="${DEPLOY_TMP_DIR}/status.deploy"
  build_out_dir="${DEPLOY_TMP_DIR}/build-outs"
  mkdir -p "${build_log_dir}" "${build_status_dir}" "${deploy_log_dir}" "${deploy_status_dir}" "${build_out_dir}"

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
        built_out_path="$(
          build_host "${node}" > >(sed -u "s/^/[${node}] /" | tee -a "${log_file}") \
            2> >(sed -u "s/^/[${node}] /" | tee -a "${log_file}" >&2)
        )"
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
        node="${failed_hosts[$i]}"
        rc="${failed_codes[$i]}"
        echo "  - ${node} (exit=${rc}, log=${build_log_dir}/${node}.log)" >&2
      done
      exit 1
    fi
  fi

  if [ "${ACTION}" = "build" ]; then
    return
  fi

  failed_hosts=()
  failed_codes=()

  if [ "${JOBS}" -eq 1 ]; then
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      out_file="${build_out_dir}/${node}.path"
      if [ ! -s "${out_file}" ]; then
        echo "Missing built output path for ${node}: ${out_file}" >&2
        return 1
      fi
      built_out_path="$(cat "${out_file}")"
      deploy_host "${node}" "${built_out_path}"
    done
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
    fi
  done

  if [ "${#failed_hosts[@]}" -gt 0 ]; then
    echo "Deploy phase failed for ${#failed_hosts[@]} host(s):" >&2
    for i in "${!failed_hosts[@]}"; do
      node="${failed_hosts[$i]}"
      rc="${failed_codes[$i]}"
      echo "  - ${node} (exit=${rc}, log=${deploy_log_dir}/${node}.log)" >&2
    done
    exit 1
  fi
}

main() {
  local config_json all_hosts_json selected_json

  vars
  trap cleanup EXIT
  parse_args "$@"

  if [ "${ACTION}" = "deploy" ]; then
    if ! command -v age >/dev/null 2>&1; then
      echo "'age' command is required for deploy key decryption" >&2
      exit 1
    fi
    config_json="$(load_deploy_config_json "${DEPLOY_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  all_hosts_json="$(load_all_hosts_json)"
  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"

  run_hosts "${selected_json}"
}

main "$@"
