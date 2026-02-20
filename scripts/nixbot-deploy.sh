#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/nixbot-deploy.sh [--hosts "host1,host2|all"] [--action build|deploy] [--goal <goal>] [--jobs <n>] [--force] [--dry] [--config <path>]

Options:
  --hosts          Comma/space-separated host list, or `all` (default: all)
  --action         build|deploy (default: deploy)
  --goal           switch|boot|test|dry-activate (default: switch, deploy only)
  --jobs           Number of hosts to process in parallel (default: 1)
  --force          Deploy even when built path matches remote /run/current-system
  --dry            Print deploy command instead of executing deploy step
  --config         SOPS YAML deploy config path (default: hosts/nixbot.yaml)

Environment:
  SOPS_AGE_KEY           Age private key used by sops to decrypt config
  DEPLOY_USER            Optional default user override
  DEPLOY_KEY             Optional key-file-path override for all hosts
  DEPLOY_SSH_KEY_FILE    Optional key-file-path override for all hosts
  DEPLOY_SSH_KEY         Optional key-content override for all hosts
  DEPLOY_SSH_KNOWN_HOSTS Optional known_hosts override for all hosts
EOF
}

vars() {
  HOSTS_RAW="all"
  ACTION="deploy"
  GOAL="switch"
  JOBS=1
  DEPLOY_IF_CHANGED=1
  DRY_RUN=0
  DEPLOY_CONFIG_PATH="hosts/nixbot.yaml"

  DEPLOY_USER_OVERRIDE="${DEPLOY_USER:-}"
  DEPLOY_KEY_PATH_OVERRIDE="${DEPLOY_KEY:-${DEPLOY_SSH_KEY_FILE:-}}"
  DEPLOY_KEY_CONTENT_OVERRIDE="${DEPLOY_SSH_KEY:-}"
  DEPLOY_KNOWN_HOSTS_OVERRIDE="${DEPLOY_SSH_KNOWN_HOSTS:-}"

  DEPLOY_DEFAULT_USER="root"
  DEPLOY_DEFAULT_KEY_CONTENT=""
  DEPLOY_DEFAULT_KNOWN_HOSTS=""
  DEPLOY_HOSTS_JSON='{}'
  DEPLOY_TMP_DIR=""
  declare -gA DEPLOY_KEY_CACHE=()
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

  if ! command -v sops >/dev/null 2>&1; then
    echo "'sops' command is required to read deploy config: ${path}" >&2
    exit 1
  fi

  sops --decrypt --output-type json "${path}"
}

init_deploy_settings() {
  local config_json="$1"

  DEPLOY_DEFAULT_USER="$(jq -r '.defaults.user // "root"' <<<"${config_json}")"
  DEPLOY_DEFAULT_KEY_CONTENT="$(jq -r '.defaults.key // ""' <<<"${config_json}")"
  DEPLOY_DEFAULT_KNOWN_HOSTS="$(jq -r '.defaults.knownHosts // ""' <<<"${config_json}")"
  DEPLOY_HOSTS_JSON="$(jq -c '.hosts // {}' <<<"${config_json}")"

  if [ -n "${DEPLOY_USER_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_USER="${DEPLOY_USER_OVERRIDE}"
  fi
  if [ -n "${DEPLOY_KEY_CONTENT_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_KEY_CONTENT="${DEPLOY_KEY_CONTENT_OVERRIDE}"
  fi
  if [ -n "${DEPLOY_KNOWN_HOSTS_OVERRIDE}" ]; then
    DEPLOY_DEFAULT_KNOWN_HOSTS="${DEPLOY_KNOWN_HOSTS_OVERRIDE}"
  fi
}

materialize_key_file() {
  local cache_key="$1"
  local key_content="$2"
  local safe_key key_path

  if [ -n "${DEPLOY_KEY_CACHE[${cache_key}]:-}" ]; then
    printf '%s\n' "${DEPLOY_KEY_CACHE[${cache_key}]}"
    return
  fi

  ensure_tmp_dir

  safe_key="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${cache_key}")"
  key_path="${DEPLOY_TMP_DIR}/${safe_key}.key"
  printf '%s\n' "${key_content}" > "${key_path}"
  chmod 600 "${key_path}"

  DEPLOY_KEY_CACHE["${cache_key}"]="${key_path}"
  printf '%s\n' "${key_path}"
}

load_all_hosts_json() {
  nix flake show --json --no-write-lock-file \
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
  out_path="$(nix build --print-out-paths ".#nixosConfigurations.${node}.config.system.build.toplevel")"
  echo "Built out path: ${out_path}" >&2
  nix path-info --closure-size --human-readable "${out_path}" >&2
  printf '%s\n' "${out_path}"
}

resolve_deploy_target() {
  local node="$1"
  local host_cfg user target key_content key_path known_hosts

  host_cfg="$(jq -c --arg h "${node}" '.[$h] // {}' <<<"${DEPLOY_HOSTS_JSON}")"

  user="$(jq -r '.user // empty' <<<"${host_cfg}")"
  target="$(jq -r '.target // empty' <<<"${host_cfg}")"
  key_content="$(jq -r '.key // empty' <<<"${host_cfg}")"
  known_hosts="$(jq -r '.knownHosts // empty' <<<"${host_cfg}")"

  if [ -z "${user}" ]; then
    user="${DEPLOY_DEFAULT_USER}"
  fi
  if [ -z "${target}" ]; then
    target="${node}"
  fi

  if [ -n "${DEPLOY_KEY_PATH_OVERRIDE}" ]; then
    key_path="${DEPLOY_KEY_PATH_OVERRIDE}"
  else
    if [ -z "${key_content}" ]; then
      key_content="${DEPLOY_DEFAULT_KEY_CONTENT}"
    fi
    if [ -n "${key_content}" ]; then
      key_path="$(materialize_key_file "${node}" "${key_content}")"
    else
      key_path=""
    fi
  fi

  if [ -z "${known_hosts}" ]; then
    known_hosts="${DEPLOY_DEFAULT_KNOWN_HOSTS}"
  fi

  printf '%s\t%s\t%s\t%s\n' "${user}" "${target}" "${key_path}" "${known_hosts}"
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
    ssh-keyscan -H "${target_host}" >> "${known_hosts_file}" 2>/dev/null || true
  fi
}

deploy_host() {
  local node="$1"
  local built_out_path="$2"
  local target_info user host key_path known_hosts known_hosts_file ssh_target remote_current_path
  local -a ssh_opts=()
  local -a rebuild_cmd=()
  local nix_sshopts=""

  target_info="$(resolve_deploy_target "${node}")"
  user="${target_info%%$'\t'*}"
  target_info="${target_info#*$'\t'}"
  host="${target_info%%$'\t'*}"
  target_info="${target_info#*$'\t'}"
  key_path="${target_info%%$'\t'*}"
  known_hosts="${target_info#*$'\t'}"

  ssh_target="${user}@${host}"

  if [ "${DRY_RUN}" -eq 0 ]; then
    known_hosts_file="$(ensure_known_hosts_file "${node}" "${known_hosts}")"
    ensure_known_host "${host}" "${known_hosts}" "${known_hosts_file}"

    ssh_opts=(-o "UserKnownHostsFile=${known_hosts_file}" -o StrictHostKeyChecking=yes)
    nix_sshopts="-o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=yes"
  fi

  if [ -n "${key_path}" ]; then
    ssh_opts=(-i "${key_path}" -o IdentitiesOnly=yes "${ssh_opts[@]}")
    if [ -n "${nix_sshopts}" ]; then
      nix_sshopts="-i ${key_path} -o IdentitiesOnly=yes ${nix_sshopts}"
    else
      nix_sshopts="-i ${key_path} -o IdentitiesOnly=yes"
    fi
  fi

  if [ "${DEPLOY_IF_CHANGED}" -eq 1 ]; then
    remote_current_path="$(ssh "${ssh_opts[@]}" "${ssh_target}" 'readlink -f /run/current-system 2>/dev/null || true')"
    if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
      echo "==> Skipping ${node}; already on ${built_out_path}"
      return
    fi
  fi

  echo "==> Deploying ${node} to ${ssh_target} (goal=${GOAL})"

  rebuild_cmd=(
    nix run nixpkgs#nixos-rebuild -- "${GOAL}"
    --flake ".#${node}"
    --build-host localhost
    --target-host "${ssh_target}"
    --sudo
  )

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

run_host() {
  local node="$1"
  local built_out_path

  built_out_path="$(build_host "${node}")"
  if [ "${ACTION}" = "deploy" ]; then
    deploy_host "${node}" "${built_out_path}"
  fi
}

run_hosts() {
  local selected_json="$1"
  local node active_jobs
  local -a selected_hosts=()
  local -a failed_hosts=()
  local -a failed_codes=()
  local log_dir status_dir log_file status_file rc

  mapfile -t selected_hosts < <(jq -r '.[]' <<<"${selected_json}")

  if [ "${JOBS}" -eq 1 ]; then
    for node in "${selected_hosts[@]}"; do
      [ -n "${node}" ] || continue
      run_host "${node}"
    done
    return
  fi

  ensure_tmp_dir
  log_dir="${DEPLOY_TMP_DIR}/logs"
  status_dir="${DEPLOY_TMP_DIR}/status"
  mkdir -p "${log_dir}" "${status_dir}"

  active_jobs=0
  for node in "${selected_hosts[@]}"; do
    [ -n "${node}" ] || continue
    log_file="${log_dir}/${node}.log"
    status_file="${status_dir}/${node}.rc"
    (
      set +e
      run_host "${node}" > >(sed -u "s/^/[${node}] /" | tee -a "${log_file}") \
        2> >(sed -u "s/^/[${node}] /" | tee -a "${log_file}" >&2)
      rc="$?"
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
    status_file="${status_dir}/${node}.rc"
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
    echo "Parallel run failed for ${#failed_hosts[@]} host(s):" >&2
    for i in "${!failed_hosts[@]}"; do
      node="${failed_hosts[$i]}"
      rc="${failed_codes[$i]}"
      echo "  - ${node} (exit=${rc}, log=${log_dir}/${node}.log)" >&2
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
    config_json="$(load_deploy_config_json "${DEPLOY_CONFIG_PATH}")"
    init_deploy_settings "${config_json}"
  fi

  all_hosts_json="$(load_all_hosts_json)"
  selected_json="$(select_hosts_json "${all_hosts_json}")"
  validate_selected_hosts "${selected_json}" "${all_hosts_json}"

  run_hosts "${selected_json}"
}

main "$@"
