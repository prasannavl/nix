#!/usr/bin/env bash
set -Eeuo pipefail

vars() {
  REPO_BASE="/var/lib/nixbot"
  REPO_PATH="${REPO_BASE}/nix"
  REPO_URL="@repoUrl@"
  SSH_KEY_PATH="${REPO_BASE}/.ssh/id_ed25519"
  GIT_SSH_CMD="ssh -i ${SSH_KEY_PATH} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  DEPLOY_SCRIPT="scripts/nixbot-deploy.sh"
  DEPLOY_GOAL="switch"
  DEPLOY_CONFIG="hosts/nixbot.nix"
  ORIGINAL_COMMAND="${SSH_ORIGINAL_COMMAND:-}"

  SHA=""
  HOSTS="all"
  ACTION="build"
}

deny() {
  echo "Denied: $*" >&2
  exit 1
}

print_cmd() {
  printf '%q ' "$@"
  echo
}

parse_cli_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --sha)
        SHA="${2:-}"
        shift 2
        ;;
      --sha=*)
        SHA="${1#--sha=}"
        shift
        ;;
      --hosts)
        HOSTS="${2:-}"
        shift 2
        ;;
      --hosts=*)
        HOSTS="${1#--hosts=}"
        shift
        ;;
      --action)
        ACTION="${2:-}"
        shift 2
        ;;
      --action=*)
        ACTION="${1#--action=}"
        shift
        ;;
      *)
        deny "unsupported argument '$1'"
        ;;
    esac
  done
}

parse_request() {
  local -a args=()

  if [ -n "${ORIGINAL_COMMAND}" ]; then
    echo "Received SSH_ORIGINAL_COMMAND:"
    echo "${ORIGINAL_COMMAND}"
    read -r -a args <<<"${ORIGINAL_COMMAND}"
    parse_cli_args "${args[@]}"
    return
  fi

  if [ "$#" -gt 0 ]; then
    echo "Received CLI command:"
    print_cmd "$@"
  fi
  parse_cli_args "$@"
}

validate_request() {
  if [ -z "${SHA}" ]; then
    deny "--sha is required"
  fi

  if ! [[ "${SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
    deny "invalid --sha"
  fi

  case "${ACTION}" in
    build|deploy) ;;
    *)
      deny "invalid --action"
      ;;
  esac

  if [ "${HOSTS}" != "all" ] && ! [[ "${HOSTS}" =~ ^[A-Za-z0-9._,-]+$ ]]; then
    deny "invalid --hosts format"
  fi
}

ensure_repo() {
  mkdir -p "${REPO_BASE}"

  if [ ! -f "${SSH_KEY_PATH}" ]; then
    deny "missing SSH key: ${SSH_KEY_PATH}"
  fi

  if [ ! -e "${REPO_PATH}" ]; then
    GIT_SSH_COMMAND="${GIT_SSH_CMD}" git clone "${REPO_URL}" "${REPO_PATH}"
  fi

  if [ ! -d "${REPO_PATH}/.git" ]; then
    deny "repo path is not a git checkout: ${REPO_PATH}"
  fi

  if [ ! -f "${REPO_PATH}/${DEPLOY_SCRIPT}" ]; then
    deny "deploy script missing: ${REPO_PATH}/${DEPLOY_SCRIPT}"
  fi
}

run_deploy() {
  cd "${REPO_PATH}"
  GIT_SSH_COMMAND="${GIT_SSH_CMD}" git fetch --prune origin
  git checkout --detach "${SHA}"

  echo "Executing deploy command:"
  print_cmd nix shell nixpkgs#age nixpkgs#jq -c "${DEPLOY_SCRIPT}" --hosts "${HOSTS}" --action "${ACTION}" --goal "${DEPLOY_GOAL}" --config "${DEPLOY_CONFIG}"

  nix shell nixpkgs#age nixpkgs#jq -c "${DEPLOY_SCRIPT}" \
    --hosts "${HOSTS}" \
    --action "${ACTION}" \
    --goal "${DEPLOY_GOAL}" \
    --config "${DEPLOY_CONFIG}"
}

main() {
  vars
  parse_request "$@"
  validate_request
  ensure_repo
  run_deploy
}

main "$@"
