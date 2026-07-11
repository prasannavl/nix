#!/usr/bin/env bash
set -Eeuo pipefail

##### Nixbot Deploy #####

RUNTIME_SHELL_FLAG="${NIXBOT_IN_NIX_SHELL:-0}"
readonly NIXBOT_VERSION="2026.06.20"
readonly NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE_FALLBACK="/run/current-system/sw/bin/incus-machines-reconciler{resourceArgs}"
readonly NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE_FALLBACK="/run/current-system/sw/bin/incus-machines-settlement --timeout {timeout}{resourceArgs}"
readonly NIXBOT_SSH_KEYSCAN_TIMEOUT_SECS="${NIXBOT_SSH_KEYSCAN_TIMEOUT_SECS:-5}"
readonly NIXBOT_DEFAULT_CONFIG_PATH="hosts/nixbot.nix"

readonly -a NIXBOT_RUNTIME_INSTALLABLES=(
	nixpkgs#age
	nixpkgs#cloudflared
	nixpkgs#coreutils
	nixpkgs#git
	nixpkgs#jq
	nixpkgs#nix
	nixpkgs#openssh
	nixpkgs#opentofu
	nixpkgs#procps
)
readonly -a NIXBOT_RUNTIME_COMMANDS=(
	nix
	age
	cloudflared
	git
	jq
	nproc
	pgrep
	ssh
	scp
	ssh-keyscan
	ssh-keygen
	stty
	timeout
	tofu
)
readonly NIXBOT_SSH_ARGV_PREFIX="__nixbot_argv64"

usage() {
	cat <<'USAGE'
Usage:
  nixbot
  nixbot <deps|check-deps|version>
  nixbot --list-hosts [--group "group1,group2"] [--hosts "host1,host2|all|-host"] [--config <path>] [--no-override] [--ci-first]
  nixbot --list-groups [--config <path>] [--no-override]
  nixbot <run|deploy|build|dev-build|tf|tf-dns|tf-platform|tf-apps|tf/<project>|check-bootstrap|clear-remote-locks|clean> [--sha <commit>] [--group "group1,group2"] [--hosts "host1,host2|all|-host"] [--goal <goal>] [--build-host <local|host>] [--build-host-deploy-mode <auto|cache|local-copy>] [--build-cache-url <url>] [--build-cache-host <host>] [--build-plan-jobs <n|auto>] [--build-jobs <n>] [--build-logs] [--deploy-jobs <n>] [--verify-jobs <n>] [--clear-remote-locks <all|nixbot|podman>] [--clean <auto|all>] [--force] [--bootstrap] [--ci-first] [--dirty] [--dirty-staged] [--dry] [--no-override] [--no-rollback] [--no-verify] [--prefix-host-logs] [--log-format <auto|gh|plain>] [--user <name>] [--ssh-key <path>] [--known-hosts <contents>] [--config <path>] [--age-key-file <path>] [--discover-keys[=auto|on|off]] [--repo-url <url>] [--repo-path <path>] [--use-repo-script] [--ci-check-ssh-key-path <path>] [--ci-trigger] [--ci-host <host>] [--ci-user <user>] [--ci-ssh-key <key-content>] [--ci-known-hosts <known-hosts-content>]
  nixbot --clear-remote-locks[=all|nixbot|podman] [--group "group1,group2"] [--hosts "host1,host2|all|-host"] [--dry] [auth/config options]
  nixbot --clean[=auto|all] [--dry] [--ci-trigger] [ci/auth/config options]
  nixbot tofu <tofu-args...>

Dependency Actions:
  deps            Enter the nixbot runtime shell, verify tools, and exit.
  check-deps      Verify required commands in the current environment.
  version         Print the nixbot script version and exit.

Workflow Actions:
  run             Run the full workflow.
  deploy          Run host build and deploy.
  build           Run host build only.
  dev-build       Build hosts into repo-local result-dev/<host> GC-root links.
  tf              Run all Terraform phases.
  tf-dns          Run the DNS Terraform phase.
  tf-platform     Run the platform Terraform phase.
  tf-apps         Run the apps Terraform phase.
  tf/<project>    Run one configured Terraform project.
  check-bootstrap Run bootstrap checks.
  clear-remote-locks Remove repo-managed lock files on selected hosts.
  clean           Clean operator-machine nixbot runtime and diagnostic dirs.

Local Wrapper Action:
  tofu            Run local OpenTofu in the nixbot runtime shell.

Workflow Selection Options:
  --list-hosts     List selected hosts using the same host block as the info banner
  --list-groups    List configured nixbot groups
  --group          Deployment group(s) to target (comma/space-separated; repeatable)
  --hosts          Hosts/context to target (comma/space-separated, globs, -exclusions, or `all`; default: all)
  --sha            Commit to check out before running

Build Action Options (`run`, `deploy`, `build`):
  --build-host     local|<ssh-host> (default: local)
  --build-host-deploy-mode auto|cache|local-copy (default: auto)
  --build-cache-url Signed cache URL for remote deploy builds
  --build-cache-host Host identity that owns --build-cache-url
  --build-plan-jobs Parallel host build-plan evals (default: auto = threads/2+1)
  --build-jobs     Parallel host builds (default: 1)
  --build-logs     Pass -L/--print-build-logs to nix build

Dev Build Action Options (`dev-build`):
  --hosts          Hosts/globs to build into result-dev/<host> links; -exclusions are supported (default: all)
  --build-plan-jobs Parallel host build-plan evals (default: auto = threads/2+1)
  --build-jobs     Parallel host builds (default: 1)

Deploy Action Options (`run`, `deploy`):
  --goal           switch|boot|test|dry-activate (default: switch)
  --deploy-jobs    Parallel deploys within a dependency wave (default: 8)
  --verify-jobs    Parallel rollback snapshot work (default: 16);
                   post-deploy health checks run sequentially
  --bootstrap      Always use bootstrap SSH user/key selection
  --no-rollback    Disable rollback if any deploy fails
  --no-verify      Skip post-deploy health checks; deploy failures can still roll back
  --prefix-host-logs Always prefix host log lines

Clean Action Options (`clean` or `--clean`):
  --clean          auto|all (default: auto)
                   auto removes /dev/shm/nixbot and /var/tmp/nixbot run/diag
                   dirs older than 1 day; all removes those roots entirely.
                   With --ci-trigger, runs the same cleanup on the CI host.

Clear Remote Locks Action Options (`clear-remote-locks` or `--clear-remote-locks`):
  --clear-remote-locks all|nixbot|podman (default for bare flag: all)
                   nixbot removes nixbot runtime, SSH tty, and worktree lock
                   dirs; podman removes podman-compose lifecycle lock files
                   discovered from the current system registry.
                   --dry audits remote lock holders without mutating hosts.
                   --force also unlinks held lock files after reporting holders.

Host Workflow Ordering Options (`run`, `deploy`, `build`, `check-bootstrap`):
  --ci-first  Prioritize CI host first when the CI host is selected

Workflow Behavior Options:
  --dry            Print commands without applying changes
  --force          Bypass change-detection gates
  --dirty          Allow running from a dirty repo root (worktree = HEAD)
  --dirty-staged   Like --dirty, but overlay staged changes into the worktree
  --no-override    Skip the sibling *.override.nix config overlay
  --log-format     auto|gh|plain (default: auto)

Auth / Config Options:
  --user           Default deploy user override
  --ssh-key        SSH key path for deploy target auth (.age or private key file)
  --known-hosts    known_hosts override for all hosts
  --config         Nix deploy config path (default: hosts/nixbot.nix)
                   Per-host config supports proxyCommand for explicit SSH
                   transports such as Cloudflare Access.
  --age-key-file   Age/SSH identity used to decrypt `*.age` secrets
  --discover-keys  Fallback decrypt identity discovery (auto|on|off; default: auto)

Bootstrap/Forced-Command Options:
  --ci-check-ssh-key-path .age key override for bootstrap checks

Remote Trigger Options:
  --ci-trigger Run remotely on the CI host via SSH and exit
  --ci-host   CI host hostname/IP
  --ci-user   CI host user (default: nixbot)
  --ci-ssh-key Optional SSH private key content for CI trigger
  --ci-known-hosts Optional known_hosts content for CI trigger

Repo Options:
  --repo-url       Repo URL for cloning a managed repo root
  --repo-path      Persistent repo root for sync and per-run worktrees
  --use-repo-script Re-exec from the worktree copy of this script; disabled by
                    default for security

Environment (Workflow Selection):
  NIXBOT_GROUPS               Same as --group
  NIXBOT_HOSTS                Same as --hosts
  NIXBOT_SHA                  Same as --sha

Environment (Build Actions):
  NIXBOT_BUILD_HOST           Same as --build-host
  NIXBOT_BUILD_HOST_DEPLOY_MODE Same as --build-host-deploy-mode
  NIXBOT_BUILD_CACHE_URL      Same as --build-cache-url
  NIXBOT_BUILD_CACHE_HOST     Same as --build-cache-host
  NIXBOT_BUILD_PLAN_JOBS      Same as --build-plan-jobs (n or auto)
  NIXBOT_BUILD_PLAN_CACHE     Enable persistent build-plan cache (default: 1)
  NIXBOT_BUILD_PLAN_CACHE_DIR Persistent build-plan cache directory override
  NIXBOT_BUILD_JOBS           Same as --build-jobs
  NIXBOT_BUILD_LOGS           Same as --build-logs (bool)
  NIXBOT_BUILD_HEARTBEAT_SECS Remote build heartbeat interval; 0 disables (default: 30)
  NIXBOT_ACTIVATION_HEARTBEAT_SECS Remote deploy/rollback activation heartbeat interval; 0 disables (default: 30)

Environment (Deploy Actions):
  NIXBOT_GOAL                 Same as --goal
  NIXBOT_JOBS                 Same as --deploy-jobs
  NIXBOT_VERIFY_JOBS          Same as --verify-jobs
  NIXBOT_NO_ROLLBACK          Same as --no-rollback (bool)
  NIXBOT_NO_VERIFY            Same as --no-verify (bool)
  NIXBOT_PREFIX_HOST_LOGS     Same as --prefix-host-logs (bool)

Environment (Host Workflow Ordering):
  NIXBOT_CI_FIRST        Same as --ci-first (bool)
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
  NIXBOT_SSH_CONNECT_TIMEOUT_SECS SSH TCP/banner timeout for deploy transport
                              setup (default: 30)
  NIXBOT_CONFIG               Same as --config
  AGE_KEY_FILE                Same as --age-key-file
  NIXBOT_DISCOVER_KEYS        Same as --discover-keys (auto|on|off)

Environment (Bootstrap / Forced-Command):
  NIXBOT_BOOTSTRAP            Same as --bootstrap (bool)
  NIXBOT_CI_SSH_KEY_PATH Same as --ci-check-ssh-key-path

Environment (Remote Trigger):
  NIXBOT_CI_TRIGGER      Same as --ci-trigger (bool)
  NIXBOT_CI_HOST         Same as --ci-host
  NIXBOT_CI_USER         Same as --ci-user
  NIXBOT_CI_SSH_KEY      Same as --ci-ssh-key
  NIXBOT_CI_KNOWN_HOSTS  Same as --ci-known-hosts

Environment (Repo):
  NIXBOT_REPO_URL             Same as --repo-url
  NIXBOT_REPO_PATH            Same as --repo-path
  NIXBOT_REPO_SSH_KEY_PATHS   Colon-separated SSH key paths used for Git repo clone/fetch
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
  consistent toolchain: age, git, jq, nix, openssh, and opentofu.
  `deps` re-execs and exits after verification.
  `check-deps` only checks the current environment.

Local tofu wrapper:
  `nixbot tofu ...` runs OpenTofu locally in the same runtime shell.
  For recognized `tf/<provider>-<phase>` projects, it can auto-load backend
  and provider secrets plus decrypted `-var-file` inputs when none are set.
  GCP projects can also auto-load `GOOGLE_APPLICATION_CREDENTIALS`,
  `GCP_STATE_BUCKET`, and `GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT` from
  encrypted files under `data/secrets/globals/gcp/`.
  This mode is local-only and not supported via ci trigger.
USAGE
}

die() {
	echo "$*" >&2
	exit 1
}

##### Color #####

_NIXBOT_C_RESET=$'\033[0m'
_NIXBOT_C_RED=$'\033[31m'
_NIXBOT_C_GREEN=$'\033[32m'
_NIXBOT_C_YELLOW=$'\033[33m'
_NIXBOT_C_GRAY=$'\033[90m'

_NIXBOT_HOST_PALETTE=(
	$'\033[36m'
	$'\033[34m'
	$'\033[35m'
	$'\033[33m'
	$'\033[94m'
	$'\033[95m'
	$'\033[96m'
	$'\033[92m'
	$'\033[93m'
)

should_use_color() {
	case "${NIXBOT_FORCE_COLOR:-}" in
	1 | true | yes | on)
		return 0
		;;
	esac
	case "${NO_COLOR:-}" in
	?*)
		return 1
		;;
	esac
	case "${LOG_FORMAT:-auto}" in
	gh | github-actions)
		return 1
		;;
	auto)
		[ "${GITHUB_ACTIONS:-false}" = "true" ] && return 1
		;;
	plain | "")
		;;
	*)
		return 1
		;;
	esac
	[ -t 2 ]
}

host_color_index() {
	local node="$1" hash=2166136261 ord=0 i

	for ((i = 0; i < ${#node}; i++)); do
		printf -v ord '%d' "'${node:i:1}"
		hash=$(((hash ^ ord) * 16777619 & 0xFFFFFFFF))
	done
	printf '%s\n' "$((hash % ${#_NIXBOT_HOST_PALETTE[@]}))"
}

host_color_code() {
	local node="$1" phase="${2:-${_NIXBOT_HOST_LOG_PHASE:-}}"
	local idx

	case "${phase}" in
	rollback)
		printf '%s' "${_NIXBOT_C_GRAY}"
		;;
	*)
		idx="$(host_color_index "${node}")"
		printf '%s' "${_NIXBOT_HOST_PALETTE[idx]}"
		;;
	esac
}

colorize() {
	local code="$1" text="$2"

	if should_use_color; then
		printf '%s%s%s' "${code}" "${text}" "${_NIXBOT_C_RESET}"
	else
		printf '%s' "${text}"
	fi
}

status_color_code() {
	local status="$1"

	case "${status}" in
	FAIL*)
		printf '%s' "${_NIXBOT_C_RED}"
		;;
	ok | built)
		printf '%s' "${_NIXBOT_C_GREEN}"
		;;
	*)
		printf '%s' "${_NIXBOT_C_GRAY}"
		;;
	esac
}

summary_host_line_color_code() {
	local status="$1"

	case "${status}" in
	FAIL*)
		printf '%s' "${_NIXBOT_C_RED}"
		;;
	optional*)
		printf '%s' "${_NIXBOT_C_YELLOW}"
		;;
	rolled\ back | ok\ \(skip\) | skip)
		printf '%s' "${_NIXBOT_C_GRAY}"
		;;
	esac
}

format_summary_host_line() {
	local node="$1" status="$2" timing_suffix="$3"
	local line="" line_color="" status_text=""

	line="  - ${node}: ${status}${timing_suffix}"
	line_color="$(summary_host_line_color_code "${status}")"
	if [ -n "${line_color}" ]; then
		colorize "${line_color}" "${line}"
		return
	fi
	if [ "${status}" = "ok" ]; then
		status_text="$(colorize "${_NIXBOT_C_GREEN}" "${status}")"
		printf '  - %s: %s%s' "${node}" "${status_text}" "${timing_suffix}"
		return
	fi
	printf '%s' "${line}"
}

##### Init Vars #####

override_config_path_for() {
	local config_path="$1" repo_root="" resolved_config="" override_config=""

	case "${config_path}" in
	*.nix) ;;
	*) return 0 ;;
	esac

	if [[ "${config_path}" == /* ]]; then
		resolved_config="${config_path}"
	else
		if repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"; then
			resolved_config="${repo_root}/${config_path}"
		fi
		if [ -z "${resolved_config}" ] || [ ! -f "${resolved_config}" ]; then
			resolved_config="$(pwd -P)/${config_path}"
		fi
	fi

	override_config="${resolved_config%.nix}.override.nix"
	if [ -f "${override_config}" ]; then
		printf '%s\n' "${override_config}"
		return 0
	fi

	return 0
}

resolve_ssh_tty_stdin_path() {
	if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then
		printf '/dev/tty\n'
	else
		printf '/dev/null\n'
	fi
}

capture_initial_tty_state() {
	local tty_path="" tty_state=""

	tty_path="$(resolve_ssh_tty_stdin_path)"
	[ "${tty_path}" = "/dev/tty" ] || return 0
	if tty_state="$(stty -g <"${tty_path}" 2>/dev/null)"; then
		NIXBOT_TTY_STDIN_PATH="${tty_path}"
		NIXBOT_TTY_STTY_STATE="${tty_state}"
	fi
}

restore_initial_tty_state() {
	[ -n "${NIXBOT_TTY_STDIN_PATH}" ] || return 0
	[ -n "${NIXBOT_TTY_STTY_STATE}" ] || return 0

	stty "${NIXBOT_TTY_STTY_STATE}" <"${NIXBOT_TTY_STDIN_PATH}" 2>/dev/null || true
}

init_vars() {
	HOSTS_RAW="${NIXBOT_HOSTS:-all}"
	HOSTS_EXPLICIT=0
	[ -z "${NIXBOT_HOSTS+x}" ] || HOSTS_EXPLICIT=1
	GROUPS_RAW="${NIXBOT_GROUPS:-}"
	ACTION=""
	HOST_ACTION=""
	GOAL="${NIXBOT_GOAL:-switch}"
	BUILD_HOST="${NIXBOT_BUILD_HOST:-local}"
	BUILD_HOST_DEPLOY_MODE="${NIXBOT_BUILD_HOST_DEPLOY_MODE:-auto}"
	BUILD_CACHE_URL="${NIXBOT_BUILD_CACHE_URL:-}"
	BUILD_CACHE_HOST="${NIXBOT_BUILD_CACHE_HOST:-}"
	BUILD_PLAN_JOBS="${NIXBOT_BUILD_PLAN_JOBS:-auto}"
	BUILD_PLAN_CACHE_ENABLED="${NIXBOT_BUILD_PLAN_CACHE:-1}"
	NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY=""
	NIXBOT_BUILD_PLAN_ATTR_BASE=""
	NIXBOT_BUILD_PLAN_ATTR_SUFFIX=""
	NIXBOT_BUILD_PLAN_NIX_ARGS=()
	BUILD_JOBS="${NIXBOT_BUILD_JOBS:-1}"
	BUILD_LOGS=0
	NIXBOT_BUILD_HEARTBEAT_SECS="${NIXBOT_BUILD_HEARTBEAT_SECS:-30}"
	NIXBOT_ACTIVATION_HEARTBEAT_SECS="${NIXBOT_ACTIVATION_HEARTBEAT_SECS:-30}"
	NIXBOT_BUILD_NIX_ARGS=()
	NIXBOT_BUILD_PLAN_DIR=""
	NIXBOT_PARALLEL_JOBS="${NIXBOT_JOBS:-8}"
	NIXBOT_VERIFY_JOBS="${NIXBOT_VERIFY_JOBS:-16}"
	NIXBOT_IF_CHANGED=1
	TF_IF_CHANGED=1
	FORCE_REQUESTED=0
	ALLOW_DIRTY_REPO=0
	OVERLAY_STAGED=0
	DIRTY_STAGED_PATCH_STDIN=0
	DIRTY_STAGED_PATCH_FILE=""
	DIRTY_STAGED_BASE_SHA=""
	FORCE_BOOTSTRAP_PATH=0
	SKIP_CONFIG_OVERRIDE=0
	PRIORITIZE_CI_FIRST=0
	DRY_RUN=0
	ROLLBACK_ON_FAILURE=1
	VERIFY_AFTER_DEPLOY=1
	FORCE_PREFIX_HOST_LOGS=0
	PREFIX_HOST_LOGS_EXPLICIT=0
	LOG_FORMAT="${NIXBOT_LOG_FORMAT:-auto}"
	NIXBOT_LOCAL_SELF_TARGET_MODE="${NIXBOT_LOCAL_SELF_TARGET:-auto}"
	NIXBOT_PARENT_SETTLE_TIMEOUT="${NIXBOT_PARENT_SETTLE_TIMEOUT:-180}"
	NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT="${NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT:-45}"
	NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS="${NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS:-5}"
	NIXBOT_PARENT_READINESS_SLOW_SECS="${NIXBOT_PARENT_READINESS_SLOW_SECS:-10}"
	NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS=0
	NIXBOT_CLEAN_MODE="${NIXBOT_CLEAN:-}"
	NIXBOT_CLEAR_REMOTE_LOCKS_MODE="${NIXBOT_CLEAR_REMOTE_LOCKS:-}"
	NIXBOT_CONTROL_PERSIST_SECS="${NIXBOT_CONTROL_PERSIST_SECS:-120}"
	NIXBOT_SSH_CONNECT_TIMEOUT_SECS="${NIXBOT_SSH_CONNECT_TIMEOUT_SECS:-30}"
	NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS="${NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS:-5}"
	NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX="${NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX:-3}"
	NIXBOT_REMOTE_READ_TIMEOUT_SECS="${NIXBOT_REMOTE_READ_TIMEOUT_SECS:-20}"
	NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS="${NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS:-1200}"
	NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS="${NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS:-180}"
	NIXBOT_CANCEL_REQUESTED=0
	NIXBOT_CANCEL_LAST_SIGNAL_EPOCH=0
	NIXBOT_CANCEL_ACTIVE_DEPLOYS_SEEN=0
	NIXBOT_CANCEL_REMOTE_WAIT_DONE=0
	NIXBOT_CANCEL_EXIT_STATUS=130
	NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS=0
	NIXBOT_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	if command -v readlink >/dev/null 2>&1; then
		NIXBOT_SCRIPT_PATH="$(readlink -f "${NIXBOT_SCRIPT_PATH}" 2>/dev/null || printf '%s\n' "${NIXBOT_SCRIPT_PATH}")"
	fi
	NIXBOT_PROCESS_GROUP="$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]' || true)"
	NIXBOT_PARENT_PROCESS_GROUP="$(ps -o pgid= -p "${PPID}" 2>/dev/null | tr -d '[:space:]' || true)"
	NIXBOT_DEPLOY_STARTED=0
	NIXBOT_FORCE_CANCEL_SIGNAL_COUNT="${NIXBOT_FORCE_CANCEL_SIGNAL_COUNT:-3}"
	NIXBOT_FORCE_CANCEL_WINDOW_SECS="${NIXBOT_FORCE_CANCEL_WINDOW_SECS:-3}"
	NIXBOT_CANCEL_TERM_GRACE_SECS="${NIXBOT_CANCEL_TERM_GRACE_SECS:-2}"
	NIXBOT_REMOTE_CANCEL_GRACE_SECS="${NIXBOT_REMOTE_CANCEL_GRACE_SECS:-10}"
	NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE="${NIXBOT_PARENT_RECONCILE_TEMPLATE:-}"
	NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE="${NIXBOT_PARENT_SETTLE_TEMPLATE:-}"
	if [ -z "${NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE}" ]; then
		NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE="${NIXBOT_DEFAULT_PARENT_RECONCILE_TEMPLATE_FALLBACK}"
	fi
	if [ -z "${NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE}" ]; then
		NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE="${NIXBOT_DEFAULT_PARENT_SETTLE_TEMPLATE_FALLBACK}"
	fi
	NIXBOT_CONFIG_PATH="${NIXBOT_CONFIG:-${NIXBOT_DEFAULT_CONFIG_PATH}}"
	NIXBOT_CONFIG_OVERRIDE_PATH="${NIXBOT_CONFIG_OVERRIDE_PATH:-}"
	if [ -z "${NIXBOT_CONFIG_OVERRIDE_PATH}" ]; then
		NIXBOT_CONFIG_OVERRIDE_PATH="$(override_config_path_for "${NIXBOT_CONFIG_PATH}")"
	fi
	SHA="${NIXBOT_SHA:-}"
	CI_TRIGGER=0
	CI_TRIGGER_HOST="${NIXBOT_CI_HOST:-}"
	CI_TRIGGER_USER="${NIXBOT_CI_USER:-nixbot}"
	CI_TRIGGER_SSH_KEY="${NIXBOT_CI_SSH_KEY:-}"
	CI_TRIGGER_KNOWN_HOSTS="${NIXBOT_CI_KNOWN_HOSTS:-}"
	CI_TRIGGER_SSH_OPTS=()
	AGE_DECRYPT_IDENTITY_FILE="${AGE_KEY_FILE:-${HOME}/.ssh/id_ed25519}"
	AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=0
	[ -n "${AGE_KEY_FILE:-}" ] && AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=1
	DISCOVER_DECRYPT_KEYS_MODE="${NIXBOT_DISCOVER_KEYS:-auto}"
	REEXEC_FROM_REPO=0
	REPO_PATH_EXPLICIT=0
	NIXBOT_REPO_ROOT_LOCK_TIMEOUT="${NIXBOT_REPO_ROOT_LOCK_TIMEOUT:-60}"
	NIXBOT_STATE_LOCK_TIMEOUT="${NIXBOT_STATE_LOCK_TIMEOUT:-30}"
	NIXBOT_TRANSPORT_RETRY_ATTEMPTS="${NIXBOT_TRANSPORT_RETRY_ATTEMPTS:-3}"
	NIXBOT_TRANSPORT_RETRY_DELAY_SECS="${NIXBOT_TRANSPORT_RETRY_DELAY_SECS:-2}"
	TF_WORK_DIR="${NIXBOT_TF_DIR:-}"
	TF_CHANGE_BASE_REF=""
	_NIXBOT_LOG_GROUP_DEPTH=0
	_NIXBOT_LOG_GROUP_SCOPE=""
	_NIXBOT_HOST_LOG_PREFIX_ACTIVE=0
	_NIXBOT_HOST_LOG_PHASE=""
	NIXBOT_RUN_STARTED_EPOCH="$(date +%s)"
	NIXBOT_RUN_STARTED_AT="$(format_epoch "${NIXBOT_RUN_STARTED_EPOCH}")"

	clear_run_summary_state

	NIXBOT_USER_OVERRIDE="${NIXBOT_USER:-}"
	NIXBOT_KEY_PATH_OVERRIDE="${NIXBOT_SSH_KEY:-}"
	NIXBOT_KNOWN_HOSTS_OVERRIDE="${NIXBOT_SSH_KNOWN_HOSTS:-}"
	NIXBOT_CI_KEY_PATH_OVERRIDE="${NIXBOT_CI_SSH_KEY_PATH:-}"

	set_discover_keys_mode "${DISCOVER_DECRYPT_KEYS_MODE}"

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
	if parse_bool_env "${NIXBOT_CI_FIRST:-0}"; then
		PRIORITIZE_CI_FIRST=1
	fi
	if parse_bool_env "${NIXBOT_BOOTSTRAP:-0}"; then
		FORCE_BOOTSTRAP_PATH=1
	fi
	if parse_bool_env "${NIXBOT_BUILD_LOGS:-0}"; then
		BUILD_LOGS=1
	fi
	if parse_bool_env "${NIXBOT_DRY:-0}"; then
		enable_dry_run_mode
	fi
	if parse_bool_env "${NIXBOT_NO_ROLLBACK:-0}"; then
		ROLLBACK_ON_FAILURE=0
	fi
	if parse_bool_env "${NIXBOT_NO_VERIFY:-0}"; then
		VERIFY_AFTER_DEPLOY=0
	fi
	if [ -n "${NIXBOT_PREFIX_HOST_LOGS:-}" ]; then
		if parse_bool_env "${NIXBOT_PREFIX_HOST_LOGS}"; then
			set_prefix_host_logs_mode 1
		else
			set_prefix_host_logs_mode 0
		fi
	fi
	if parse_bool_env "${NIXBOT_CI_TRIGGER:-0}"; then
		CI_TRIGGER=1
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
	NIXBOT_GROUPS_JSON='{}'
	NIXBOT_GROUP_DEPENDENCY_EXCLUSIONS_JSON='{}'

	NIXBOT_TMP_DIR=""
	NIXBOT_DIAG_DIR="${NIXBOT_RUNTIME_DIAG_DIR:-}"
	NIXBOT_KEEP_DIAG_DIR=0
	NIXBOT_KEEP_DIAG_ON_FAILURE=0
	NIXBOT_DIAG_REPORTED=0
	NIXBOT_TTY_LOCK_DIR=""
	NIXBOT_TTY_STDIN_PATH=""
	NIXBOT_TTY_STTY_STATE=""
	NIXBOT_CONFIG_DIR=""
	# These process-local caches are read and written through line_state_* namerefs.
	# shellcheck disable=SC2034
	BOOTSTRAP_READY_NODES=""
	# shellcheck disable=SC2034
	PRIMARY_READY_NODES=""
	PREP_DEPLOY_NODE=""
	PREP_DEPLOY_SSH_TARGET=""
	PREP_DEPLOY_NIX_SSHOPTS=""
	PREP_USING_BOOTSTRAP_FALLBACK=0
	PREP_DEPLOY_AGE_IDENTITY_KEY=""
	PREP_DEPLOY_AGE_IDENTITY_FILE=""
	PREP_DEPLOY_AGE_IDENTITY_SHA=""
	PREP_DEPLOY_LOCAL_EXEC=0
	PREP_DEPLOY_SSH_OPTS=()
	PRIMARY_PROBE_LAST_OUTPUT=""
	CURRENT_HOST_ALIASES=()
	CURRENT_HOST_ADDRESSES=()
	# shellcheck disable=SC2034
	SELF_TARGET_NOTICE_KEYS=""
	ROLLBACK_OK_HOSTS=()
	ROLLBACK_FAILED_HOSTS=()
	DEPLOY_FAILED_ROLLBACK_OK_HOSTS=()
	DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS=()
	HEALTH_FAILED_HOSTS=()
	HEALTH_FAILED_ROLLBACK_OK_HOSTS=()
	HEALTH_FAILED_ROLLBACK_FAILED_HOSTS=()
	FULLY_SKIPPED_HOSTS=()
	OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=()
	OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
	OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=()

	CI_TRIGGER_KEY_PATH="data/secrets/globals/ci/nixbot-ci-ssh.key.age"
	REMOTE_NIXBOT_BASE="/var/lib/nixbot"
	REMOTE_NIXBOT_SSH_DIR="${REMOTE_NIXBOT_BASE}/.ssh"
	REMOTE_NIXBOT_AGE_DIR="${REMOTE_NIXBOT_BASE}/.age"
	REMOTE_NIXBOT_DEPLOY_SCRIPT="/run/current-system/sw/bin/nixbot"
	REMOTE_NIXBOT_PRIMARY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519"
	REMOTE_NIXBOT_LEGACY_KEY="${REMOTE_NIXBOT_SSH_DIR}/id_ed25519_legacy"
	REMOTE_NIXBOT_AUTHORIZED_KEYS="/etc/ssh/authorized_keys.d/nixbot"
	REMOTE_NIXBOT_AGE_IDENTITY="${REMOTE_NIXBOT_AGE_DIR}/identity"
	REMOTE_CURRENT_SYSTEM_PATH="/run/current-system"
	REMOTE_SYSTEM_PROFILE_PATH="/nix/var/nix/profiles/system"
	REMOTE_WRAPPER_BIN_DIR="/run/wrappers/bin"
	REMOTE_SYSTEM_BIN_DIR="/run/current-system/sw/bin"
	REMOTE_RUNTIME_PATH="${REMOTE_WRAPPER_BIN_DIR}:${REMOTE_SYSTEM_BIN_DIR}"
	REMOTE_SYSTEM_BASH="${REMOTE_SYSTEM_BIN_DIR}/bash"
	SSH_NULL_KNOWN_HOSTS_FILE="/dev/null"
	SSH_NULL_CONFIG_FILE="/dev/null"
	RUNTIME_WORK_ROOT="/dev/shm/nixbot"
	RUNTIME_WORK_FALLBACK_ROOT="${TMPDIR:-/tmp}/nixbot"
	NIXBOT_DIAG_KEEP_ROOT="/var/tmp/nixbot"
	CI_KNOWN_HOSTS_PREFIX="ci-known-hosts"
	NODE_KNOWN_HOSTS_PREFIX="known_hosts"
	REPO_KNOWN_HOSTS_PREFIX="repo-known-hosts"
	TMP_SECRETS_DIR=""
	TMP_SSH_DIR=""
	TMP_TARGET_DIR=""
	TMP_STDERR_DIR=""
	TMP_STDOUT_DIR=""
	TMP_BUILD_RESULTS_DIR=""
	TMP_BUILD_PLAN_DIR=""
	TMP_TF_ARTIFACT_DIR=""
	TMP_ACTIVE_DEPLOY_DIR=""
	TMP_DEPLOY_JOB_DIR=""
	TMP_STATE_LOCK_DIR=""
	REPO_DEPLOY_SCRIPT_REL="pkgs/tools/nixbot/nixbot.sh"
	REMOTE_BOOTSTRAP_KEY_TMP_PREFIX="bootstrap-key."
	REMOTE_AGE_IDENTITY_TMP_PREFIX="age-identity."
	TF_CLOUDFLARE_API_TOKEN_PATH="data/secrets/globals/cloudflare/api-token.key.age"
	TF_R2_ACCOUNT_ID_PATH="data/secrets/globals/cloudflare/r2-account-id.key.age"
	TF_R2_STATE_BUCKET_PATH="data/secrets/globals/cloudflare/r2-state-bucket.key.age"
	TF_R2_ACCESS_KEY_ID_PATH="data/secrets/globals/cloudflare/r2-access-key-id.key.age"
	TF_R2_SECRET_ACCESS_KEY_PATH="data/secrets/globals/cloudflare/r2-secret-access-key.key.age"
	TF_GCP_APPLICATION_CREDENTIALS_PATH="data/secrets/globals/gcp/application-default-credentials.json.age"
	TF_GCP_STATE_BUCKET_PATH="data/secrets/globals/gcp/state-bucket.key.age"
	TF_GCP_BACKEND_IMPERSONATE_SERVICE_ACCOUNT_PATH="data/secrets/globals/gcp/backend-impersonate-service-account.key.age"
	TF_SECRETS_DIR="data/secrets/globals/tf"
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
	REPO_URL="${NIXBOT_REPO_URL:-}"
	REPO_SSH_KEY_PATHS="${NIXBOT_REPO_SSH_KEY_PATHS:-${REMOTE_NIXBOT_PRIMARY_KEY}}"
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
	1 | true | TRUE | yes | YES | on | ON) return 0 ;;
	"" | 0 | false | FALSE | no | NO | off | OFF) return 1 ;;
	*) die "Unsupported boolean value: ${raw}" ;;
	esac
}

is_signal_exit_status() {
	case "${1:-}" in
	130 | 143)
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
		case "$2" in
		--*) die "Missing value for $1 before $2" ;;
		esac
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

default_auto_build_plan_jobs() {
	local threads=""

	threads="$(nproc 2>/dev/null || printf '1\n')"
	[[ "${threads}" =~ ^[1-9][0-9]*$ ]] || threads=1
	printf '%s\n' "$(((threads / 2) + 1))"
}

is_github_actions_log_mode() {
	case "${LOG_FORMAT}" in
	gh | github-actions)
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
	auto | on | off)
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

announce_age_decrypt_identity_candidates() {
	local candidate="" rendered="" first=1

	while IFS= read -r candidate; do
		[ -n "${candidate}" ] || continue
		[ -f "${candidate}" ] || continue
		if [ "${first}" -eq 1 ]; then
			rendered="${candidate}"
			first=0
		else
			rendered="${rendered}, ${candidate}"
		fi
	done < <(emit_age_decrypt_identity_candidates)

	if [ "${first}" -eq 1 ]; then
		echo "(none found)"
	else
		echo "${rendered}"
	fi
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
	dns | platform | apps)
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
	run | build | dev-build | deploy | tf | tf-dns | tf-platform | tf-apps | check-bootstrap | clear-remote-locks | clean | list-hosts | list-groups) return 0 ;;
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
	tf | tf-dns | tf-platform | tf-apps) return 0 ;;
	*)
		action_is_tf_project_only "${1:-}"
		;;
	esac
}

resolved_host_action() {
	case "${1:-}" in
	run) printf 'deploy\n' ;;
	dev-build) printf 'build\n' ;;
	clear-remote-locks) printf 'clear-remote-locks\n' ;;
	clean) printf 'clean\n' ;;
	*) printf '%s\n' "${1:-}" ;;
	esac
}

emit_normalized_hosts() {
	local raw="$1"

	printf '%s' "${raw}" |
		tr ', ' '\n' |
		awk 'NF && !seen[$0]++'
}

host_token_is_glob() {
	local token="$1"

	case "${token}" in
	*'*'* | *'?'* | *'['*) return 0 ;;
	*) return 1 ;;
	esac
}

normalize_hosts_input() {
	local raw="$1"
	if [ "${raw}" = "all" ]; then
		printf 'all\n'
		return
	fi

	emit_normalized_hosts "${raw}" | paste -sd, -
}

normalize_groups_input() {
	emit_normalized_hosts "$1" | paste -sd, -
}

append_selector_raw() {
	local -n asr_target_ref="$1"
	local value="$2"

	[ -n "${value}" ] || return 0
	if [ -n "${asr_target_ref}" ]; then
		asr_target_ref="${asr_target_ref},${value}"
	else
		asr_target_ref="${value}"
	fi
}

bash_args_to_json_array() {
	if [ "$#" -eq 0 ]; then
		printf '[]\n'
		return
	fi

	printf '%s\n' "$@" | jq -Rcn '[inputs]'
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

shell_quote_argv() {
	local arg="" sep=""

	for arg in "$@"; do
		printf '%s%q' "${sep}" "${arg}"
		sep=" "
	done
	printf '\n'
}

emit_remote_function_command() {
	local invoke_cmd="$1" remote_fn=""
	shift

	for remote_fn in "$@"; do
		case "${remote_fn}" in
		_remote_*) ;;
		*) die "Remote command helper must use _remote_ prefix: ${remote_fn}" ;;
		esac
		declare -f "${remote_fn}" || die "Missing remote command helper: ${remote_fn}"
	done
	printf '%s\n' "${invoke_cmd}"
}

decode_ssh_command_args() {
	local encoded_args="$1"

	printf '%s' "${encoded_args}" | base64 -d
}

##### Argument Parsing #####

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--list-hosts)
			ACTION="list-hosts"
			HOST_ACTION="list-hosts"
			shift
			;;
		--list-groups)
			ACTION="list-groups"
			shift
			;;
		--sha | --sha=*)
			take_optval "$@"
			SHA="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--hosts | --hosts=*)
			take_optval "$@"
			HOSTS_RAW="${OPTVAL}"
			HOSTS_EXPLICIT=1
			shift "${OPTSHIFT}"
			;;
		--group | --group=*)
			take_optval "$@"
			append_selector_raw GROUPS_RAW "${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--goal | --goal=*)
			take_optval "$@"
			GOAL="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-host | --build-host=*)
			take_optval "$@"
			BUILD_HOST="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-cache-url | --build-cache-url=*)
			take_optval "$@"
			BUILD_CACHE_URL="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-cache-host | --build-cache-host=*)
			take_optval "$@"
			BUILD_CACHE_HOST="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-host-deploy-mode | --build-host-deploy-mode=*)
			take_optval "$@"
			BUILD_HOST_DEPLOY_MODE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-plan-jobs | --build-plan-jobs=*)
			take_optval "$@"
			BUILD_PLAN_JOBS="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-jobs | --build-jobs=*)
			take_optval "$@"
			BUILD_JOBS="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--build-logs)
			BUILD_LOGS=1
			shift
			;;
		--no-build-logs)
			BUILD_LOGS=0
			shift
			;;
		--deploy-jobs | --deploy-jobs=*)
			take_optval "$@"
			NIXBOT_PARALLEL_JOBS="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--verify-jobs | --verify-jobs=*)
			take_optval "$@"
			NIXBOT_VERIFY_JOBS="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--clean)
			ACTION="clean"
			if [ "$#" -gt 1 ] && [[ "${2:-}" != --* ]]; then
				NIXBOT_CLEAN_MODE="$2"
				shift 2
			else
				NIXBOT_CLEAN_MODE="auto"
				shift
			fi
			;;
		--clean=*)
			take_optval "$@"
			ACTION="clean"
			NIXBOT_CLEAN_MODE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--clear-remote-locks)
			ACTION="clear-remote-locks"
			if [ "$#" -gt 1 ] && [[ "${2:-}" != --* ]]; then
				NIXBOT_CLEAR_REMOTE_LOCKS_MODE="$2"
				shift 2
			else
				NIXBOT_CLEAR_REMOTE_LOCKS_MODE="all"
				shift
			fi
			;;
		--clear-remote-locks=*)
			take_optval "$@"
			ACTION="clear-remote-locks"
			NIXBOT_CLEAR_REMOTE_LOCKS_MODE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--force)
			enable_force_mode
			shift
			;;
		--dirty)
			ALLOW_DIRTY_REPO=1
			shift
			;;
		--dirty-staged)
			OVERLAY_STAGED=1
			ALLOW_DIRTY_REPO=1
			shift
			;;
		--dirty-staged-patch-stdin)
			DIRTY_STAGED_PATCH_STDIN=1
			OVERLAY_STAGED=1
			ALLOW_DIRTY_REPO=1
			shift
			;;
		--dirty-staged-base | --dirty-staged-base=*)
			take_optval "$@"
			DIRTY_STAGED_BASE_SHA="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--no-override)
			SKIP_CONFIG_OVERRIDE=1
			NIXBOT_CONFIG_OVERRIDE_PATH=""
			shift
			;;
		--bootstrap)
			FORCE_BOOTSTRAP_PATH=1
			shift
			;;
		--ci-first)
			PRIORITIZE_CI_FIRST=1
			shift
			;;
		--dry)
			enable_dry_run_mode
			shift
			;;
		--no-rollback)
			ROLLBACK_ON_FAILURE=0
			shift
			;;
		--no-verify)
			VERIFY_AFTER_DEPLOY=0
			shift
			;;
		--prefix-host-logs)
			set_prefix_host_logs_mode 1
			shift
			;;
		--log-format | --log-format=*)
			take_optval "$@"
			set_log_format_mode "${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--user | --user=*)
			take_optval "$@"
			NIXBOT_USER_OVERRIDE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--ssh-key | --ssh-key=*)
			take_optval "$@"
			NIXBOT_KEY_PATH_OVERRIDE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--known-hosts | --known-hosts=*)
			take_optval "$@"
			NIXBOT_KNOWN_HOSTS_OVERRIDE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--config | --config=*)
			take_optval "$@"
			NIXBOT_CONFIG_PATH="${OPTVAL}"
			if [ "${SKIP_CONFIG_OVERRIDE}" -eq 0 ]; then
				NIXBOT_CONFIG_OVERRIDE_PATH="$(override_config_path_for "${NIXBOT_CONFIG_PATH}")"
			else
				NIXBOT_CONFIG_OVERRIDE_PATH=""
			fi
			shift "${OPTSHIFT}"
			;;
		--age-key-file | --age-key-file=*)
			take_optval "$@"
			AGE_DECRYPT_IDENTITY_FILE="${OPTVAL}"
			AGE_DECRYPT_IDENTITY_FILE_EXPLICIT=1
			shift "${OPTSHIFT}"
			;;
		--discover-keys)
			set_discover_keys_mode on
			shift
			;;
		--no-discover-keys)
			set_discover_keys_mode off
			shift
			;;
		--discover-keys=*)
			take_optval "$@"
			set_discover_keys_mode "${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--repo-url | --repo-url=*)
			take_optval "$@"
			REPO_URL="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--repo-path | --repo-path=*)
			take_optval "$@"
			REPO_ROOT="${OPTVAL}"
			REPO_PATH_EXPLICIT=1
			shift "${OPTSHIFT}"
			;;
		--use-repo-script)
			REEXEC_FROM_REPO=1
			shift
			;;
		--ci-check-ssh-key-path | --ci-check-ssh-key-path=*)
			take_optval "$@"
			NIXBOT_CI_KEY_PATH_OVERRIDE="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--ci-trigger)
			CI_TRIGGER=1
			shift
			;;
		--ci-host | --ci-host=*)
			take_optval "$@"
			CI_TRIGGER_HOST="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--ci-user | --ci-user=*)
			take_optval "$@"
			CI_TRIGGER_USER="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--ci-ssh-key | --ci-ssh-key=*)
			take_optval "$@"
			CI_TRIGGER_SSH_KEY="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		--ci-known-hosts | --ci-known-hosts=*)
			take_optval "$@"
			CI_TRIGGER_KNOWN_HOSTS="${OPTVAL}"
			shift "${OPTSHIFT}"
			;;
		-h | --help)
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
	if [ -n "${GROUPS_RAW}" ] && [ -z "$(normalize_groups_input "${GROUPS_RAW}")" ]; then
		die "--group cannot be empty"
	fi

	action_is_supported "${ACTION}" || die "Unsupported action: ${ACTION}"
	normalize_host_action
	if [ "${ACTION}" = "clean" ] && [ -z "${NIXBOT_CLEAN_MODE}" ]; then
		NIXBOT_CLEAN_MODE="auto"
	fi
	case "${NIXBOT_CLEAN_MODE}" in
	"" | auto | all) ;;
	*) die "Unsupported --clean: ${NIXBOT_CLEAN_MODE}" ;;
	esac
	if [ "${ACTION}" = "clear-remote-locks" ] && [ -z "${NIXBOT_CLEAR_REMOTE_LOCKS_MODE}" ]; then
		NIXBOT_CLEAR_REMOTE_LOCKS_MODE="all"
	fi
	case "${NIXBOT_CLEAR_REMOTE_LOCKS_MODE}" in
	"" | all | nixbot | podman) ;;
	*) die "Unsupported --clear-remote-locks: ${NIXBOT_CLEAR_REMOTE_LOCKS_MODE}" ;;
	esac

	case "${GOAL}" in
	switch | boot | test | dry-activate) ;;
	*) die "Unsupported --goal: ${GOAL}" ;;
	esac

	case "${BUILD_HOST}" in
	local) ;;
	"") die "Unsupported --build-host: empty value" ;;
	*) ;;
	esac
	case "${BUILD_HOST_DEPLOY_MODE}" in
	auto | cache | local-copy) ;;
	*) die "Unsupported --build-host-deploy-mode: ${BUILD_HOST_DEPLOY_MODE}" ;;
	esac

	[[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --build-jobs: ${BUILD_JOBS} (must be a positive integer)"
	if [ "${BUILD_PLAN_JOBS}" = "auto" ]; then
		BUILD_PLAN_JOBS="$(default_auto_build_plan_jobs)"
	fi
	[[ "${BUILD_PLAN_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --build-plan-jobs: ${BUILD_PLAN_JOBS} (must be a positive integer or auto)"
	case "${BUILD_PLAN_CACHE_ENABLED}" in
	1 | true | TRUE | yes | YES | on | ON | "" | 0 | false | FALSE | no | NO | off | OFF) ;;
	*) die "Unsupported NIXBOT_BUILD_PLAN_CACHE: ${BUILD_PLAN_CACHE_ENABLED}" ;;
	esac
	[[ "${NIXBOT_BUILD_HEARTBEAT_SECS}" =~ ^[0-9]+$ ]] || die "Unsupported NIXBOT_BUILD_HEARTBEAT_SECS: ${NIXBOT_BUILD_HEARTBEAT_SECS} (must be a non-negative integer)"
	[[ "${NIXBOT_ACTIVATION_HEARTBEAT_SECS}" =~ ^[0-9]+$ ]] || die "Unsupported NIXBOT_ACTIVATION_HEARTBEAT_SECS: ${NIXBOT_ACTIVATION_HEARTBEAT_SECS} (must be a non-negative integer)"
	[[ "${NIXBOT_PARALLEL_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --deploy-jobs: ${NIXBOT_PARALLEL_JOBS} (must be a positive integer)"
	[[ "${NIXBOT_VERIFY_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported --verify-jobs: ${NIXBOT_VERIFY_JOBS} (must be a positive integer)"
	[[ "${NIXBOT_PARENT_READINESS_SLOW_SECS}" =~ ^[0-9]+$ ]] || die "Unsupported NIXBOT_PARENT_READINESS_SLOW_SECS: ${NIXBOT_PARENT_READINESS_SLOW_SECS} (must be a non-negative integer)"
	[[ "${NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS: ${NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS} (must be a positive integer)"
	[[ "${NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS}" =~ ^[1-9][0-9]*$ ]] || die "Unsupported NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS: ${NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS} (must be a positive integer)"
	case "${LOG_FORMAT}" in
	auto | gh | github-actions | plain) ;;
	*) die "Unsupported --log-format: ${LOG_FORMAT}" ;;
	esac
	if [ "${PREFIX_HOST_LOGS_EXPLICIT}" -eq 0 ] && { [ "${BUILD_PLAN_JOBS}" -gt 1 ] || [ "${BUILD_JOBS}" -gt 1 ] || [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ] || [ "${NIXBOT_VERIFY_JOBS}" -gt 1 ]; }; then
		FORCE_PREFIX_HOST_LOGS=1
	fi
	if [ -n "${SHA}" ] && ! [[ "${SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
		die "Unsupported --sha: ${SHA}"
	fi
	if [ -n "${DIRTY_STAGED_BASE_SHA}" ] && ! [[ "${DIRTY_STAGED_BASE_SHA}" =~ ^[0-9a-f]{7,40}$ ]]; then
		die "Unsupported --dirty-staged base: ${DIRTY_STAGED_BASE_SHA}"
	fi

	if [ "${CI_TRIGGER}" -eq 1 ]; then
		[ -n "${CI_TRIGGER_USER}" ] || die "--ci-user value is required"
	fi
	if [ "${ACTION}" = "dev-build" ] && [ -n "${SHA}" ]; then
		die "dev-build uses the current local checkout; --sha is unsupported"
	fi
}

cleanup_core() {
	local cleanup_rc="$1"

	terminate_background_jobs || true
	restore_initial_tty_state || true
	log_group_end_all || true
	cleanup_repo_worktree || true
	if [ -n "${REPO_ROOT_LOCK_DIR}" ]; then
		release_repo_root_lock || true
	fi
	if [ "${cleanup_rc}" -ne 0 ] && [ "${NIXBOT_KEEP_DIAG_ON_FAILURE:-0}" -eq 1 ]; then
		NIXBOT_KEEP_DIAG_DIR=1
	fi
	if [ "${NIXBOT_KEEP_DIAG_DIR:-0}" -eq 1 ]; then
		keep_diag_dir || true
	else
		[ -n "${NIXBOT_DIAG_DIR:-}" ] && rm -rf "${NIXBOT_DIAG_DIR}"
	fi
	if [ -n "${RUNTIME_WORK_DIR}" ] && [ -d "${RUNTIME_WORK_DIR}" ]; then
		rm -rf "${RUNTIME_WORK_DIR}"
	fi
	rmdir "${RUNTIME_WORK_ROOT}" "${RUNTIME_WORK_FALLBACK_ROOT}" "${NIXBOT_DIAG_KEEP_ROOT}" 2>/dev/null || true
	restore_initial_tty_state || true
}

cleanup() {
	local cleanup_rc="$?" shell_opts="$-"

	case "${shell_opts}" in
	*e*)
		set +e
		;;
	esac
	cleanup_core "${cleanup_rc}"
	case "${shell_opts}" in
	*e*)
		set -e
		;;
	esac
}

cleanup_trap() {
	local cleanup_rc="$?"

	set +e
	trap - HUP INT TERM EXIT
	cleanup_core "${cleanup_rc}"
}

request_hangup() {
	echo "nixbot: received SIGHUP; cleaning up local run" >&2
	NIXBOT_KEEP_DIAG_DIR=1
	terminate_background_jobs
	exit 129
}

request_cancel() {
	local exit_status="$1" signal_name="$2"
	local now_epoch=0 last_signal_epoch=0 remaining_signals=0

	NIXBOT_CANCEL_EXIT_STATUS="${exit_status}"
	NIXBOT_KEEP_DIAG_DIR=1
	now_epoch="$(date +%s)"
	last_signal_epoch="${NIXBOT_CANCEL_LAST_SIGNAL_EPOCH:-0}"
	if [ "${last_signal_epoch}" -gt 0 ] &&
		[ $((now_epoch - last_signal_epoch)) -le "${NIXBOT_FORCE_CANCEL_WINDOW_SECS}" ]; then
		NIXBOT_CANCEL_REQUESTED=$((NIXBOT_CANCEL_REQUESTED + 1))
	else
		NIXBOT_CANCEL_REQUESTED=1
	fi
	NIXBOT_CANCEL_LAST_SIGNAL_EPOCH="${now_epoch}"

	if [ "${NIXBOT_CANCEL_REQUESTED}" -eq 1 ]; then
		if active_deploy_jobs_running; then
			NIXBOT_CANCEL_ACTIVE_DEPLOYS_SEEN=1
			echo "nixbot: received ${signal_name}; waiting for active deploy jobs to finish" >&2
			return 0
		fi
		if deploy_jobs_started; then
			echo "nixbot: received ${signal_name}; no active remote deploy remains, canceling local jobs" >&2
		else
			echo "nixbot: received ${signal_name}; no deploy job has started, canceling local jobs" >&2
		fi
		terminate_background_jobs
		exit "${exit_status}"
	fi

	if ! force_cancel_requested; then
		remaining_signals=$((NIXBOT_FORCE_CANCEL_SIGNAL_COUNT - NIXBOT_CANCEL_REQUESTED))
		echo "nixbot: received ${signal_name} again; press Ctrl-C ${remaining_signals} more time(s) within ${NIXBOT_FORCE_CANCEL_WINDOW_SECS}s to force remote cancellation" >&2
		return 0
	fi

	echo "nixbot: received ${signal_name} ${NIXBOT_CANCEL_REQUESTED} times within ${NIXBOT_FORCE_CANCEL_WINDOW_SECS}s; best-effort canceling activation and forcing local jobs down" >&2
	cancel_active_deploy_activation_units
	terminate_background_jobs force
	exit "${exit_status}"
}

cancel_requested() {
	[ "${NIXBOT_CANCEL_REQUESTED:-0}" -gt 0 ]
}

force_cancel_requested() {
	[ "${NIXBOT_CANCEL_REQUESTED:-0}" -ge "${NIXBOT_FORCE_CANCEL_SIGNAL_COUNT:-3}" ]
}

active_deploy_registry_file() {
	local node="$1" node_hash=""

	ensure_tmp_dir
	node_hash="$(printf '%s' "${node}" | sha256sum | cut -d ' ' -f 1)"
	printf '%s/%s.deploy\n' "${TMP_ACTIVE_DEPLOY_DIR}" "${node_hash}"
}

deploy_job_registry_file() {
	local pid="$1"

	ensure_tmp_dir
	printf '%s/%s.job\n' "${TMP_DEPLOY_JOB_DIR}" "${pid}"
}

deploy_activation_marker_file() {
	local node="$1" node_hash=""

	ensure_tmp_dir
	node_hash="$(printf '%s' "${node}" | sha256sum | cut -d ' ' -f 1)"
	printf '%s/%s.activation\n' "${TMP_DEPLOY_JOB_DIR}" "${node_hash}"
}

nixbot_run_id() {
	local run_id=""

	ensure_runtime_work_dir
	run_id="$(basename "${RUNTIME_WORK_DIR}")"
	run_id="${run_id#run-}"
	printf '%s\n' "$(printf '%s' "${run_id}" | tr -c 'a-zA-Z0-9._-' '-')"
}

nixbot_host_unit_name() {
	local purpose="$1" node="$2" run_id="" node_hash=""

	run_id="$(nixbot_run_id)"
	node_hash="$(printf '%s' "${node}" | sha256sum | cut -c 1-16)"
	printf 'nixbot-%s-%s-%s\n' "${purpose}" "${run_id}" "${node_hash}"
}

deploy_activation_unit_name() {
	local node="$1"

	nixbot_host_unit_name switch-to-configuration "${node}"
}

deploy_activation_attempt_unit_name() {
	local node="$1" attempt="${2:-1}" unit_name=""

	unit_name="$(deploy_activation_unit_name "${node}")"
	if [ "${attempt}" -le 1 ]; then
		printf '%s\n' "${unit_name}"
	else
		printf '%s-retry%s\n' "${unit_name}" "${attempt}"
	fi
}

rollback_activation_unit_name() {
	local node="$1"

	nixbot_host_unit_name rollback-to-configuration "${node}"
}

nixbot_activation_command() {
	local system_path="$1" goal="$2" persist_profile="$3" post_promote_bootloader_goal="$4"

	printf 'set -Eeuo pipefail\n'
	printf 'system_path=%q\n' "${system_path}"
	printf 'goal=%q\n' "${goal}"
	printf 'persist_profile=%q\n' "${persist_profile}"
	printf 'post_promote_bootloader_goal=%q\n' "${post_promote_bootloader_goal}"
	cat <<'EOF_ACTIVATION'
nix_env_path="${system_path}/sw/bin/nix-env"

if [ ! -x "${system_path}/bin/switch-to-configuration" ]; then
	echo "system path is not activatable: ${system_path}" >&2
	exit 1
fi

NIXOS_INSTALL_BOOTLOADER=0 "${system_path}/bin/switch-to-configuration" "${goal}"

if [ "${persist_profile}" -eq 1 ]; then
	if [ ! -f "${system_path}/nixos-version" ]; then
		echo "system path is missing nixos-version after activation: ${system_path}" >&2
		exit 1
	fi
	if [ ! -x "${nix_env_path}" ]; then
		echo "system path is missing nix-env: ${nix_env_path}" >&2
		exit 1
	fi
	"${nix_env_path}" -p /nix/var/nix/profiles/system --set "${system_path}"
	if [ -n "${post_promote_bootloader_goal}" ]; then
		NIXOS_INSTALL_BOOTLOADER=1 "${system_path}/bin/switch-to-configuration" "${post_promote_bootloader_goal}"
	fi
fi
EOF_ACTIVATION
}

nixbot_activation_runner_command() {
	local activation_script="$1" encoded_script="" runner_script=""

	encoded_script="$(printf '%s' "${activation_script}" | base64 | tr -d '\n')"
	# shellcheck disable=SC2016
	printf -v runner_script \
		'set -o pipefail; printf %%s "$1" | %q -d | %q -s' \
		"${REMOTE_SYSTEM_BIN_DIR}/base64" \
		"${REMOTE_SYSTEM_BASH}"
	shell_quote_argv "${REMOTE_SYSTEM_BASH}" -c "${runner_script}" nixbot-activation "${encoded_script}"
}

activation_goal_persists_profile() {
	local goal="$1"

	case "${goal}" in
	switch | boot) return 0 ;;
	*) return 1 ;;
	esac
}

host_boot_is_container() {
	local node="$1" is_container=""

	if ! run_supervised_stdout_capture is_container "" \
		nix eval "${NIXBOT_BUILD_PLAN_NIX_ARGS[@]}" --option warn-dirty false --json --no-write-lock-file ".#nixosConfigurations.${node}.config.boot.isContainer"; then
		echo "Failed to evaluate boot.isContainer for ${node}" >&2
		return 2
	fi

	case "${is_container}" in
	true) return 0 ;;
	false) return 1 ;;
	*)
		echo "Unexpected boot.isContainer value for ${node}: ${is_container}" >&2
		return 2
		;;
	esac
}

activation_post_promote_bootloader_goal() {
	local node="$1" goal="$2" is_container_rc=0

	if ! activation_goal_persists_profile "${goal}"; then
		return 0
	fi

	if host_boot_is_container "${node}"; then
		is_container_rc=0
	else
		is_container_rc="$?"
	fi
	case "${is_container_rc}" in
	0)
		;;
	1)
		printf 'boot\n'
		;;
	*)
		return "${is_container_rc}"
		;;
	esac
}

nixbot_activation_systemd_run_properties() {
	printf -- '--property=%q --property=%q --property=%q --property=%q ' \
		"RuntimeMaxSec=${NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS}s" \
		"TimeoutStopSec=${NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS}s" \
		"KillMode=control-group" \
		"CollectMode=inactive-or-failed"
}

deploy_pre_activation_cancel_marker_file() {
	local node="$1" node_hash=""

	ensure_tmp_dir
	node_hash="$(printf '%s' "${node}" | sha256sum | cut -d ' ' -f 1)"
	printf '%s/%s.pre-activation-canceled\n' "${TMP_DEPLOY_JOB_DIR}" "${node_hash}"
}

mark_deploy_job_started() {
	NIXBOT_DEPLOY_STARTED=1
}

register_active_deploy() {
	local node="$1" registry_file=""

	registry_file="$(active_deploy_registry_file "${node}")"
	printf '%s\n' "${node}" >"${registry_file}"
}

unregister_active_deploy() {
	local node="$1" registry_file=""

	registry_file="$(active_deploy_registry_file "${node}")"
	rm -f "${registry_file}"
}

register_deploy_job_pid() {
	local node="$1" pid="$2" registry_file=""

	registry_file="$(deploy_job_registry_file "${pid}")"
	printf '%s\n' "${node}" >"${registry_file}"
}

mark_deploy_activation_started() {
	local node="$1" marker_file=""

	marker_file="$(deploy_activation_marker_file "${node}")"
	printf '%s\n' "${node}" >"${marker_file}"
}

deploy_jobs_started() {
	[ "${NIXBOT_DEPLOY_STARTED:-0}" -eq 1 ]
}

active_deploys_registered() {
	[ -n "${TMP_ACTIVE_DEPLOY_DIR:-}" ] || return 1
	[ -d "${TMP_ACTIVE_DEPLOY_DIR}" ] || return 1
	find "${TMP_ACTIVE_DEPLOY_DIR}" -type f -name '*.deploy' -print -quit 2>/dev/null | grep -q .
}

active_deploy_jobs_running() {
	active_deploys_registered || return 1
	jobs -pr 2>/dev/null | grep -q .
}

active_deploy_files() {
	[ -n "${TMP_ACTIVE_DEPLOY_DIR:-}" ] || return 0
	[ -d "${TMP_ACTIVE_DEPLOY_DIR}" ] || return 0
	find "${TMP_ACTIVE_DEPLOY_DIR}" -type f -name '*.deploy' -print 2>/dev/null | sort
}

wait_active_deploy_jobs_to_finish() {
	local active_pids=""

	[ "${NIXBOT_CANCEL_REMOTE_WAIT_DONE:-0}" -eq 0 ] || return 0
	if active_deploys_registered; then
		NIXBOT_CANCEL_ACTIVE_DEPLOYS_SEEN=1
	fi
	[ "${NIXBOT_CANCEL_ACTIVE_DEPLOYS_SEEN:-0}" -eq 1 ] || return 0
	while active_pids="$(jobs -pr 2>/dev/null || true)" && [ -n "${active_pids}" ]; do
		if force_cancel_requested; then
			return 1
		fi
		wait -n || true
	done

	NIXBOT_CANCEL_REMOTE_WAIT_DONE=1
	return 0
}

active_deploy_activation_units_running() {
	local file="" node="" unit_name="" check_cmd="" state=""

	while IFS= read -r file; do
		[ -n "${file}" ] || continue
		node="$(cat "${file}" 2>/dev/null || true)"
		[ -n "${node}" ] || continue
		unit_name="$(deploy_activation_unit_name "${node}")"
		printf -v check_cmd 'systemctl show --property=ActiveState --value %q 2>/dev/null || true' "${unit_name}"
		if ! state="$(run_host_root_command "${node}" "${check_cmd}" 2>/dev/null)"; then
			continue
		fi
		case "${state}" in
		active | activating | reloading | deactivating)
			return 0
			;;
		esac
	done < <(active_deploy_files)

	return 1
}

host_deploy_activation_unit_running() {
	local node="$1" unit_name="" check_cmd="" state=""

	unit_name="$(deploy_activation_unit_name "${node}")"
	printf -v check_cmd 'systemctl show --property=ActiveState --value %q 2>/dev/null || true' "${unit_name}"
	if ! state="$(run_host_root_command "${node}" "${check_cmd}" 2>/dev/null)"; then
		return 1
	fi
	case "${state}" in
	active | activating | reloading | deactivating)
		return 0
		;;
	esac

	return 1
}

deploy_activation_unit_state() {
	local node="$1" unit_name="" check_cmd="" state=""

	unit_name="$(deploy_activation_unit_name "${node}")"
	printf -v check_cmd 'systemctl show --property=ActiveState --value %q 2>/dev/null || true' "${unit_name}"
	state="$(run_host_root_command "${node}" "${check_cmd}" 2>/dev/null)" || return 1
	printf '%s' "${state}"
}

host_deploy_reached_activation() {
	local node="$1"

	if [ -s "$(deploy_activation_marker_file "${node}")" ]; then
		return 0
	fi
	host_deploy_activation_unit_running "${node}"
}

terminate_pre_activation_deploy_jobs() {
	local failed_node="$1" file="" pid="" node=""
	local -a canceled_pids=()

	[ -n "${TMP_DEPLOY_JOB_DIR:-}" ] || return 0
	[ -d "${TMP_DEPLOY_JOB_DIR}" ] || return 0

	while IFS= read -r file; do
		[ -n "${file}" ] || continue
		pid="$(basename "${file}" .job)"
		[ -n "${pid}" ] || continue
		kill -0 "${pid}" 2>/dev/null || continue
		node="$(cat "${file}" 2>/dev/null || true)"
		[ -n "${node}" ] || continue
		[ "${node}" != "${failed_node}" ] || continue
		if host_deploy_reached_activation "${node}"; then
			echo "Deploy failed on ${failed_node}; leaving ${node} activation to finish" >&2
			continue
		fi
		NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS=$((NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS + 1))
		: >"$(deploy_pre_activation_cancel_marker_file "${node}")"
		echo "Deploy failed on ${failed_node}; canceling pre-activation deploy for ${node}" >&2
		terminate_pid_tree "${pid}" TERM
		canceled_pids+=("${pid}")
	done < <(find "${TMP_DEPLOY_JOB_DIR}" -type f -name '*.job' -print 2>/dev/null | sort)

	[ "${#canceled_pids[@]}" -gt 0 ] || return 0
	sleep "${NIXBOT_CANCEL_TERM_GRACE_SECS}"
	for pid in "${canceled_pids[@]}"; do
		kill -0 "${pid}" 2>/dev/null || continue
		terminate_pid_tree "${pid}" KILL
	done
}

run_active_deploy_activation_unit_command() {
	local action="$1" file="" node="" unit_name="" command=""

	while IFS= read -r file; do
		[ -n "${file}" ] || continue
		node="$(cat "${file}" 2>/dev/null || true)"
		[ -n "${node}" ] || continue
		unit_name="$(deploy_activation_unit_name "${node}")"
		case "${action}" in
		stop)
			printf -v command 'systemctl --no-block stop %q' "${unit_name}"
			;;
		kill)
			printf -v command 'systemctl kill --kill-who=all --signal=KILL %q' "${unit_name}"
			;;
		*)
			die "Unsupported active deploy activation unit action: ${action}"
			;;
		esac
		run_host_root_command "${node}" "${command}" >/dev/null 2>&1 || true
	done < <(active_deploy_files)
}

cancel_active_deploy_activation_units() {
	local start_epoch="" now_epoch=""

	active_deploys_registered || return 0

	run_active_deploy_activation_unit_command stop

	start_epoch="$(date +%s)"
	while active_deploy_activation_units_running; do
		now_epoch="$(date +%s)"
		if [ $((now_epoch - start_epoch)) -ge "${NIXBOT_REMOTE_CANCEL_GRACE_SECS}" ]; then
			break
		fi
		sleep 1
	done

	if active_deploy_activation_units_running; then
		run_active_deploy_activation_unit_command kill
	fi
}

collect_descendant_pids() {
	local pid="$1" child=""

	[ -n "${pid}" ] || return 0
	kill -0 "${pid}" 2>/dev/null || return 0
	printf '%s\n' "${pid}"

	while IFS= read -r child; do
		[ -n "${child}" ] || continue
		collect_descendant_pids "${child}"
	done < <(pgrep -P "${pid}" 2>/dev/null || true)
}

terminate_pid_tree() {
	local root_pid="$1" signal_name="$2" pid="" index=0
	local -a pids=()

	mapfile -t pids < <(collect_descendant_pids "${root_pid}" | awk '!seen[$0]++')
	[ "${#pids[@]}" -gt 0 ] || return 0

	for ((index = ${#pids[@]} - 1; index >= 0; index--)); do
		pid="${pids[${index}]}"
		kill "-${signal_name}" "${pid}" >/dev/null 2>&1 || true
	done
}

terminate_ssh_control_masters() {
	local signal_name="$1" pid=""
	local -a control_master_pids=()

	[ -n "${TMP_SSH_DIR:-}" ] || return 0
	[ -d "${TMP_SSH_DIR}" ] || return 0

	mapfile -t control_master_pids < <(pgrep -f -- "${TMP_SSH_DIR}/cm-" 2>/dev/null || true)
	for pid in "${control_master_pids[@]}"; do
		[ -n "${pid}" ] || continue
		[ "${pid}" != "$$" ] || continue
		terminate_pid_tree "${pid}" "${signal_name}"
	done
}

terminate_nixbot_process_group_wrappers() {
	local signal_name="$1" pid="" pgid="" args=""

	[ -n "${NIXBOT_PROCESS_GROUP:-}" ] || return 0
	[ -n "${NIXBOT_PARENT_PROCESS_GROUP:-}" ] || return 0
	[ "${NIXBOT_PROCESS_GROUP}" != "${NIXBOT_PARENT_PROCESS_GROUP}" ] || return 0
	[ -n "${NIXBOT_SCRIPT_PATH:-}" ] || return 0

	while read -r pid pgid args; do
		[ -n "${pid}" ] || continue
		[ "${pid}" != "$$" ] || continue
		[ "${pgid}" = "${NIXBOT_PROCESS_GROUP}" ] || continue
		case "${args}" in
		*" ${NIXBOT_SCRIPT_PATH} "* | *" ${NIXBOT_SCRIPT_PATH}")
			kill "-${signal_name}" "${pid}" >/dev/null 2>&1 || true
			;;
		esac
	done < <(ps -eo pid=,pgid=,args= 2>/dev/null || true)
}

terminate_background_jobs() {
	local mode="${1:-term}" signal_name="TERM"
	local -a job_pids=()

	mapfile -t job_pids < <(jobs -pr 2>/dev/null || true)
	if [ "${mode}" = "force" ]; then
		signal_name="KILL"
	fi

	terminate_ssh_control_masters "${signal_name}"
	terminate_nixbot_process_group_wrappers "${signal_name}"
	[ "${#job_pids[@]}" -gt 0 ] || return 0

	for pid in "${job_pids[@]}"; do
		terminate_pid_tree "${pid}" "${signal_name}"
	done

	if [ "${signal_name}" != "KILL" ]; then
		sleep "${NIXBOT_CANCEL_TERM_GRACE_SECS}"
		terminate_ssh_control_masters KILL
		terminate_nixbot_process_group_wrappers KILL
		for pid in "${job_pids[@]}"; do
			kill -0 "${pid}" 2>/dev/null || continue
			terminate_pid_tree "${pid}" KILL
		done
	fi

	wait "${job_pids[@]}" >/dev/null 2>&1 || true
}

ensure_tmp_dir() {
	if [ -n "${NIXBOT_TMP_DIR}" ]; then
		return
	fi
	ensure_runtime_work_dir
	NIXBOT_TMP_DIR="${RUNTIME_WORK_DIR}"

	# Runtime-only material stays out of diagnostics. The diag directory is safe
	# to retain directly on failure without a sanitization pass.
	TMP_SECRETS_DIR="${NIXBOT_TMP_DIR}/secrets"
	TMP_SSH_DIR="${NIXBOT_TMP_DIR}/ssh"
	TMP_TARGET_DIR="${NIXBOT_TMP_DIR}/target-tmp"
	TMP_STDERR_DIR="${NIXBOT_DIAG_DIR}/stderr"
	TMP_STDOUT_DIR="${NIXBOT_TMP_DIR}/stdout"
	TMP_BUILD_RESULTS_DIR="${NIXBOT_TMP_DIR}/build-results"
	TMP_BUILD_PLAN_DIR="${NIXBOT_TMP_DIR}/build-plans"
	TMP_TF_ARTIFACT_DIR="$(phase_artifact_dir_path "${NIXBOT_TMP_DIR}" "tf")"
	TMP_ACTIVE_DEPLOY_DIR="${NIXBOT_TMP_DIR}/active-deploys"
	TMP_DEPLOY_JOB_DIR="${NIXBOT_TMP_DIR}/deploy-jobs"
	TMP_STATE_LOCK_DIR="${NIXBOT_TMP_DIR}/state-locks"
	NIXBOT_TTY_LOCK_DIR="${NIXBOT_TMP_DIR}/ssh-tty.lock"
	mkdir -p \
		"${TMP_SECRETS_DIR}" \
		"${TMP_SSH_DIR}" \
		"${TMP_TARGET_DIR}" \
		"${TMP_STDERR_DIR}" \
		"${TMP_STDOUT_DIR}" \
		"${TMP_BUILD_RESULTS_DIR}" \
		"${TMP_BUILD_PLAN_DIR}" \
		"${TMP_TF_ARTIFACT_DIR}" \
		"${TMP_ACTIVE_DEPLOY_DIR}" \
		"${TMP_DEPLOY_JOB_DIR}" \
		"${TMP_STATE_LOCK_DIR}"
	ensure_phase_artifact_dirs "${NIXBOT_DIAG_DIR}" tf
}

tmp_runtime_dir_path() {
	local area="$1"

	ensure_tmp_dir
	case "${area}" in
	secrets) printf '%s\n' "${TMP_SECRETS_DIR}" ;;
	ssh) printf '%s\n' "${TMP_SSH_DIR}" ;;
	target) printf '%s\n' "${TMP_TARGET_DIR}" ;;
	stderr) printf '%s\n' "${TMP_STDERR_DIR}" ;;
	stdout) printf '%s\n' "${TMP_STDOUT_DIR}" ;;
	build-results) printf '%s\n' "${TMP_BUILD_RESULTS_DIR}" ;;
	build-plans) printf '%s\n' "${TMP_BUILD_PLAN_DIR}" ;;
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

runtime_state_file() {
	local state_name="$1"

	ensure_tmp_dir
	printf '%s/%s\n' "${NIXBOT_TMP_DIR}" "${state_name}"
}

runtime_state_lock_dir() {
	local state_name="$1"

	ensure_tmp_dir
	printf '%s/%s.lock\n' "${TMP_STATE_LOCK_DIR}" "${state_name}"
}

acquire_runtime_state_lock() {
	local state_name="$1" lock_dir="" lock_pid="" lock_deadline=0

	lock_dir="$(runtime_state_lock_dir "${state_name}")"
	lock_deadline=$((SECONDS + NIXBOT_STATE_LOCK_TIMEOUT))
	while ! mkdir "${lock_dir}" 2>/dev/null; do
		if [ "${SECONDS}" -ge "${lock_deadline}" ]; then
			lock_pid=""
			if [ -f "${lock_dir}/pid" ]; then
				lock_pid="$(<"${lock_dir}/pid")"
			fi

			if [ -n "${lock_pid}" ] && kill -0 "${lock_pid}" 2>/dev/null; then
				die "Timed out waiting for runtime state lock ${lock_dir} held by pid ${lock_pid}"
			fi

			echo "Removing stale runtime state lock: ${lock_dir}" >&2
			rm -rf "${lock_dir}" 2>/dev/null || true
			lock_deadline=$((SECONDS + NIXBOT_STATE_LOCK_TIMEOUT))
			continue
		fi

		sleep 0.05
	done

	printf '%s\n' "${BASHPID}" >"${lock_dir}/pid"
}

release_runtime_state_lock() {
	local state_name="$1" lock_dir=""

	lock_dir="$(runtime_state_lock_dir "${state_name}")"
	rm -rf "${lock_dir}" 2>/dev/null || true
}

with_runtime_state_lock() {
	local state_name="$1" rc=0
	shift

	acquire_runtime_state_lock "${state_name}"
	if "$@"; then
		rc=0
	else
		rc="$?"
	fi
	release_runtime_state_lock "${state_name}"
	return "${rc}"
}

line_state_cache_contains() {
	local cache="$1" item="$2"

	case " ${cache} " in
	*" ${item} "*) return 0 ;;
	esac
	return 1
}

line_state_file_contains() {
	local state_file="$1" item="$2"

	[ -f "${state_file}" ] || return 1
	grep -Fxq -- "${item}" "${state_file}"
}

line_state_contains_locked() {
	local state_name="$1" item="$2" cache_name="$3" state_file=""
	# shellcheck disable=SC2178
	local -n cache_ref="${cache_name}"

	if line_state_cache_contains "${cache_ref}" "${item}"; then
		return 0
	fi

	state_file="$(runtime_state_file "${state_name}")"
	if line_state_file_contains "${state_file}" "${item}"; then
		cache_ref="${cache_ref}${cache_ref:+ }${item}"
		return 0
	fi

	return 1
}

line_state_contains() {
	local state_name="$1" item="$2" cache_name="$3"

	with_runtime_state_lock \
		"${state_name}" \
		line_state_contains_locked \
		"${state_name}" \
		"${item}" \
		"${cache_name}"
}

line_state_mark_locked() {
	local state_name="$1" item="$2" cache_name="$3" state_file=""
	# shellcheck disable=SC2178
	local -n cache_ref="${cache_name}"

	if ! line_state_cache_contains "${cache_ref}" "${item}"; then
		cache_ref="${cache_ref}${cache_ref:+ }${item}"
	fi

	state_file="$(runtime_state_file "${state_name}")"
	if ! line_state_file_contains "${state_file}" "${item}"; then
		printf '%s\n' "${item}" >>"${state_file}" || return 1
	fi
}

line_state_mark() {
	local state_name="$1" item="$2" cache_name="$3"

	with_runtime_state_lock \
		"${state_name}" \
		line_state_mark_locked \
		"${state_name}" \
		"${item}" \
		"${cache_name}"
}

line_state_mark_new_locked() {
	local state_name="$1" item="$2" cache_name="$3" state_file=""
	# shellcheck disable=SC2178
	local -n cache_ref="${cache_name}"

	state_file="$(runtime_state_file "${state_name}")"
	if line_state_cache_contains "${cache_ref}" "${item}"; then
		return 1
	fi

	if line_state_file_contains "${state_file}" "${item}"; then
		cache_ref="${cache_ref}${cache_ref:+ }${item}"
		return 1
	fi

	cache_ref="${cache_ref}${cache_ref:+ }${item}"
	printf '%s\n' "${item}" >>"${state_file}" || return 1
	return 0
}

line_state_mark_new() {
	local state_name="$1" item="$2" cache_name="$3"

	with_runtime_state_lock \
		"${state_name}" \
		line_state_mark_new_locked \
		"${state_name}" \
		"${item}" \
		"${cache_name}"
}

line_state_clear_locked() {
	local state_name="$1" item="$2" cache_name="$3"
	local state_file="" tmp_file="" line="" rebuilt_cache=""
	# shellcheck disable=SC2178
	local -n cache_ref="${cache_name}"

	for line in ${cache_ref}; do
		[ "${line}" = "${item}" ] && continue
		rebuilt_cache="${rebuilt_cache}${rebuilt_cache:+ }${line}"
	done
	cache_ref="${rebuilt_cache}"

	state_file="$(runtime_state_file "${state_name}")"
	[ -f "${state_file}" ] || return 0

	if ! tmp_file="$(mktemp "${state_file}.tmp.XXXXXX")"; then
		return 1
	fi
	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		[ "${line}" = "${item}" ] && continue
		printf '%s\n' "${line}" >>"${tmp_file}" || {
			rm -f "${tmp_file}"
			return 1
		}
	done <"${state_file}"
	mv "${tmp_file}" "${state_file}" || {
		rm -f "${tmp_file}"
		return 1
	}
}

line_state_clear() {
	local state_name="$1" item="$2" cache_name="$3"

	with_runtime_state_lock \
		"${state_name}" \
		line_state_clear_locked \
		"${state_name}" \
		"${item}" \
		"${cache_name}"
}

runtime_namespace_root() {
	if [ -d "/dev/shm" ] && [ -w "/dev/shm" ]; then
		printf '%s\n' "${RUNTIME_WORK_ROOT}"
	else
		printf '%s\n' "${RUNTIME_WORK_FALLBACK_ROOT}"
	fi
}

ensure_runtime_work_dir() {
	local namespace_root="" run_id="" run_dir_template=""

	if [ -n "${RUNTIME_WORK_DIR}" ]; then
		if [ -z "${NIXBOT_DIAG_DIR}" ]; then
			run_id="$(basename "${RUNTIME_WORK_DIR}")"
			run_id="${run_id#run-}"
			NIXBOT_DIAG_DIR="$(dirname "${RUNTIME_WORK_DIR}")/diag-${run_id}"
		fi
		mkdir -p "${NIXBOT_DIAG_DIR}" || die "Failed to create diagnostic directory: ${NIXBOT_DIAG_DIR}"
		return 0
	fi

	namespace_root="$(runtime_namespace_root)"
	mkdir -p "${namespace_root}" || die "Failed to create nixbot runtime namespace: ${namespace_root}"
	run_dir_template="${namespace_root}/run-XXXXXX"
	RUNTIME_WORK_DIR="$(mktemp -d "${run_dir_template}")" || die "Failed to create runtime directory under ${namespace_root}"
	run_id="$(basename "${RUNTIME_WORK_DIR}")"
	run_id="${run_id#run-}"
	NIXBOT_DIAG_DIR="${namespace_root}/diag-${run_id}"
	mkdir -p "${NIXBOT_DIAG_DIR}" || die "Failed to create diagnostic directory: ${NIXBOT_DIAG_DIR}"
}

cleanup_stale_runtime_dirs() {
	local scan_root="" path=""

	scan_root="${RUNTIME_WORK_ROOT}"
	if [ -d "${scan_root}" ]; then

		while IFS= read -r path; do
			[ -n "${path}" ] || continue
			rm -rf "${path}" || true
		done < <(
			find "${scan_root}" -maxdepth 1 -mindepth 1 -type d \
				\( -name 'run-*' -o -name 'diag-*' \) \
				-mtime +3 -print 2>/dev/null
		)
		rmdir "${scan_root}" 2>/dev/null || true
	fi

	scan_root="${RUNTIME_WORK_FALLBACK_ROOT}"
	if [ -d "${scan_root}" ]; then

		while IFS= read -r path; do
			[ -n "${path}" ] || continue
			rm -rf "${path}" || true
		done < <(
			find "${scan_root}" -maxdepth 1 -mindepth 1 -type d \
				-name 'run-*' \
				-mtime +3 -print 2>/dev/null
		)
		rmdir "${scan_root}" 2>/dev/null || true
	fi

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

	scan_root="${NIXBOT_DIAG_KEEP_ROOT}"
	if [ -d "${scan_root}" ]; then
		while IFS= read -r path; do
			[ -n "${path}" ] || continue
			rm -rf "${path}" || true
		done < <(
			find "${scan_root}" -maxdepth 1 -mindepth 1 -type d \
				-name 'diag-*' \
				-mtime +3 -print 2>/dev/null
		)
		while IFS= read -r path; do
			[ -n "${path}" ] || continue
			rmdir "${path}" 2>/dev/null || true
		done < <(
			find "${scan_root}" -maxdepth 1 -mindepth 1 -type d \
				-name 'diag-*' \
				-empty -print 2>/dev/null
		)
		rmdir "${scan_root}" 2>/dev/null || true
	fi
}

dir_has_regular_files() {
	local dir="$1"

	[ -d "${dir}" ] || return 1
	find "${dir}" -type f -print -quit 2>/dev/null | grep -q .
}

keep_diag_dir() {
	local keep_dir=""

	[ "${NIXBOT_DIAG_REPORTED:-0}" -eq 0 ] || return 0
	[ -n "${NIXBOT_DIAG_DIR:-}" ] || return 0
	[ -d "${NIXBOT_DIAG_DIR}" ] || return 0

	if ! dir_has_regular_files "${NIXBOT_DIAG_DIR}"; then
		rm -rf "${NIXBOT_DIAG_DIR}"
		rmdir "${NIXBOT_DIAG_KEEP_ROOT}" 2>/dev/null || true
		return 0
	fi

	keep_dir="${NIXBOT_DIAG_KEEP_ROOT}/$(basename "${NIXBOT_DIAG_DIR}")"
	if [ "${NIXBOT_DIAG_DIR}" != "${keep_dir}" ]; then
		if [ -e "${keep_dir}" ]; then
			keep_dir="${keep_dir}.$(date +%s).$$"
		fi
		if mkdir -p "${NIXBOT_DIAG_KEEP_ROOT}" && mv "${NIXBOT_DIAG_DIR}" "${keep_dir}"; then
			NIXBOT_DIAG_DIR="${keep_dir}"
		else
			echo "warning: failed to move diagnostics to ${keep_dir}; keeping ${NIXBOT_DIAG_DIR}" >&2
		fi
	fi
	printf '\nLogs kept at: %s\n' "${NIXBOT_DIAG_DIR}" >&2
	NIXBOT_DIAG_REPORTED=1
}

keep_diag_on_failure() {
	NIXBOT_KEEP_DIAG_ON_FAILURE=1
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
		"${REPO_WORKTREE_ROOT}" | "${REPO_WORKTREE_ROOT}/"*)
			cd /
			;;
		esac
		git -C "${REPO_ROOT}" worktree remove --force "${REPO_WORKTREE_ROOT}" >/dev/null 2>&1 || rm -rf "${REPO_WORKTREE_ROOT}"
		git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
	fi
	release_repo_root_lock
}

prepare_dev_build_workspace() {
	local current_repo_root=""

	current_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	[ -n "${current_repo_root}" ] || die "dev-build must be run from inside a Git checkout"
	cd "${current_repo_root}"
}

warn_if_unstaged_changes_ignored() {
	local repo_root="$1" untracked_path=""

	if ! git -C "${repo_root}" diff --quiet --no-ext-diff --; then
		echo "warning: --dirty-staged ignores unstaged tracked changes" >&2
	fi

	untracked_path="$(git -C "${repo_root}" ls-files --others --exclude-standard | sed -n '1p')"
	if [ -n "${untracked_path}" ]; then
		echo "warning: --dirty-staged ignores unstaged untracked files" >&2
	fi
}

write_staged_patch_from_repo() {
	local repo_root="$1" patch_file="$2"

	if git -C "${repo_root}" diff --cached --quiet --no-ext-diff --; then
		return 2
	fi

	git -C "${repo_root}" diff --cached --binary --full-index --no-ext-diff >"${patch_file}" ||
		die "Failed to prepare staged patch from ${repo_root}"
	[ -s "${patch_file}" ] || die "Staged patch was empty: ${patch_file}"
}

capture_dirty_staged_patch_stdin() {
	[ "${DIRTY_STAGED_PATCH_STDIN}" -eq 1 ] || return 0
	[ -z "${DIRTY_STAGED_PATCH_FILE}" ] || return 0

	[ ! -t 0 ] || die "--dirty-staged patch payload must be provided on stdin"
	ensure_tmp_dir
	DIRTY_STAGED_PATCH_FILE="$(tmp_runtime_mktemp target "dirty-staged-stdin.XXXXXX.patch")"
	cat >"${DIRTY_STAGED_PATCH_FILE}" || die "Failed to read --dirty-staged patch payload"
	[ -s "${DIRTY_STAGED_PATCH_FILE}" ] || die "--dirty-staged patch payload was empty"
}

prepare_local_dirty_staged_patch() {
	local rc=0

	ensure_tmp_dir
	DIRTY_STAGED_PATCH_FILE="$(tmp_runtime_mktemp target "dirty-staged.XXXXXX.patch")"
	warn_if_unstaged_changes_ignored "${REPO_ROOT}"
	if write_staged_patch_from_repo "${REPO_ROOT}" "${DIRTY_STAGED_PATCH_FILE}"; then
		return 0
	else
		rc="$?"
	fi
	if [ "${rc}" -eq 2 ]; then
		rm -f "${DIRTY_STAGED_PATCH_FILE}"
		DIRTY_STAGED_PATCH_FILE=""
		echo "No staged changes to overlay; continuing with committed state" >&2
		return 2
	fi
	return "${rc}"
}

validate_dirty_staged_base() {
	local target_ref="$1" target_commit="" base_commit=""

	[ "${OVERLAY_STAGED}" -eq 1 ] || return 0

	target_commit="$(git -C "${REPO_ROOT}" rev-parse --verify "${target_ref}^{commit}" 2>/dev/null)" ||
		die "Requested repo target not available: ${target_ref}"

	if [ -z "${DIRTY_STAGED_BASE_SHA}" ] && [ "${REPO_ROOT_MANAGED}" -eq 0 ]; then
		DIRTY_STAGED_BASE_SHA="$(git -C "${REPO_ROOT}" rev-parse --verify HEAD)"
	fi

	[ -n "${DIRTY_STAGED_BASE_SHA}" ] ||
		die "--dirty-staged requires a base commit for managed repo worktrees"

	base_commit="$(git -C "${REPO_ROOT}" rev-parse --verify "${DIRTY_STAGED_BASE_SHA}^{commit}" 2>/dev/null)" ||
		die "--dirty-staged base commit is unavailable: ${DIRTY_STAGED_BASE_SHA}"

	[ "${target_commit}" = "${base_commit}" ] ||
		die "--dirty-staged patch is based on ${base_commit}, but requested target is ${target_commit}"
}

overlay_dirty_staged_patch_to_worktree() {
	local rc=0

	[ "${OVERLAY_STAGED}" -eq 1 ] || return 0

	capture_dirty_staged_patch_stdin
	if [ -z "${DIRTY_STAGED_PATCH_FILE}" ]; then
		if [ "${REPO_ROOT_MANAGED}" -eq 0 ]; then
			if prepare_local_dirty_staged_patch; then
				:
			else
				rc="$?"
				[ "${rc}" -eq 2 ] && return 0
				return "${rc}"
			fi
		else
			die "--dirty-staged on a managed repo requires a staged patch payload"
		fi
	fi

	echo "Overlaying staged changes into worktree..." >&2
	git -C "${REPO_WORKTREE_ROOT}" apply --index --binary --allow-empty "${DIRTY_STAGED_PATCH_FILE}" ||
		die "Failed to overlay staged changes into repo worktree"
}

configure_ci_trigger_ssh_opts() {
	local key_file="" known_hosts_file="" scanned_known_hosts=""

	CI_TRIGGER_SSH_OPTS=()

	ensure_tmp_dir

	if [ -z "${CI_TRIGGER_SSH_KEY}" ]; then
		if key_file="$(resolve_runtime_key_file "${CI_TRIGGER_KEY_PATH}" 1)" && [ -f "${key_file}" ]; then
			CI_TRIGGER_SSH_KEY="$(<"${key_file}")"
		else
			CI_TRIGGER_SSH_KEY=""
		fi
	fi

	if [ -n "${CI_TRIGGER_SSH_KEY}" ]; then
		key_file="$(tmp_runtime_mktemp ssh "ci-key.XXXXXX")"
		printf '%s\n' "${CI_TRIGGER_SSH_KEY}" >"${key_file}"
		chmod 600 "${key_file}"
		CI_TRIGGER_SSH_OPTS+=(-i "${key_file}" -o IdentitiesOnly=yes)
	fi

	if [ -n "${CI_TRIGGER_KNOWN_HOSTS}" ]; then
		scanned_known_hosts="${CI_TRIGGER_KNOWN_HOSTS}"
	else
		run_supervised_stdout_capture scanned_known_hosts "" run_quiet_ssh_keyscan -H "${CI_TRIGGER_HOST}" || true
		[ -n "${scanned_known_hosts}" ] || die "Could not determine CI host key for ${CI_TRIGGER_HOST}. Pass --ci-known-hosts/NIXBOT_CI_KNOWN_HOSTS or ensure ssh-keyscan can reach the CI host."
	fi

	known_hosts_file="$(tmp_runtime_mktemp ssh "${CI_KNOWN_HOSTS_PREFIX}.XXXXXX")"
	printf '%s\n' "${scanned_known_hosts}" >"${known_hosts_file}"
	chmod 600 "${known_hosts_file}"
	CI_TRIGGER_SSH_OPTS+=(
		-F "${SSH_NULL_CONFIG_FILE}"
		-o "GlobalKnownHostsFile=${SSH_NULL_KNOWN_HOSTS_FILE}"
		-o StrictHostKeyChecking=yes
		-o "UserKnownHostsFile=${known_hosts_file}"
	)
}

prepare_ci_trigger_dirty_staged_patch() {
	local trigger_sha="$1" local_repo_root="" local_head="" trigger_commit="" rc=0

	local_repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
	[ -n "${local_repo_root}" ] || die "--dirty-staged --ci-trigger must run from inside a Git checkout"

	local_head="$(git -C "${local_repo_root}" rev-parse --verify HEAD)" ||
		die "Could not resolve local HEAD for --dirty-staged"
	trigger_commit="$(git -C "${local_repo_root}" rev-parse --verify "${trigger_sha}^{commit}" 2>/dev/null)" ||
		die "Requested --dirty-staged trigger SHA is unavailable locally: ${trigger_sha}"

	[ "${trigger_commit}" = "${local_head}" ] ||
		die "--dirty-staged --ci-trigger can only send staged changes based on local HEAD (${local_head}); requested ${trigger_commit}"

	ensure_tmp_dir
	DIRTY_STAGED_PATCH_FILE="$(tmp_runtime_mktemp target "dirty-staged-ci.XXXXXX.patch")"
	DIRTY_STAGED_BASE_SHA="${local_head}"
	warn_if_unstaged_changes_ignored "${local_repo_root}"
	if write_staged_patch_from_repo "${local_repo_root}" "${DIRTY_STAGED_PATCH_FILE}"; then
		return 0
	else
		rc="$?"
	fi
	if [ "${rc}" -eq 2 ]; then
		rm -f "${DIRTY_STAGED_PATCH_FILE}"
		DIRTY_STAGED_PATCH_FILE=""
		DIRTY_STAGED_BASE_SHA=""
		OVERLAY_STAGED=0
		echo "No staged changes to send; continuing CI trigger with committed state" >&2
		return 0
	fi
	return "${rc}"
}

run_ci_trigger() {
	local trigger_sha="${SHA}" trigger_groups="" trigger_hosts="" encoded_request="" config_json="" patch_bytes=""
	local all_hosts_json="" selected_hosts_json=""
	local -a remote_args=()
	if ! is_clean_action && [ -z "${trigger_sha}" ]; then
		trigger_sha="$(git rev-parse --verify HEAD 2>/dev/null || true)"
	fi
	if ! is_clean_action; then
		[ -n "${trigger_sha}" ] || die "Could not resolve local HEAD; pass --sha/NIXBOT_SHA explicitly"
		[[ "${trigger_sha}" =~ ^[0-9a-f]{7,40}$ ]] || die "Unsupported --sha: ${trigger_sha}"
	fi

	action_is_supported "${ACTION}" || die "Unsupported action for --ci-trigger: ${ACTION}"

	config_json="$(load_deploy_config_json "${NIXBOT_CONFIG_PATH}" "")"
	init_deploy_settings "${config_json}"
	if ! is_clean_action; then
		trigger_groups="$(normalize_groups_input "${GROUPS_RAW}")"
		if [ -n "${trigger_groups}" ]; then
			all_hosts_json="$(load_all_hosts_json)"
			selected_hosts_json="$(resolve_selected_hosts_json "${all_hosts_json}")" || exit "$?"
			trigger_hosts="$(jq -r 'join(",")' <<<"${selected_hosts_json}")"
		elif [ "${HOSTS_EXPLICIT}" -eq 1 ] || [ -z "${trigger_groups}" ]; then
			trigger_hosts="$(normalize_hosts_input "${HOSTS_RAW}")"
		fi
		[ -n "${trigger_hosts}" ] || die "No valid hosts after normalization"
	fi

	if [ -z "${CI_TRIGGER_HOST}" ]; then
		apply_config_defaults "${config_json}"
	fi
	if is_clean_action && [ "${OVERLAY_STAGED}" -eq 1 ]; then
		die "--clean --ci-trigger does not accept --dirty-staged"
	fi
	if ! is_clean_action && [ "${OVERLAY_STAGED}" -eq 1 ]; then
		prepare_ci_trigger_dirty_staged_patch "${trigger_sha}"
	fi

	configure_ci_trigger_ssh_opts

	log_section "Phase: Remote Trigger"
	echo "CI host: ${CI_TRIGGER_USER}@${CI_TRIGGER_HOST}" >&2
	echo "Action: ${ACTION}" >&2
	if [ -n "${trigger_groups}" ]; then
		echo "Groups: ${trigger_groups}" >&2
	fi
	if ! is_clean_action; then
		echo "Hosts: ${trigger_hosts}" >&2
		echo "SHA: ${trigger_sha}" >&2
	fi
	# Intentionally forward only the ci-trigger contract here. The remote side is
	# expected to use its repo-local defaults and checked-in config for
	# deploy-shaping settings such as goal, build host, job counts, rollback
	# policy, and similar local overrides. Operator execution modifiers such as
	# --dry, --force, --dirty, --no-verify, and --ci-first are explicit parts
	# of this contract.
	# Groups are resolved locally and forwarded as --hosts so an installed remote
	# nixbot can accept the request even before it has been upgraded with group
	# parsing support.
	if is_clean_action; then
		remote_args=("${ACTION}" --no-override --clean "${NIXBOT_CLEAN_MODE:-auto}")
	elif is_clear_remote_locks_action; then
		remote_args=("${ACTION}" --no-override)
	else
		remote_args=("${ACTION}" --sha "${trigger_sha}" --no-override)
	fi
	if ! is_clean_action; then
		remote_args+=(--hosts "${trigger_hosts}")
	fi
	if is_clear_remote_locks_action; then
		remote_args+=(--clear-remote-locks "${NIXBOT_CLEAR_REMOTE_LOCKS_MODE:-all}")
	fi
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
	if [ "${PRIORITIZE_CI_FIRST}" -eq 1 ]; then
		remote_args+=(--ci-first)
		echo "CI-first host ordering: true" >&2
	fi
	if [ "${VERIFY_AFTER_DEPLOY}" -eq 0 ]; then
		remote_args+=(--no-verify)
		echo "Post-deploy health checks: skipped" >&2
	fi
	if [ "${OVERLAY_STAGED}" -eq 1 ]; then
		remote_args+=(--dirty-staged --dirty-staged-patch-stdin --dirty-staged-base "${DIRTY_STAGED_BASE_SHA}")
		patch_bytes="$(wc -c <"${DIRTY_STAGED_PATCH_FILE}" | tr -d '[:space:]')"
		echo "Dirty staged patch: ${patch_bytes} bytes" >&2
	elif [ "${ALLOW_DIRTY_REPO}" -eq 1 ]; then
		remote_args+=(--dirty)
		echo "Dirty repo allowed: true" >&2
	fi

	encoded_request="$(encode_ssh_command_args "${remote_args[@]}")"
	log_group_end
	if [ -n "${DIRTY_STAGED_PATCH_FILE}" ]; then
		ssh "${CI_TRIGGER_SSH_OPTS[@]}" -- "${CI_TRIGGER_USER}@${CI_TRIGGER_HOST}" \
			"${NIXBOT_SSH_ARGV_PREFIX} ${encoded_request}" <"${DIRTY_STAGED_PATCH_FILE}"
	else
		ssh "${CI_TRIGGER_SSH_OPTS[@]}" -- "${CI_TRIGGER_USER}@${CI_TRIGGER_HOST}" \
			"${NIXBOT_SSH_ARGV_PREFIX} ${encoded_request}"
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

is_deploy_style_action() {
	[ "${HOST_ACTION}" = "deploy" ]
}

is_host_build_only_action() {
	[ "${HOST_ACTION}" = "build" ]
}

is_bootstrap_check_action() {
	[ "${ACTION}" = "check-bootstrap" ]
}

is_clean_action() {
	[ "${ACTION}" = "clean" ]
}

is_clear_remote_locks_action() {
	[ "${ACTION}" = "clear-remote-locks" ]
}

# Resolve the source repo root exactly once. Local clean repo runs reuse the
# current checkout as the mirror; ci/explicit `--repo-path` runs use the
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

	printf '%s\n' "$$" >"${lock_root}/pid"
	REPO_ROOT_LOCK_DIR="${lock_root}"
}

release_repo_root_lock() {
	if [ -n "${REPO_ROOT_LOCK_DIR}" ] && [ -d "${REPO_ROOT_LOCK_DIR}" ]; then
		rm -rf "${REPO_ROOT_LOCK_DIR}"
	fi
	REPO_ROOT_LOCK_DIR=""
}

ensure_repo_root_exists() {
	local repo_git_ssh_command=""

	mkdir -p "$(dirname "${REPO_ROOT}")"

	if [ -d "${REPO_ROOT}/.git" ] || [ -f "${REPO_ROOT}/.git" ]; then
		return
	fi

	[ -n "${REPO_URL}" ] ||
		die "Managed repo root is missing and no repo URL is configured; set config.repoUrl in ${NIXBOT_CONFIG_PATH} or pass --repo-url"

	if extract_ssh_endpoint_from_repo_url "${REPO_URL}" >/dev/null; then
		repo_git_ssh_command="$(build_repo_git_ssh_command_for_url "${REPO_URL}")" || return 1
		GIT_SSH_COMMAND="${repo_git_ssh_command}" git clone "${REPO_URL}" "${REPO_ROOT}"
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
	local origin_url="" repo_git_ssh_command=""

	origin_url="$(git -C "${REPO_ROOT}" remote get-url origin 2>/dev/null || true)"
	if [ -z "${origin_url}" ]; then
		origin_url="${REPO_URL}"
	fi

	if extract_ssh_endpoint_from_repo_url "${origin_url}" >/dev/null; then
		repo_git_ssh_command="$(build_repo_git_ssh_command_for_url "${origin_url}")" || return 1
		GIT_SSH_COMMAND="${repo_git_ssh_command}" git -C "${REPO_ROOT}" fetch --prune origin
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
	capture_dirty_staged_patch_stdin
	apply_config_defaults_if_config_available

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
	validate_dirty_staged_base "${target_ref}"

	REPO_WORKTREE_ROOT="${RUNTIME_WORK_DIR}/repo"
	git -C "${REPO_ROOT}" worktree add --detach "${REPO_WORKTREE_ROOT}" "${target_ref}" >/dev/null
	git -C "${REPO_ROOT}" worktree prune >/dev/null 2>&1 || true
	release_repo_root_lock

	overlay_dirty_staged_patch_to_worktree

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
	exec env \
		NIXBOT_REEXECED_FROM_REPO=1 \
		NIXBOT_REPO_ROOT="${REPO_ROOT}" \
		NIXBOT_REPO_WORKTREE_ROOT="${REPO_WORKTREE_ROOT}" \
		NIXBOT_RUNTIME_WORK_DIR="${RUNTIME_WORK_DIR}" \
		NIXBOT_RUNTIME_DIAG_DIR="${NIXBOT_DIAG_DIR}" \
		NIXBOT_CONFIG_OVERRIDE_PATH="${NIXBOT_CONFIG_OVERRIDE_PATH}" \
		bash "${repo_script}" "${request_args[@]}"
}

##### Config / Secrets #####

resolve_config_path() {
	local path="$1"

	if [[ "${path}" == /* ]]; then
		printf '%s\n' "${path}"
		return
	fi

	if [ -f "${path}" ]; then
		readlink -f "${path}"
		return
	fi

	printf '%s/%s\n' "$(pwd -P)" "${path}"
}

load_deploy_config_json() {
	local path="$1" override_path="${2-${NIXBOT_CONFIG_OVERRIDE_PATH:-}}"
	local resolved_path="" resolved_override_path="" expr="" output=""

	resolved_path="$(resolve_config_path "${path}")"
	[ -f "${resolved_path}" ] || die "Deploy config not found: ${path} (resolved: ${resolved_path})"
	if [ -z "${override_path}" ] || [ ! -f "${override_path}" ]; then
		run_supervised_stdout_capture output "" nix eval --json --file "${resolved_path}" || return "$?"
		printf '%s\n' "${output}"
		return
	fi

	resolved_override_path="$(resolve_config_path "${override_path}")"
	# The sibling override is a partial attrset layered over the selected config:
	# nested attrsets merge recursively, while scalar/list values replace the
	# base value.
	expr="
let
  recursiveUpdate = lhs: rhs:
    lhs
    // rhs
    // builtins.mapAttrs (
      name: rhsValue:
        let
          lhsValue = lhs.\${name} or null;
        in
          if builtins.isAttrs lhsValue && builtins.isAttrs rhsValue
          then recursiveUpdate lhsValue rhsValue
          else rhsValue
    ) rhs;
in
  recursiveUpdate (import ${resolved_path}) (import ${resolved_override_path})
"
	run_supervised_stdout_capture output "" nix eval --impure --json --expr "${expr}" || return "$?"
	printf '%s\n' "${output}"
}

apply_config_defaults_if_config_available() {
	local config_path="" config_json=""

	if [ -f "$(resolve_config_path "${NIXBOT_CONFIG_PATH}")" ]; then
		config_path="${NIXBOT_CONFIG_PATH}"
	elif [ -n "${REPO_ROOT:-}" ] && [ -f "${REPO_ROOT%/}/${NIXBOT_CONFIG_PATH}" ]; then
		config_path="${REPO_ROOT%/}/${NIXBOT_CONFIG_PATH}"
	else
		return 0
	fi

	config_json="$(load_deploy_config_json "${config_path}")" || return 0
	apply_config_defaults "${config_json}"
}

derive_groups_json() {
	local config_json="$1"

	jq -c '
    def stable_unique:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    .hosts // {}
    | if type == "object" then . else error("hosts must be an attrset") end
    | to_entries
    | reduce .[] as $host ({};
        (
          ($host.value.groups // [])
          | if type == "array" then .
            else error("host groups must be lists")
            end
          | map(
              if type == "string" and length > 0 then .
              else error("host groups must contain non-empty strings")
              end
            )
          | map(select(startswith("-") | not))
        ) as $groups
        | reduce $groups[] as $group (.;
            .[$group] = ((.[$group] // []) + [$host.key])
          )
      )
    | with_entries(.value |= stable_unique)
  ' <<<"${config_json}"
}

derive_group_dependency_exclusions_json() {
	local config_json="$1"

	jq -c '
    def stable_unique:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    .hosts // {}
    | if type == "object" then . else error("hosts must be an attrset") end
    | to_entries
    | reduce .[] as $host ({};
        (
          ($host.value.groups // [])
          | if type == "array" then .
            else error("host groups must be lists")
            end
          | map(
              if type == "string" and length > 0 then .
              else error("host groups must contain non-empty strings")
              end
            )
          | map(select(startswith("-")) | .[1:])
          | map(
              if length > 0 then .
              else error("negated host groups must include a group name")
              end
            )
        ) as $groups
        | reduce $groups[] as $group (.;
            .[$group] = ((.[$group] // []) + [$host.key])
          )
      )
    | with_entries(.value |= stable_unique)
  ' <<<"${config_json}"
}

init_deploy_settings() {
	local config_json="$1"
	local resolved_config_path=""

	resolved_config_path="$(resolve_config_path "${NIXBOT_CONFIG_PATH}")"
	NIXBOT_CONFIG_DIR="$(cd "$(dirname "${resolved_config_path}")" && pwd -P)"

	{
		read -r NIXBOT_DEFAULT_USER
		read -r NIXBOT_DEFAULT_KEY_PATH
		read -r NIXBOT_DEFAULT_KNOWN_HOSTS
		read -r NIXBOT_DEFAULT_BOOTSTRAP_KEY
		read -r NIXBOT_DEFAULT_BOOTSTRAP_USER
		read -r NIXBOT_DEFAULT_BOOTSTRAP_KEY_PATH
		read -r NIXBOT_DEFAULT_AGE_IDENTITY_KEY
	} < <(jq -r '
    (.config.hostDefaults // {}) as $hostDefaults
    | [
      ($hostDefaults.user // "root"),
      ($hostDefaults.key // ""),
      ($hostDefaults.knownHosts // ""),
      ($hostDefaults.bootstrapKey // ""),
      ($hostDefaults.bootstrapUser // "root"),
      ($hostDefaults.bootstrapKeyPath // ""),
      ($hostDefaults.ageIdentityKey // "")
    ]
    | .[]
	' <<<"${config_json}")
	NIXBOT_HOSTS_JSON="$(jq -c '.hosts // {}' <<<"${config_json}")"
	NIXBOT_GROUPS_JSON="$(derive_groups_json "${config_json}")" || die "Nixbot host groups must be lists of non-empty strings"
	NIXBOT_GROUP_DEPENDENCY_EXCLUSIONS_JSON="$(derive_group_dependency_exclusions_json "${config_json}")" || die "Nixbot host groups must be lists of non-empty strings"
	apply_config_defaults "${config_json}"

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

apply_config_defaults() {
	local config_json="$1" nixbot_config_json="" configured_default_group="" configured_ci_host="" configured_cache_host="" configured_cache_url="" configured_repo_url=""

	nixbot_config_json="$(jq -c '.config // {}' <<<"${config_json}")"

	if [ -z "${GROUPS_RAW}" ] && [ "${HOSTS_EXPLICIT}" -eq 0 ]; then
		configured_default_group="$(
			jq -r '
        .defaultGroup // ""
        | if type == "string" then .
          else error("defaultGroup must be a string")
          end
      ' <<<"${nixbot_config_json}"
		)" || die "Nixbot default group must be a string"
		if [ -n "${configured_default_group}" ]; then
			GROUPS_RAW="${configured_default_group}"
		fi
	fi

	if [ -z "${CI_TRIGGER_HOST}" ]; then
		configured_ci_host="$(jq -r '.ci.host // empty' <<<"${nixbot_config_json}")"
		CI_TRIGGER_HOST="${configured_ci_host}"
	fi

	if [ -z "${BUILD_CACHE_URL}" ]; then
		configured_cache_url="$(jq -r '.buildCache.url // empty' <<<"${nixbot_config_json}")"
		BUILD_CACHE_URL="${configured_cache_url}"
	fi

	if [ -z "${BUILD_CACHE_HOST}" ]; then
		configured_cache_host="$(jq -r '.buildCache.host // empty' <<<"${nixbot_config_json}")"
		BUILD_CACHE_HOST="${configured_cache_host}"
	fi

	if [ -z "${REPO_URL}" ]; then
		configured_repo_url="$(jq -r '.repoUrl // empty' <<<"${nixbot_config_json}")"
		REPO_URL="${configured_repo_url}"
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
		readlink -f "${key_path}"
		return
	fi

	if [ -n "${NIXBOT_CONFIG_DIR}" ] && [ -f "${NIXBOT_CONFIG_DIR}/${key_path}" ]; then
		printf '%s/%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
		return
	fi

	if [ -n "${NIXBOT_CONFIG_DIR}" ] && [ -f "${NIXBOT_CONFIG_DIR}/../${key_path}" ]; then
		printf '%s/../%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
		return
	fi

	if [ -n "${NIXBOT_CONFIG_DIR}" ]; then
		printf '%s/../%s\n' "${NIXBOT_CONFIG_DIR}" "${key_path}"
		return
	fi

	printf '%s\n' "${key_path}"
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
			if age --decrypt -i "${decrypt_identity}" -o "${out_file}" "${src_path}" 2>"${age_stderr_file}"; then
				chmod 600 "${out_file}"
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
	local output=""

	run_supervised_stdout_capture output "" nix eval --json --no-write-lock-file .#nixosConfigurations --apply builtins.attrNames 2>/dev/null || return "$?"
	printf '%s\n' "${output}"
}

##### Host Selection #####

parse_host_selectors_json() {
	local all_hosts_json="$1" raw_selectors="$2" imply_all_on_only_exclusions="$3"
	local token="" selector="" host="" matched="" exclusion=0
	local selected_json="" excluded_json=""
	local -a all_hosts=() selected_hosts=() excluded_hosts=()
	declare -A selected_host_set=()
	declare -A excluded_host_set=()

	if [ -z "${raw_selectors}" ]; then
		jq -cn '{selected: [], excluded: []}'
		return
	fi

	if [ "${raw_selectors}" = "all" ]; then
		jq -cn --argjson selected "${all_hosts_json}" '{selected: $selected, excluded: []}'
		return
	fi

	json_array_to_bash_array "${all_hosts_json}" all_hosts

	while IFS= read -r token; do
		[ -n "${token}" ] || continue

		exclusion=0
		selector="${token}"
		if [[ "${token}" == '-'* ]]; then
			exclusion=1
			selector="${token#-}"
			[ -n "${selector}" ] || selector="${token}"
		fi

		if [ "${selector}" = "all" ]; then
			for host in "${all_hosts[@]}"; do
				if [ "${exclusion}" -eq 1 ]; then
					if [ -z "${excluded_host_set["${host}"]+x}" ]; then
						excluded_host_set["${host}"]=1
						excluded_hosts+=("${host}")
					fi
				elif [ -z "${selected_host_set["${host}"]+x}" ]; then
					selected_host_set["${host}"]=1
					selected_hosts+=("${host}")
				fi
			done
			continue
		fi

		if host_token_is_glob "${selector}"; then
			matched=0
			for host in "${all_hosts[@]}"; do
				# shellcheck disable=SC2053
				if [[ "${host}" == ${selector} ]]; then
					matched=1
					if [ "${exclusion}" -eq 1 ]; then
						if [ -z "${excluded_host_set["${host}"]+x}" ]; then
							excluded_host_set["${host}"]=1
							excluded_hosts+=("${host}")
						fi
					elif [ -z "${selected_host_set["${host}"]+x}" ]; then
						selected_host_set["${host}"]=1
						selected_hosts+=("${host}")
					fi
				fi
			done
			if [ "${matched}" -eq 0 ]; then
				if [ "${exclusion}" -eq 1 ]; then
					if [ -z "${excluded_host_set["${selector}"]+x}" ]; then
						excluded_host_set["${selector}"]=1
						excluded_hosts+=("${selector}")
					fi
				elif [ -z "${selected_host_set["${selector}"]+x}" ]; then
					selected_host_set["${selector}"]=1
					selected_hosts+=("${selector}")
				fi
			fi
			continue
		fi

		if [ "${exclusion}" -eq 1 ]; then
			if [ -z "${excluded_host_set["${selector}"]+x}" ]; then
				excluded_host_set["${selector}"]=1
				excluded_hosts+=("${selector}")
			fi
			continue
		fi

		if [ -z "${selected_host_set["${selector}"]+x}" ]; then
			selected_host_set["${selector}"]=1
			selected_hosts+=("${selector}")
		fi
	done < <(emit_normalized_hosts "${raw_selectors}")

	if [ "${imply_all_on_only_exclusions}" -eq 1 ] && [ "${#selected_hosts[@]}" -eq 0 ] && [ "${#excluded_hosts[@]}" -gt 0 ]; then
		for host in "${all_hosts[@]}"; do
			if [ -z "${selected_host_set["${host}"]+x}" ]; then
				selected_host_set["${host}"]=1
				selected_hosts+=("${host}")
			fi
		done
	fi

	selected_json="$(bash_args_to_json_array "${selected_hosts[@]}")"
	excluded_json="$(bash_args_to_json_array "${excluded_hosts[@]}")"

	jq -cn --argjson selected "${selected_json}" --argjson excluded "${excluded_json}" \
		'{selected: $selected, excluded: $excluded}'
}

group_exists() {
	local group="$1"
	jq -e --arg group "${group}" 'has($group)' <<<"${NIXBOT_GROUPS_JSON}" >/dev/null
}

group_hosts_for() {
	local group="$1"
	jq -r --arg group "${group}" '
    .[$group] | if type == "array" then .[] else empty end
  ' <<<"${NIXBOT_GROUPS_JSON}"
}

group_dependency_exclusions_for() {
	local group="$1"
	jq -r --arg group "${group}" '
    .[$group] | if type == "array" then .[] else empty end
  ' <<<"${NIXBOT_GROUP_DEPENDENCY_EXCLUSIONS_JSON}"
}

validate_group_shapes() {
	local invalid=""

	invalid="$(jq -r '
    to_entries
    | map(select(.value | type != "array") | .key)
    | join(", ")
  ' <<<"${NIXBOT_GROUPS_JSON}")"
	[ -z "${invalid}" ] || die "Nixbot groups must be direct host lists; invalid groups: ${invalid}"
}

append_group_hosts() {
	local group="$1"
	local host=""

	group_exists "${group}" || die "Unknown group requested: ${group}"
	if [ -n "${GROUP_SELECTED_SET["${group}"]+x}" ]; then
		return 0
	fi

	GROUP_SELECTED_SET["${group}"]=1
	GROUP_SELECTED_NAMES+=("${group}")

	while IFS= read -r host; do
		[ -n "${host}" ] || continue
		if [ -z "${GROUP_SELECTED_HOST_SET["${host}"]+x}" ]; then
			GROUP_SELECTED_HOST_SET["${host}"]=1
			GROUP_SELECTED_HOSTS+=("${host}")
		fi
	done < <(group_hosts_for "${group}")

	while IFS= read -r host; do
		[ -n "${host}" ] || continue
		if [ -z "${GROUP_DEPENDENCY_EXCLUDED_HOST_SET["${host}"]+x}" ]; then
			GROUP_DEPENDENCY_EXCLUDED_HOST_SET["${host}"]=1
			GROUP_DEPENDENCY_EXCLUDED_HOSTS+=("${host}")
		fi
	done < <(group_dependency_exclusions_for "${group}")
}

parse_group_selectors_json() {
	local token="" selected_json="" groups_json="" dependency_excluded_json=""

	declare -gA GROUP_SELECTED_HOST_SET
	declare -gA GROUP_SELECTED_SET
	declare -gA GROUP_DEPENDENCY_EXCLUDED_HOST_SET
	GROUP_SELECTED_HOSTS=()
	GROUP_SELECTED_NAMES=()
	GROUP_DEPENDENCY_EXCLUDED_HOSTS=()
	GROUP_SELECTED_HOST_SET=()
	GROUP_SELECTED_SET=()
	GROUP_DEPENDENCY_EXCLUDED_HOST_SET=()
	validate_group_shapes

	while IFS= read -r token; do
		[ -n "${token}" ] || continue
		append_group_hosts "${token}"
	done < <(emit_normalized_hosts "${GROUPS_RAW}")

	selected_json="$(bash_args_to_json_array "${GROUP_SELECTED_HOSTS[@]}")"
	groups_json="$(bash_args_to_json_array "${GROUP_SELECTED_NAMES[@]}")"
	dependency_excluded_json="$(bash_args_to_json_array "${GROUP_DEPENDENCY_EXCLUDED_HOSTS[@]}")"
	jq -cn --argjson selected "${selected_json}" --argjson groups "${groups_json}" --argjson dependencyExcluded "${dependency_excluded_json}" \
		'{selected: $selected, groups: $groups, dependencyExcluded: $dependencyExcluded}'
}

merge_selection_json() {
	local group_selection_json="$1" host_selection_json="$2"

	jq -cn --argjson groupSelection "${group_selection_json}" --argjson hostSelection "${host_selection_json}" '
    def stable_unique:
      reduce .[] as $item ([]; if index($item) then . else . + [$item] end);
    {
      selected: ((($groupSelection.selected // []) + ($hostSelection.selected // [])) | stable_unique),
      excluded: ($hostSelection.excluded // []),
      dependencyExcluded: ($groupSelection.dependencyExcluded // []),
      groups: ($groupSelection.groups // [])
    }
  '
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
	strict | optional | skip)
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

host_target_for() {
	local node="$1"

	jq -r --arg h "${node}" --arg default "${node}" '
    (.[$h].target // "") as $target |
    if $target == "" then $default else $target end
  ' <<<"${NIXBOT_HOSTS_JSON}"
}

host_parent_resource_for() {
	local node="$1"
	jq -r --arg h "${node}" '.[$h].resourceId // $h' <<<"${NIXBOT_HOSTS_JSON}"
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

build_host_cache_url_for() {
	local build_host="$1"

	if [ -n "${BUILD_CACHE_URL}" ] && build_host_matches_cache_host "${build_host}"; then
		printf '%s\n' "${BUILD_CACHE_URL}"
	fi
}

require_build_host_cache_config() {
	local build_host="$1" cache_url=""

	cache_url="$(build_host_cache_url_for "${build_host}")"

	if [ -n "${cache_url}" ]; then
		return 0
	fi

	if [ -z "${BUILD_CACHE_URL}" ] && [ -z "${BUILD_CACHE_HOST}" ]; then
		die "Remote deploy build on ${build_host} requires config.buildCache.url" \
			"and config.buildCache.host in ${NIXBOT_CONFIG_PATH}"
	fi
	if [ -z "${BUILD_CACHE_URL}" ]; then
		die "Remote deploy build on ${build_host} requires config.buildCache.url" \
			"in ${NIXBOT_CONFIG_PATH} (config.buildCache.host='${BUILD_CACHE_HOST}')"
	fi
	if [ -z "${BUILD_CACHE_HOST}" ]; then
		die "Remote deploy build on ${build_host} requires config.buildCache.host" \
			"in ${NIXBOT_CONFIG_PATH} for cache '${BUILD_CACHE_URL}'"
	fi

	die "Remote deploy build on ${build_host} cannot use cache '${BUILD_CACHE_URL}':" \
		"config.buildCache.host is '${BUILD_CACHE_HOST}'." \
		"Use --build-host ${BUILD_CACHE_HOST} or set --build-cache-host ${build_host}."
}

remote_build_deploy_uses_local_relay() {
	[ "${BUILD_HOST}" != "local" ] && [ "$(effective_build_host_deploy_mode)" = "local-copy" ]
}

resolved_target_host_for_role() {
	local role_host="$1" target_info="" target=""

	target_info="$(resolve_deploy_target "${role_host}")" || return 1
	target="$(jq -r '.target // empty' <<<"${target_info}")"
	[ -n "${target}" ] || target="${role_host}"
	ssh_host_from_target "${target}"
}

build_host_matches_configured_host() {
	local build_host="$1" configured_host="$2" build_target="" configured_target=""

	[ -n "${configured_host}" ] || return 1
	[ "${build_host}" = "${configured_host}" ] && return 0

	build_target="$(resolved_target_host_for_role "${build_host}" 2>/dev/null || true)"
	configured_target="$(resolved_target_host_for_role "${configured_host}" 2>/dev/null || true)"

	[ -n "${build_target}" ] &&
		[ -n "${configured_target}" ] &&
		[ "${build_target}" = "${configured_target}" ]
}

build_host_matches_cache_host() {
	local build_host="${1:-${BUILD_HOST}}"

	build_host_matches_configured_host "${build_host}" "${BUILD_CACHE_HOST}"
}

effective_build_host_deploy_mode() {
	case "${BUILD_HOST_DEPLOY_MODE}" in
	cache | local-copy)
		printf '%s\n' "${BUILD_HOST_DEPLOY_MODE}"
		;;
	auto)
		if build_host_matches_cache_host; then
			printf 'cache\n'
		else
			printf 'local-copy\n'
		fi
		;;
	esac
}

copy_remote_build_closure_to_local_store() {
	local node="$1" store_uri="$2" nix_sshopts="$3" out_path="$4" cache_url="" remote_copy_output="" trusted_public_keys=""
	local -a copy_cmd=()

	cache_url="$(build_host_cache_url_for "${BUILD_HOST}")"
	copy_cmd=(nix)
	if [ -n "${cache_url}" ]; then
		trusted_public_keys="$(target_trusted_public_keys_for_copy "${node}")" || return 1
		append_extra_trusted_public_keys_option "${trusted_public_keys}" copy_cmd
		copy_cmd+=(copy --from "${cache_url}" "${out_path}")
		nix_sshopts=""
		echo "Copying built closure from ${BUILD_HOST} cache to local store: ${out_path}" >&2
	else
		copy_cmd+=(copy --from "${store_uri}" "${out_path}")
		echo "Copying built closure from ${BUILD_HOST} to local store: ${out_path}" >&2
	fi

	if ! run_remote_store_command_with_retry \
		remote_copy_output \
		"Remote build copy from ${BUILD_HOST}" \
		"${nix_sshopts}" \
		"${copy_cmd[@]}"; then
		echo "Failed to copy built closure from ${BUILD_HOST}: ${out_path}" >&2
		return 1
	fi
	if ! nix path-info --closure-size --human-readable "${out_path}" >&2; then
		echo "Unable to resolve closure size for ${node}: ${out_path}" >&2
		return 1
	fi
}

wait_before_host_phase() {
	local node="$1" phase="$2" wait_secs=""

	wait_secs="$(host_wait_seconds "${node}")"
	if [ "${wait_secs}" -gt 0 ] 2>/dev/null; then
		echo "[${node}] ${phase} | waiting ${wait_secs}s before ${phase}" >&2
		sleep_for_retry_or_signal "${wait_secs}" || return "$?"
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

	bash_args_to_json_array "${expanded_hosts[@]}"
}

order_selected_hosts_json() {
	local selected_json="$1" all_hosts_json="$2" node="" dep="" progress="" ci_host="${CI_TRIGGER_HOST}"
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
			if [ "${PRIORITIZE_CI_FIRST}" -eq 1 ] && [ "${node}" = "${ci_host}" ]; then
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

	if [ "${PRIORITIZE_CI_FIRST}" -eq 1 ] && [ -n "${selected_host_set["${ci_host}"]+x}" ]; then
		emitted_host_set["${ci_host}"]=1
		ordered_hosts+=("${ci_host}")
		while IFS= read -r dep; do
			[ -n "${dep}" ] || continue
			indegree["${dep}"]=$((indegree["${dep}"] - 1))
		done <<<"${dependents["${ci_host}"]:-}"
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

	bash_args_to_json_array "${ordered_hosts[@]}"
}

selected_host_levels_json() {
	local selected_json="$1" node="" dep="" dep_level="" node_level=""
	local max_level="" level="" ci_host="${CI_TRIGGER_HOST}"
	local -a selected_hosts=()
	declare -A selected_host_set=()
	declare -A host_level=()

	json_array_to_bash_array "${selected_json}" selected_hosts
	json_array_to_bash_set "${selected_json}" selected_host_set

	max_level=0
	for node in "${selected_hosts[@]}"; do
		[ -n "${node}" ] || continue
		if [ "${PRIORITIZE_CI_FIRST}" -eq 1 ] && [ "${node}" = "${ci_host}" ]; then
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

		if [ "${PRIORITIZE_CI_FIRST}" -eq 1 ] && [ -n "${selected_host_set["${ci_host}"]+x}" ] && [ "${node_level}" -lt 1 ]; then
			node_level=1
		fi

		host_level["${node}"]="${node_level}"
		if [ "${node_level}" -gt "${max_level}" ]; then
			max_level="${node_level}"
		fi
	done

	{
		for ((level = 0; level <= max_level; level++)); do
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

validate_excluded_hosts() {
	local excluded_json="$1" all_hosts_json="$2" invalid=""

	invalid="$(jq -n --argjson excluded "${excluded_json}" --argjson all "${all_hosts_json}" '$excluded - $all')"

	if [ "$(jq 'length' <<<"${invalid}")" -gt 0 ]; then
		die "Unknown hosts excluded: $(jq -r 'join(", ")' <<<"${invalid}")"
	fi
}

apply_host_exclusions_json() {
	local selected_json="$1" excluded_json="$2"

	jq -cn --argjson selected "${selected_json}" --argjson excluded "${excluded_json}" '$selected - $excluded'
}

apply_dependency_exclusions_json() {
	local selected_json="$1" direct_json="$2" excluded_json="$3"

	jq -cn --argjson selected "${selected_json}" --argjson direct "${direct_json}" --argjson excluded "${excluded_json}" '
    def dependency_excluded($host):
      (($excluded | index($host)) != null) and (($direct | index($host)) == null);
    $selected | map(select(dependency_excluded(.) | not))
  '
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

	bash_args_to_json_array "${runnable_hosts[@]}"
}

resolve_selected_hosts_json() {
	local all_hosts_json="$1" group_selection_json="" host_selection_json="" selection_json="" direct_selected_json="" selected_json="" excluded_json="" dependency_excluded_json=""
	local parse_hosts=0 imply_all_on_only_exclusions=1

	if [ -n "${GROUPS_RAW}" ]; then
		group_selection_json="$(parse_group_selectors_json)" || return "$?"
		imply_all_on_only_exclusions=0
	fi
	if [ "${HOSTS_EXPLICIT}" -eq 1 ] || [ -z "${GROUPS_RAW}" ]; then
		parse_hosts=1
	fi
	if [ "${parse_hosts}" -eq 1 ]; then
		host_selection_json="$(parse_host_selectors_json "${all_hosts_json}" "${HOSTS_RAW}" "${imply_all_on_only_exclusions}")" || return "$?"
	else
		host_selection_json="$(jq -cn '{selected: [], excluded: []}')"
	fi
	if [ -z "${group_selection_json}" ]; then
		group_selection_json="$(jq -cn '{selected: [], groups: []}')"
	fi

	selection_json="$(merge_selection_json "${group_selection_json}" "${host_selection_json}")"
	selected_json="$(jq -c '.selected' <<<"${selection_json}")"
	direct_selected_json="${selected_json}"
	excluded_json="$(jq -c '.excluded' <<<"${selection_json}")"
	dependency_excluded_json="$(jq -c '.dependencyExcluded' <<<"${selection_json}")"
	validate_selected_hosts "${selected_json}" "${all_hosts_json}"
	validate_excluded_hosts "${excluded_json}" "${all_hosts_json}"
	validate_excluded_hosts "${dependency_excluded_json}" "${all_hosts_json}"
	selected_json="$(apply_host_exclusions_json "${selected_json}" "${excluded_json}")"
	validate_selected_hosts "${selected_json}" "${all_hosts_json}"
	direct_selected_json="${selected_json}"
	if is_clear_remote_locks_action; then
		validate_selected_host_execution_policies "${direct_selected_json}"
		order_selected_hosts_json "${direct_selected_json}" "${all_hosts_json}"
		return
	fi
	selected_json="$(expand_selected_hosts_json "${selected_json}" "${all_hosts_json}")"
	selected_json="$(apply_dependency_exclusions_json "${selected_json}" "${direct_selected_json}" "${dependency_excluded_json}")"
	selected_json="$(apply_host_exclusions_json "${selected_json}" "${excluded_json}")"
	validate_selected_hosts "${selected_json}" "${all_hosts_json}"
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
	if ! prc_selected_json_out_ref="$(resolve_selected_hosts_json "${all_hosts_json}")"; then
		exit 1
	fi
}

emit_annotated_selected_hosts() {
	local selected_json="$1" node="" mode="" wait_secs="" parent_host="" target="" annotation=""
	local -a selected_hosts=()

	json_array_to_bash_array "${selected_json}" selected_hosts

	for node in "${selected_hosts[@]}"; do
		[ -n "${node}" ] || continue
		if host_skip_enabled "${node}"; then
			continue
		fi
		target="$(host_target_for "${node}")"
		annotation="target: ${target}"
		mode="$(host_deploy_mode "${node}")"
		if [ "${mode}" != "strict" ]; then
			annotation="${annotation}, deploy: ${mode}"
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
			printf '%s (%s)\n' "${node}" "${annotation}"
		else
			printf '%s\n' "${node}"
		fi
	done
}

print_selected_hosts_block() {
	local selected_json="$1"
	local -a annotated_hosts=()

	mapfile -t annotated_hosts < <(emit_annotated_selected_hosts "${selected_json}")
	print_host_block "Hosts" "${annotated_hosts[@]}"
}

print_selected_groups_block() {
	local -a selected_groups=()

	[ -n "${GROUPS_RAW}" ] || return 0
	mapfile -t selected_groups < <(emit_normalized_hosts "${GROUPS_RAW}")
	print_host_block "Groups" "${selected_groups[@]}"
}

print_groups_block() {
	local group="" host=""
	local -a groups=() hosts=() ungrouped_hosts=()

	echo "Groups:" >&2
	mapfile -t groups < <(jq -r 'keys[]' <<<"${NIXBOT_GROUPS_JSON}")
	if [ "${#groups[@]}" -eq 0 ]; then
		echo "  - (none)" >&2
	fi

	for group in "${groups[@]}"; do
		echo "  - ${group}" >&2
		mapfile -t hosts < <(jq -r --arg group "${group}" '
      .[$group] | if type == "array" then .[] else empty end
    ' <<<"${NIXBOT_GROUPS_JSON}")
		if [ "${#hosts[@]}" -eq 0 ]; then
			echo "    - (none)" >&2
			continue
		fi
		for host in "${hosts[@]}"; do
			echo "    - ${host}" >&2
		done
	done

	mapfile -t ungrouped_hosts < <(jq -r '
    to_entries[]
    | select((.value.groups // []) | length == 0)
    | .key
  ' <<<"${NIXBOT_HOSTS_JSON}")
	if [ "${#ungrouped_hosts[@]}" -gt 0 ]; then
		echo "  - (ungrouped)" >&2
		for host in "${ungrouped_hosts[@]}"; do
			echo "    - ${host}" >&2
		done
	fi
}

print_config_override_line() {
	if [ -n "${NIXBOT_CONFIG_OVERRIDE_PATH:-}" ] && [ -f "${NIXBOT_CONFIG_OVERRIDE_PATH}" ]; then
		echo "Config override: ${NIXBOT_CONFIG_OVERRIDE_PATH}" >&2
	fi
}

log_run_context() {
	local selected_json="$1"

	log_section "nixbot"
	echo "Version: ${NIXBOT_VERSION}" >&2
	echo "Action: ${ACTION}" >&2
	echo "Started: ${NIXBOT_RUN_STARTED_AT}" >&2
	print_config_override_line
	print_selected_groups_block
	print_selected_hosts_block "${selected_json}"
	if is_deploy_style_action; then
		echo "Goal: ${GOAL}" >&2
		echo "Build host: ${BUILD_HOST}" >&2
		if [ "${BUILD_HOST}" != "local" ]; then
			if [ "${BUILD_HOST_DEPLOY_MODE}" = "auto" ]; then
				echo "Build-host deploy mode: auto ($(effective_build_host_deploy_mode))" >&2
			else
				echo "Build-host deploy mode: ${BUILD_HOST_DEPLOY_MODE}" >&2
			fi
		fi
	fi
	echo "Decrypt identities: $(announce_age_decrypt_identity_candidates)" >&2
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
      proxyJump: ($cfg.proxyJump // ""),
      proxyCommand: ($cfg.proxyCommand // "")
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
        ($cfg.proxyCommand // "") as $proxyCommand |
        resolve_chain($next; $visited + [$h]) + [{
          node: $h,
          target: $target,
          port: $port,
          connectTarget: (if $user == "" then $target else "\($user)@\($target)" end),
          connectPort: $port,
          keyPath: $keyPath,
          proxyCommand: $proxyCommand
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
		printf '%s\n' "${known_hosts}" >"${known_hosts_file}"
	else
		: >"${known_hosts_file}"
	fi

	chmod 600 "${known_hosts_file}"
	printf '%s\n' "${known_hosts_file}"
}

run_ssh_keyscan() {
	ssh-keyscan -T "${NIXBOT_SSH_KEYSCAN_TIMEOUT_SECS}" "$@"
}

run_quiet_ssh_keyscan() {
	run_ssh_keyscan "$@" 2>/dev/null
}

ensure_known_host() {
	local host="$1" known_hosts="$2" known_hosts_file="$3"

	if [ -n "${known_hosts}" ]; then
		return
	fi

	if ! ssh-keygen -F "${host}" -f "${known_hosts_file}" | grep -q ' ssh-ed25519 '; then
		run_ssh_keyscan -t ed25519 "${host}" >>"${known_hosts_file}" 2>/dev/null || true
	fi
	if ! ssh-keygen -F "${host}" -f "${known_hosts_file}" >/dev/null 2>&1; then
		run_ssh_keyscan "${host}" >>"${known_hosts_file}" 2>/dev/null || true
	fi
}

extract_ssh_endpoint_from_repo_url() {
	local repo_url="$1" host_part="" repo_host="" repo_port="22"

	case "${repo_url}" in
	ssh://*)
		host_part="${repo_url#ssh://}"
		host_part="${host_part#*@}"
		host_part="${host_part%%/*}"
		if [[ "${host_part}" == \[*\]:* ]]; then
			repo_host="${host_part#\[}"
			repo_host="${repo_host%%]*}"
			repo_port="${host_part##*:}"
		elif [[ "${host_part}" == \[*\] ]]; then
			repo_host="${host_part#\[}"
			repo_host="${repo_host%\]}"
		else
			repo_host="${host_part%%:*}"
			if [[ "${host_part}" == *:* ]]; then
				repo_port="${host_part##*:}"
			fi
		fi
		;;
	*@*:*)
		repo_host="${repo_url#*@}"
		repo_host="${repo_host%%:*}"
		;;
	*)
		return 1
		;;
	esac

	[ -n "${repo_host}" ] || return 1
	printf '%s\n%s\n' "${repo_host}" "${repo_port}"
}

ensure_repo_known_hosts_file_for_url() {
	local repo_url="$1" repo_host="" repo_port="" safe_host="" known_hosts_file=""
	local scanned_known_hosts=""

	{
		read -r repo_host
		read -r repo_port
	} < <(extract_ssh_endpoint_from_repo_url "${repo_url}") || return 1

	ensure_tmp_dir
	safe_host="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${repo_host}")"
	known_hosts_file="${TMP_SSH_DIR}/${REPO_KNOWN_HOSTS_PREFIX}.${safe_host}"

	if [ ! -s "${known_hosts_file}" ]; then
		if [ -n "${repo_port}" ] && [ "${repo_port}" != "22" ]; then
			run_supervised_stdout_capture scanned_known_hosts "" run_quiet_ssh_keyscan -H -p "${repo_port}" "${repo_host}" || true
		else
			run_supervised_stdout_capture scanned_known_hosts "" run_quiet_ssh_keyscan -H "${repo_host}" || true
		fi
		[ -n "${scanned_known_hosts}" ] || {
			echo "Could not determine repo host key for ${repo_host} from ${repo_url}" >&2
			return 1
		}
		printf '%s\n' "${scanned_known_hosts}" >"${known_hosts_file}"
		chmod 600 "${known_hosts_file}"
	fi

	printf '%s\n' "${known_hosts_file}"
}

build_repo_git_ssh_command_for_url() {
	local repo_url="$1" known_hosts_file="" git_ssh_command="" key_path=""
	local -a repo_ssh_key_paths=()

	known_hosts_file="$(ensure_repo_known_hosts_file_for_url "${repo_url}")" || return 1

	printf -v git_ssh_command \
		'ssh -F %q -o GlobalKnownHostsFile=%q -o UserKnownHostsFile=%q -o StrictHostKeyChecking=yes' \
		"${SSH_NULL_CONFIG_FILE}" \
		"${SSH_NULL_KNOWN_HOSTS_FILE}" \
		"${known_hosts_file}"

	IFS=':' read -r -a repo_ssh_key_paths <<<"${REPO_SSH_KEY_PATHS}"
	for key_path in "${repo_ssh_key_paths[@]}"; do
		[ -n "${key_path}" ] || continue
		[ -f "${key_path}" ] || continue
		printf -v git_ssh_command '%s -i %q -o IdentitiesOnly=yes' \
			"${git_ssh_command}" \
			"${key_path}"
	done

	printf '%s\n' "${git_ssh_command}"
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
	on | true | 1 | yes)
		return 0
		;;
	off | false | 0 | no)
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

can_execute_self_target_locally_as_deploy_user() {
	local deploy_user="$1"

	[ -n "${deploy_user}" ] || return 1
	[ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "${deploy_user}" ]
}

self_target_notice_emitted() {
	local notice_key="$1"

	line_state_contains "self-target-notices.keys" "${notice_key}" SELF_TARGET_NOTICE_KEYS
}

mark_self_target_notice_emitted() {
	local notice_key="$1"

	line_state_mark "self-target-notices.keys" "${notice_key}" SELF_TARGET_NOTICE_KEYS
}

emit_self_target_notice_once() {
	local notice_key="$1" notice_message="$2"

	if line_state_mark_new "self-target-notices.keys" "${notice_key}" SELF_TARGET_NOTICE_KEYS; then
		echo "${notice_message}" >&2
	fi
}

mark_bootstrap_ready() {
	local node="$1"

	line_state_mark "bootstrap-ready.nodes" "${node}" BOOTSTRAP_READY_NODES
}

is_bootstrap_ready() {
	local node="$1"

	line_state_contains "bootstrap-ready.nodes" "${node}" BOOTSTRAP_READY_NODES
}

mark_primary_ready() {
	local node="$1"

	line_state_mark "primary-ready.nodes" "${node}" PRIMARY_READY_NODES
}

clear_primary_ready() {
	local node="$1"

	[ -n "${node}" ] || return 0

	clear_control_master_socket "${node}" primary
	clear_control_master_socket "${node}" bootstrap
	line_state_clear "primary-ready.nodes" "${node}" PRIMARY_READY_NODES
}

is_primary_ready() {
	local node="$1"

	line_state_contains "primary-ready.nodes" "${node}" PRIMARY_READY_NODES
}

check_bootstrap_via_forced_command() {
	local node="$1" ssh_target="$2"
	local -a ssh_opts=("${@:3}") check_ssh_opts=() check_remote_cmd=()
	local check_output="" check_key_file="" remote_config_path=""
	local i="" opt="" skip_next=0 use_override_key=0

	# Forced-command ingress may require a key different from the deploy key.
	if [ -n "${NIXBOT_CI_KEY_PATH_OVERRIDE}" ]; then
		ensure_tmp_dir
		if ! check_key_file="$(resolve_runtime_key_file "${NIXBOT_CI_KEY_PATH_OVERRIDE}" 1)"; then
			return 1
		fi
		if [ ! -f "${check_key_file}" ]; then
			echo "Forced-command key file not found: ${NIXBOT_CI_KEY_PATH_OVERRIDE} (resolved: ${check_key_file})" >&2
			return 1
		fi
		use_override_key=1
	fi

	if [ "${use_override_key}" -eq 1 ]; then
		for ((i = 0; i < ${#ssh_opts[@]}; i++)); do
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
			-oIdentitiesOnly=* | IdentitiesOnly=*)
				continue
				;;
			*)
				check_ssh_opts+=("${opt}")
				;;
			esac
		done
		check_ssh_opts=(-i "${check_key_file}" -o IdentitiesOnly=yes "${check_ssh_opts[@]}")
	else
		check_ssh_opts=("${ssh_opts[@]}")
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
			echo "Cannot forward absolute config path for bootstrap check: ${NIXBOT_CONFIG_PATH}" >&2
			return 1
		fi
		check_remote_cmd+=(--config "${remote_config_path}")
	fi

	if retry_transport_capture \
		check_output \
		"Bootstrap check for ${node}" \
		"" \
		ssh \
		"${check_ssh_opts[@]}" \
		"${ssh_target}" \
		"${check_remote_cmd[@]}"; then
		echo "==> Bootstrap check validated remote nixbot access for ${node}"
		return 0
	fi

	if [[ "${check_output}" == *"Unsupported action: check-bootstrap"* ]] || [[ "${check_output}" == *"invalid action"* ]]; then
		echo "==> Remote bootstrap check entrypoint is on an older revision (no check-bootstrap action); treating auth as valid for ${node}"
		return 0
	fi

	echo "==> Bootstrap check failed for ${node}; continuing with bootstrap injection fallback" >&2
	printf '%s\n' "${check_output}" >&2
	return 1
}

inject_bootstrap_nixbot_key() {
	local node="$1" bootstrap_ssh_target="$2" bootstrap_nixbot_key_path="$3"
	local -a bootstrap_ssh_opts=("${@:4}")
	local bootstrap_key_file="" bootstrap_pub_file="" remote_tmp="" expected_bootstrap_fpr="" remote_check_rc=0
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
	bootstrap_pub_file="$(mktemp "${NIXBOT_TMP_DIR}/nixbot-bootstrap-pub.${node}.XXXXXX")"
	if ! ssh-keygen -y -f "${bootstrap_key_file}" >"${bootstrap_pub_file}"; then
		echo "Unable to derive bootstrap public key for ${node}: ${bootstrap_nixbot_key_path}" >&2
		rm -f "${bootstrap_pub_file}"
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
		if ! ensure_bootstrap_nixbot_authorized_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_pub_file}" "${bootstrap_ssh_opts[@]}"; then
			rm -f "${bootstrap_pub_file}"
			return 1
		fi
		rm -f "${bootstrap_pub_file}"
		return
	else
		remote_check_rc="$?"
		if [ "${remote_check_rc}" -eq 255 ]; then
			echo "Unable to verify bootstrap key for ${node}; bootstrap target ${bootstrap_ssh_target} is unreachable" >&2
			rm -f "${bootstrap_pub_file}"
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
		rm -f "${bootstrap_pub_file}"
		return 1
	fi
	if ! ensure_bootstrap_nixbot_authorized_key "${node}" "${bootstrap_ssh_target}" "${bootstrap_pub_file}" "${bootstrap_ssh_opts[@]}"; then
		rm -f "${bootstrap_pub_file}"
		return 1
	fi
	rm -f "${bootstrap_pub_file}"
}

ensure_bootstrap_nixbot_authorized_key() {
	local node="$1" bootstrap_ssh_target="$2" bootstrap_pub_file="$3"
	local -a bootstrap_ssh_opts=("${@:4}")

	# shellcheck disable=SC2016
	if ! ssh "${bootstrap_ssh_opts[@]}" "${bootstrap_ssh_target}" \
		"authorized_keys_path='${REMOTE_NIXBOT_AUTHORIZED_KEYS}'" '
set -euo pipefail
public_key="$(cat)"
if sudo test -f "${authorized_keys_path}" && sudo grep -qxF "${public_key}" "${authorized_keys_path}"; then
	exit 0
fi
tmp="$(mktemp)"
trap '\''rm -f "${tmp}"'\'' EXIT
if sudo test -f "${authorized_keys_path}"; then
	sudo cat "${authorized_keys_path}" >"${tmp}"
fi
printf "%s\n" "${public_key}" >>"${tmp}"
sudo install -D -m 0444 -o root -g root "${tmp}" "${authorized_keys_path}"
' <"${bootstrap_pub_file}"; then
		echo "Unable to ensure bootstrap nixbot authorized key for ${node}" >&2
		return 1
	fi
}

_remote_install_managed_file() {
	local remote_base="$1" remote_tmp="$2" remote_dest="$3" remote_dir="$4"
	local remote_dir_mode="$5" remote_file_mode="$6"
	local before_install_cmd="${7:-}" after_install_cmd="${8:-}" extra_vars="${9:-}"
	local remote_runtime_path="/run/wrappers/bin:/run/current-system/sw/bin"

	if [ -n "${extra_vars}" ]; then
		eval "${extra_vars}"
	fi

	export PATH="${remote_runtime_path}${PATH:+:${PATH}}"
	if ! command -v sudo >/dev/null 2>&1; then
		echo "sudo is required to install ${remote_dest}" >&2
		return 1
	fi

	sudo install -d -m 0755 "${remote_base}"
	sudo install -d -m "${remote_dir_mode}" "${remote_dir}"
	if [ -n "${before_install_cmd}" ]; then
		eval "${before_install_cmd}"
	fi
	sudo install -m "${remote_file_mode}" "${remote_tmp}" "${remote_dest}"
	rm -f "${remote_tmp}"
	if [ -n "${after_install_cmd}" ]; then
		eval "${after_install_cmd}"
	fi
	return 0
}

build_remote_install_file_cmd() {
	local remote_tmp="$1" remote_dest="$2" remote_dir="$3"
	local remote_dir_mode="$4" remote_file_mode="$5"
	local before_install_cmd="${6:-}" after_install_cmd="${7:-}" extra_vars="${8:-}"
	local invoke_cmd=""

	printf -v invoke_cmd '_remote_install_managed_file %q %q %q %q %q %q %q %q %q' \
		"${REMOTE_NIXBOT_BASE}" \
		"${remote_tmp}" \
		"${remote_dest}" \
		"${remote_dir}" \
		"${remote_dir_mode}" \
		"${remote_file_mode}" \
		"${before_install_cmd}" \
		"${after_install_cmd}" \
		"${extra_vars}"

	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_install_managed_file
}

_remote_check_file_value() {
	local remote_dest="$1" expected_value="$2" read_cmd="$3" sudo_cmd="$4"
	local current=""
	local remote_runtime_path="/run/wrappers/bin:/run/current-system/sw/bin"
	local remote_bin_dir="/run/current-system/sw/bin"
	local remote_sh="${remote_bin_dir}/sh"

	export PATH="${remote_runtime_path}${PATH:+:${PATH}}"
	if ! command -v sudo >/dev/null 2>&1; then
		echo "sudo is required to validate ${remote_dest}" >&2
		return 1
	fi

	current="$(
		DEST="${remote_dest}" \
			${sudo_cmd} env PATH="${remote_runtime_path}" DEST="${remote_dest}" "${remote_sh}" -c "${read_cmd}" \
			2>/dev/null || true
	)"
	[ "${current}" = "${expected_value}" ]
}

build_remote_file_value_check_cmd() {
	local remote_dest="$1" expected_value="$2" read_cmd="$3" ask_sudo_password="${4:-0}"
	local sudo_cmd="sudo -n" invoke_cmd=""

	if [ "${ask_sudo_password}" -eq 1 ]; then
		sudo_cmd="sudo"
	fi

	printf -v invoke_cmd '_remote_check_file_value %q %q %q %q' \
		"${remote_dest}" \
		"${expected_value}" \
		"${read_cmd}" \
		"${sudo_cmd}"

	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_check_file_value
}

run_target_command() {
	local local_exec="$1" ssh_target="$2" tty_mode="$3" target_cmd="$4"
	shift 4
	local -a ssh_opts=("$@")

	if [ "${local_exec}" -eq 1 ]; then
		bash -c "${target_cmd}"
	elif [ "${tty_mode}" -eq 1 ]; then
		run_tty_target_command "${ssh_target}" "${target_cmd}" "${ssh_opts[@]}"
	elif [ -n "${RUN_TARGET_COMMAND_TIMEOUT_SECS:-}" ]; then
		timeout --foreground "${RUN_TARGET_COMMAND_TIMEOUT_SECS}s" ssh "${ssh_opts[@]}" "${ssh_target}" "${target_cmd}"
	else
		# shellcheck disable=SC2029
		ssh "${ssh_opts[@]}" "${ssh_target}" "${target_cmd}"
	fi
}

acquire_tty_ssh_lock() {
	ensure_tmp_dir

	while ! mkdir "${NIXBOT_TTY_LOCK_DIR}" 2>/dev/null; do
		sleep 0.1
	done
}

release_tty_ssh_lock() {
	[ -n "${NIXBOT_TTY_LOCK_DIR}" ] || return 0
	rm -rf "${NIXBOT_TTY_LOCK_DIR}" || true
}

run_tty_target_command() {
	local ssh_target="$1" target_cmd="$2" tty_stdin_path="" rc=0
	shift 2
	local -a ssh_opts=("$@")

	tty_stdin_path="$(resolve_ssh_tty_stdin_path)"
	if [ "${tty_stdin_path}" = "/dev/tty" ]; then
		acquire_tty_ssh_lock
	fi

	if ssh -tt "${ssh_opts[@]}" "${ssh_target}" "${target_cmd}" <"${tty_stdin_path}"; then
		rc=0
	else
		rc="$?"
	fi

	if [ "${tty_stdin_path}" = "/dev/tty" ]; then
		release_tty_ssh_lock
		restore_initial_tty_state
	fi

	return "${rc}"
}

transport_retry_backoff_seconds() {
	local attempt="$1"

	printf '%s\n' "$((NIXBOT_TRANSPORT_RETRY_DELAY_SECS * (attempt - 1)))"
}

sleep_for_retry_or_signal() {
	local seconds="$1" rc=0

	sleep "${seconds}" || rc="$?"
	if is_signal_exit_status "${rc}"; then
		return "${rc}"
	fi
	if cancel_requested; then
		return "${NIXBOT_CANCEL_EXIT_STATUS}"
	fi
	return 0
}

transport_status_is_retryable() {
	case "${1:-}" in
	124 | 255)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

retry_transport_command() {
	local retry_label="$1" retry_hook="${2:-}"
	shift 2
	local attempt=1 rc=0 retry_sleep_secs=0

	while :; do
		if "$@"; then
			return 0
		else
			rc="$?"
		fi
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi

		if ! transport_status_is_retryable "${rc}" || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
			return "${rc}"
		fi

		attempt=$((attempt + 1))
		retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
		echo "${retry_label} transport unavailable; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
		sleep_for_retry_or_signal "${retry_sleep_secs}" || return "$?"
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
		if run_supervised_combined_capture captured "$@"; then
			# shellcheck disable=SC2034
			rtc_output_out_ref="${captured}"
			return 0
		else
			rc="$?"
		fi
		# shellcheck disable=SC2034
		rtc_output_out_ref="${captured}"
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi

		if ! transport_status_is_retryable "${rc}" || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
			return "${rc}"
		fi

		attempt=$((attempt + 1))
		retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
		echo "${retry_label} transport unavailable; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
		sleep_for_retry_or_signal "${retry_sleep_secs}" || return "$?"
		if [ -n "${retry_hook}" ]; then
			"${retry_hook}" || return "$?"
		fi
	done
}

retry_transport_stdout_capture() {
	# shellcheck disable=SC2034
	local -n rtsc_output_out_ref="$1"
	local retry_label="$2" retry_hook="${3:-}"
	shift 3
	local attempt=1 rc=0 retry_sleep_secs=0 captured=""

	while :; do
		if run_supervised_stdout_capture captured "" "$@"; then
			# shellcheck disable=SC2034
			rtsc_output_out_ref="${captured}"
			return 0
		else
			rc="$?"
		fi
		# shellcheck disable=SC2034
		rtsc_output_out_ref="${captured}"
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi

		if ! transport_status_is_retryable "${rc}" || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
			return "${rc}"
		fi

		attempt=$((attempt + 1))
		retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
		echo "${retry_label} transport unavailable; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
		sleep_for_retry_or_signal "${retry_sleep_secs}" || return "$?"
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

resolve_target_sudo_policy() {
	local local_exec="$1" ssh_target="$2"
	local deploy_user="" ask_sudo_password=0 sudo_tty_mode=0

	deploy_user="$(resolve_target_command_user "${local_exec}" "${ssh_target}")"
	# nixbot deploys are noninteractive automation. Non-root users must have
	# passwordless sudo or fail fast; otherwise bootstrap fallback users can hang
	# the run at a remote sudo password prompt.
	ask_sudo_password=0

	# The TTY path is intentionally unreachable unless a future explicit
	# interactive mode enables sudo password prompting.
	if [ "${local_exec}" -eq 0 ] && [ "${ask_sudo_password}" -eq 1 ]; then
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
	local resolved_tmp_prefix=""

	if [ "${local_exec}" -eq 1 ]; then
		if [[ "${tmp_prefix}" == /* ]]; then
			resolved_tmp_prefix="${tmp_prefix}"
		else
			resolved_tmp_prefix="$(tmp_runtime_dir_path target)/${tmp_prefix}"
		fi
		umask 077
		mktemp "${resolved_tmp_prefix}XXXXXX"
	else
		if [[ "${tmp_prefix}" == /* ]]; then
			resolved_tmp_prefix="${tmp_prefix}"
		else
			resolved_tmp_prefix="/tmp/nixbot-${tmp_prefix}"
		fi
		run_target_command \
			"${local_exec}" \
			"${ssh_target}" \
			0 \
			"umask 077; ${REMOTE_SYSTEM_BIN_DIR}/mktemp ${resolved_tmp_prefix}XXXXXX" \
			"${ssh_opts[@]}"
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
		run_target_command \
			"${local_exec}" \
			"${ssh_target}" \
			0 \
			"${REMOTE_SYSTEM_BIN_DIR}/rm -f '${target_tmp}'" \
			"${ssh_opts[@]}" >/dev/null 2>&1 || true
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
		"Remote file validation for ${remote_dest} on ${ssh_target}" \
		refresh_prepared_primary_target \
		run_target_command \
		"${local_exec}" \
		"${ssh_target}" \
		"${tty_mode}" \
		"${check_cmd}" \
		"${ssh_opts[@]}"; then
		return 0
	else
		rc="$?"
	fi
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

	if ! retry_transport_stdout_capture \
		target_tmp \
		"Remote temp allocation for ${install_label} on ${node} (${ssh_target})" \
		refresh_prepared_primary_target \
		create_target_tmp_file \
		"${local_exec}" \
		"${ssh_target}" \
		"${tmp_prefix}" \
		"${ssh_opts[@]}"; then
		target_tmp=""
	fi
	if [ -z "${target_tmp}" ]; then
		echo "Failed to allocate remote temporary file for ${install_label} on ${node} (${ssh_target})" >&2
		return 1
	fi

	if ! retry_transport_command \
		"Copying ${install_label} to ${node} (${ssh_target})" \
		refresh_prepared_primary_target \
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
		"Installing ${install_label} on ${node} (${ssh_target})" \
		refresh_prepared_primary_target \
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

	ikhsc_ssh_opts_out_ref=(
		-F "${SSH_NULL_CONFIG_FILE}"
		-o "ConnectTimeout=${NIXBOT_SSH_CONNECT_TIMEOUT_SECS}"
		-o ConnectionAttempts=1
		-o "ServerAliveInterval=${NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS}"
		-o "ServerAliveCountMax=${NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX}"
		-o LogLevel=ERROR
		-o "GlobalKnownHostsFile=${SSH_NULL_KNOWN_HOSTS_FILE}"
		-o "UserKnownHostsFile=${known_hosts_file}"
		-o "StrictHostKeyChecking=${host_key_check}"
	)
	ikhsc_nix_sshopts_out_ref="-F ${SSH_NULL_CONFIG_FILE} -o ConnectTimeout=${NIXBOT_SSH_CONNECT_TIMEOUT_SECS} -o ConnectionAttempts=1 -o ServerAliveInterval=${NIXBOT_SSH_SERVER_ALIVE_INTERVAL_SECS} -o ServerAliveCountMax=${NIXBOT_SSH_SERVER_ALIVE_COUNT_MAX} -o LogLevel=ERROR -o GlobalKnownHostsFile=${SSH_NULL_KNOWN_HOSTS_FILE} -o UserKnownHostsFile=${known_hosts_file} -o StrictHostKeyChecking=${host_key_check}"

	if [ "${batch_mode}" -eq 1 ]; then
		ikhsc_ssh_opts_out_ref=(-o BatchMode=yes "${ikhsc_ssh_opts_out_ref[@]}")
		ikhsc_nix_sshopts_out_ref="-o BatchMode=yes ${ikhsc_nix_sshopts_out_ref}"
	fi
}

control_master_socket_path() {
	local node="$1" role="$2" safe_node=""

	safe_node="$(printf '%s' "${node}-${role}" | tr -c 'a-zA-Z0-9._-' '_')"
	printf '%s/cm-%s\n' "${TMP_SSH_DIR}" "${safe_node}"
}

clear_control_master_socket() {
	local node="$1" role="$2" control_path=""

	[ -n "${node}" ] || return 0
	[ -n "${role}" ] || return 0
	[ -n "${TMP_SSH_DIR:-}" ] || return 0
	[ -d "${TMP_SSH_DIR}" ] || return 0

	control_path="$(control_master_socket_path "${node}" "${role}")"
	rm -f "${control_path}" || true
}

apply_control_master_to_ssh_context() {
	local node="$1" role="$2"
	# shellcheck disable=SC2178
	local -n acmtsc_ssh_opts_inout_ref="$3" acmtsc_nix_sshopts_inout_ref="$4"
	local control_path=""

	ensure_tmp_dir
	control_path="$(control_master_socket_path "${node}" "${role}")"

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
	local proxy_chain="${8:-}" proxy_command="${9:-}"
	local known_hosts_file=""

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
	if [ -z "${proxy_chain}" ] && [ -z "${proxy_command}" ]; then
		ensure_known_host "${host}" "${known_hosts}" "${known_hosts_file}"
	fi
	# Scan all directly-reachable intermediate hops.
	if [ -n "${proxy_chain}" ]; then
		local -a _chain_hops=()
		local hop_json="" hop_target="" hop_proxy_command=""
		while IFS= read -r hop_json; do
			[ -n "${hop_json}" ] || continue
			_chain_hops+=("${hop_json}")
		done <<<"${proxy_chain}"
		# The first hop is directly reachable; subsequent hops are behind proxies
		# and will be scanned through the proxy scripts built in prepare_deploy_context.
		if [ "${#_chain_hops[@]}" -gt 0 ]; then
			{
				read -r hop_target
				read -r hop_proxy_command
			} < <(jq -r '[.target, (.proxyCommand // "")] | .[]' <<<"${_chain_hops[0]}")
			if [ -z "${hop_proxy_command}" ]; then
				ensure_known_host "${hop_target}" "${known_hosts}" "${known_hosts_file}"
			fi
		fi
	fi
	# When the target is behind a proxy, ssh-keyscan cannot reach it
	# (it has no ProxyCommand support).  Use accept-new so the host key
	# is recorded on first contact — same trust model as the proxy scripts.
	# accept-new still rejects CHANGED keys (MITM protection).
	local host_key_check="yes"
	if [ -n "${proxy_chain}" ] || [ -n "${proxy_command}" ]; then
		host_key_check="accept-new"
	fi
	init_known_hosts_ssh_context 1 "${known_hosts_file}" phsc_host_ssh_opts_out_ref phsc_host_nix_sshopts_out_ref "${host_key_check}"
	init_known_hosts_ssh_context 0 "${known_hosts_file}" phsc_bootstrap_ssh_opts_out_ref phsc_bootstrap_nix_sshopts_out_ref "${host_key_check}"
	apply_control_master_to_ssh_context "${node}" primary phsc_host_ssh_opts_out_ref phsc_host_nix_sshopts_out_ref
	apply_control_master_to_ssh_context "${node}" bootstrap phsc_bootstrap_ssh_opts_out_ref phsc_bootstrap_nix_sshopts_out_ref
}

expand_proxy_command_template() {
	local template="$1" host="$2" port="$3"
	local expanded="${template}"
	expanded="${expanded//%h/${host}}"
	expanded="${expanded//%p/${port}}"
	printf '%s\n' "${expanded}"
}

write_static_proxy_command_script() {
	local script_path="$1" proxy_command="$2" host="$3" port="$4"
	local expanded_proxy_command=""

	expanded_proxy_command="$(expand_proxy_command_template "${proxy_command}" "${host}" "${port}")"
	{
		printf '%s\n' '#!/usr/bin/env bash'
		printf '%s\n' 'set -Eeuo pipefail'
		printf 'proxy_command=%q\n' "${expanded_proxy_command}"
		cat <<'EOF'
exec bash -c "${proxy_command}"
EOF
	} >"${script_path}"
	chmod +x "${script_path}"
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
cmd=(ssh -F /dev/null -o LogLevel=ERROR -o "GlobalKnownHostsFile=/dev/null" -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=${known_hosts_file}")
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
	} >"${script_path}"
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
	local hop_proxy_command="" hop_direct_proxy_script="" hop_previous_proxy_script=""

	[ -n "${proxy_chain}" ] || return 0

	ensure_tmp_dir

	# ProxyJump spawns a separate SSH process that does NOT inherit our custom
	# known-hosts isolation, so it can fall back to the ambient machine-level SSH
	# trust store and fail with "REMOTE HOST IDENTIFICATION HAS CHANGED" on
	# fresh/reinstalled hosts.
	# Use ProxyCommand instead so we can pass the known_hosts file through.
	# The proxy host key was already scanned into the node's known_hosts file
	# by prepare_host_ssh_contexts above.
	safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
	proxy_known_hosts_file="${TMP_SSH_DIR}/${NODE_KNOWN_HOSTS_PREFIX}.${safe_node}"

	while IFS= read -r hop_json; do
		[ -n "${hop_json}" ] || continue
		chain_hops+=("${hop_json}")
	done <<<"${proxy_chain}"

	for ((i = 0; i < ${#chain_hops[@]}; i++)); do
		hop_json="${chain_hops[i]}"
		proxy_script="${TMP_SSH_DIR}/proxy-${safe_node}-${i}.sh"
		{
			read -r hop_target
			read -r _hop_port
			read -r hop_connect_target
			read -r hop_connect_port
			read -r hop_key_path
			read -r hop_proxy_command
		} < <(jq -r '[.target, (.port // "22"), .connectTarget, (.connectPort // .port // "22"), (.keyPath // ""), (.proxyCommand // "")] | .[]' <<<"${hop_json}")
		if [ "${i}" -lt "$((${#chain_hops[@]} - 1))" ]; then
			fwd_host="$(jq -r '.target' <<<"${chain_hops[i + 1]}")"
			fwd_port="$(jq -r '(.port // "22")' <<<"${chain_hops[i + 1]}")"
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

		hop_previous_proxy_script="${prev_script}"
		if [ -z "${hop_previous_proxy_script}" ] && [ -n "${hop_proxy_command}" ]; then
			hop_direct_proxy_script="${TMP_SSH_DIR}/proxy-${safe_node}-${i}-direct.sh"
			write_static_proxy_command_script \
				"${hop_direct_proxy_script}" \
				"${hop_proxy_command}" \
				"$(ssh_host_from_target "${hop_connect_target}")" \
				"${hop_connect_port}"
			hop_previous_proxy_script="${hop_direct_proxy_script}"
		fi

		write_proxy_command_script \
			"${proxy_script}" \
			"${proxy_known_hosts_file}" \
			"$(format_ssh_forward_target "${fwd_host}" "${fwd_port}")" \
			"$(format_ssh_connect_target "${hop_connect_target}")" \
			"${hop_connect_port}" \
			"${hop_previous_proxy_script}" \
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
	local proxy_command="$7" key_path="$8" bootstrap_key_path="$9"
	# shellcheck disable=SC2178,SC2034
	local -n bdsc_host_ssh_opts_out_ref="${10}" bdsc_host_nix_sshopts_out_ref="${11}"
	# shellcheck disable=SC2178,SC2034
	local -n bdsc_bootstrap_ssh_opts_out_ref="${12}" bdsc_bootstrap_nix_sshopts_out_ref="${13}"
	local deploy_key_file="" bootstrap_key_file="" proxy_script=""

	prepare_host_ssh_contexts \
		"${node}" \
		"${host}" \
		"${known_hosts}" \
		bdsc_host_ssh_opts_out_ref \
		bdsc_host_nix_sshopts_out_ref \
		bdsc_bootstrap_ssh_opts_out_ref \
		bdsc_bootstrap_nix_sshopts_out_ref \
		"${proxy_chain}" \
		"${proxy_command}" || return 1

	apply_port_to_ssh_context "${port}" bdsc_host_ssh_opts_out_ref bdsc_host_nix_sshopts_out_ref
	apply_port_to_ssh_context "${bootstrap_port}" bdsc_bootstrap_ssh_opts_out_ref bdsc_bootstrap_nix_sshopts_out_ref

	if [ -n "${proxy_command}" ]; then
		proxy_script="${TMP_SSH_DIR}/proxy-$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")-direct.sh"
		write_static_proxy_command_script "${proxy_script}" "${proxy_command}" "${host}" "${port}"
		bdsc_host_ssh_opts_out_ref+=(-o "ProxyCommand=${proxy_script}")
		bdsc_host_nix_sshopts_out_ref="${bdsc_host_nix_sshopts_out_ref:+${bdsc_host_nix_sshopts_out_ref} }-o ProxyCommand=${proxy_script}"
		bdsc_bootstrap_ssh_opts_out_ref+=(-o "ProxyCommand=${proxy_script}")
		bdsc_bootstrap_nix_sshopts_out_ref="${bdsc_bootstrap_nix_sshopts_out_ref:+${bdsc_bootstrap_nix_sshopts_out_ref} }-o ProxyCommand=${proxy_script}"
	fi

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
		if ! deploy_key_file="$(resolve_ssh_identity_file "${key_path}" "Deploy SSH key" 0)"; then
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
	PREP_DEPLOY_AGE_IDENTITY_FILE=""
	PREP_DEPLOY_AGE_IDENTITY_SHA=""
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
	PREP_DEPLOY_AGE_IDENTITY_FILE=""
	PREP_DEPLOY_AGE_IDENTITY_SHA=""
	PREP_DEPLOY_LOCAL_EXEC=0
	PREP_DEPLOY_SSH_OPTS=()
}

probe_primary_deploy_target() {
	local node="$1" ssh_target="$2"
	shift 2
	local -a ssh_opts=("$@")
	local attempt=1 rc=0 retry_sleep_secs=0 captured=""

	while :; do
		if run_supervised_combined_capture captured ssh "${ssh_opts[@]}" "${ssh_target}" true; then
			PRIMARY_PROBE_LAST_OUTPUT=""
			return 0
		else
			rc="$?"
		fi
		PRIMARY_PROBE_LAST_OUTPUT="${captured}"

		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		if ! transport_status_is_retryable "${rc}" || [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
			return "${rc}"
		fi

		attempt=$((attempt + 1))
		retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
		echo "Primary connectivity probe for ${ssh_target} transport unavailable; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
		clear_control_master_socket "${node}" primary
		sleep_for_retry_or_signal "${retry_sleep_secs}" || return "$?"
	done
}

log_primary_probe_failure() {
	local label="$1" probe_output="$2"

	echo "==> ${label} failed" >&2
	[ -n "${probe_output}" ] || return 0

	while IFS= read -r line; do
		[ -n "${line}" ] || continue
		echo "    ${line}" >&2
	done <<<"${probe_output}"
}

primary_probe_failure_is_temporary_transport() {
	local probe_output="$1"

	[ -n "${probe_output}" ] || return 1

	grep -Eq \
		"Connection timed out|Connection timed out during banner exchange|No route to host|Connection reset by peer|Connection closed by remote host|kex_exchange_identification|ssh_exchange_identification|stdio forwarding failed|mux_client_request_session|Broken pipe" \
		<<<"${probe_output}"
}

ensure_primary_deploy_connectivity() {
	local node="$1" host="$2" port="$3" bootstrap_port="$4" known_hosts="$5" ssh_target="$6"
	local full_proxy_chain="$7" effective_proxy_chain="$8" proxy_command="$9"
	local key_path="${10}" bootstrap_key_path="${11}" age_identity_key="${12}"
	# shellcheck disable=SC2178,SC2034
	local -n epdc_ssh_opts_inout_ref="${13}" epdc_bootstrap_ssh_opts_inout_ref="${15}"
	# shellcheck disable=SC2178,SC2034
	local -n epdc_nix_sshopts_inout_ref="${14}" epdc_bootstrap_nix_sshopts_inout_ref="${16}"
	local direct_probe_output="" proxied_probe_output=""

	if probe_primary_deploy_target "${node}" "${ssh_target}" "${epdc_ssh_opts_inout_ref[@]}"; then
		mark_primary_ready "${node}"
		return 0
	fi
	direct_probe_output="${PRIMARY_PROBE_LAST_OUTPUT}"

	if [ -z "${full_proxy_chain}" ] || [ "${full_proxy_chain}" = "${effective_proxy_chain}" ]; then
		log_primary_probe_failure "Primary deploy target ${ssh_target}" "${direct_probe_output}"
		return 1
	fi

	log_primary_probe_failure "Direct path to ${ssh_target}" "${direct_probe_output}"
	echo "==> Direct path to ${ssh_target} is unavailable; retrying with configured proxy chain"
	build_deploy_ssh_contexts \
		"${node}" \
		"${host}" \
		"${port}" \
		"${bootstrap_port}" \
		"${known_hosts}" \
		"${full_proxy_chain}" \
		"${proxy_command}" \
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

	if probe_primary_deploy_target "${node}" "${ssh_target}" "${epdc_ssh_opts_inout_ref[@]}"; then
		mark_primary_ready "${node}"
		return 0
	fi
	proxied_probe_output="${PRIMARY_PROBE_LAST_OUTPUT}"
	log_primary_probe_failure \
		"Primary deploy target ${ssh_target} via configured proxy chain" \
		"${proxied_probe_output}"

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
	local node="$1" local_exec="$2" ssh_target="$3" age_identity_key_file="$4"
	local expected_sha="$5" using_bootstrap_fallback="${6:-0}"
	shift 6
	local -a ssh_opts=("$@")
	local remote_dest="${REMOTE_NIXBOT_AGE_IDENTITY}"

	if [ -z "${age_identity_key_file}" ] || [ -z "${expected_sha}" ]; then
		return
	fi

	if [ "${DRY_RUN}" -eq 1 ]; then
		if [ "${local_exec}" -eq 1 ]; then
			echo "DRY: would inject host age identity ${age_identity_key_file} -> ${remote_dest}"
		else
			echo "DRY: would inject host age identity ${age_identity_key_file} -> ${ssh_target}:${remote_dest}"
		fi
		return
	fi

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

ensure_prepared_host_age_identity_material() {
	local node="${1:-${PREP_DEPLOY_NODE}}"
	local age_identity_key_path="${2:-${PREP_DEPLOY_AGE_IDENTITY_KEY}}"

	if [ -z "${age_identity_key_path}" ]; then
		PREP_DEPLOY_AGE_IDENTITY_FILE=""
		PREP_DEPLOY_AGE_IDENTITY_SHA=""
		return 0
	fi

	if [ -n "${PREP_DEPLOY_AGE_IDENTITY_FILE}" ] && [ -n "${PREP_DEPLOY_AGE_IDENTITY_SHA}" ]; then
		return 0
	fi

	if [ -z "${node}" ]; then
		echo "Missing deploy node for prepared host age identity resolution" >&2
		return 1
	fi

	{
		read -r PREP_DEPLOY_AGE_IDENTITY_FILE
		read -r PREP_DEPLOY_AGE_IDENTITY_SHA
	} < <(resolve_host_age_identity_key_file_and_sha "${node}" "${age_identity_key_path}") || return 1
}

prepare_deploy_context() {
	local node="$1" mode="${2:-normal}"
	local target_info="" user="" host="" port="" key_path="" known_hosts=""
	local bootstrap_key="" bootstrap_user="" bootstrap_port="" bootstrap_key_path=""
	local age_identity_key="" proxy_jump="" proxy_command="" full_proxy_chain="" effective_proxy_chain=""
	local ssh_target="" bootstrap_ssh_target=""
	local local_exec=0 primary_target_ready=1 self_target_match=0
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
		read -r proxy_command
	} < <(jq -r '[.user, .target, (.port // "22"), (.keyPath // ""), (.knownHosts // ""), (.bootstrapKey // ""), (.bootstrapUser // ""), (.bootstrapPort // .port // "22"), (.bootstrapKeyPath // ""), (.ageIdentityKey // ""), (.proxyJump // ""), (.proxyCommand // "")] | .[]' <<<"${target_info}")

	ssh_target="${user}@${host}"
	bootstrap_ssh_target="${bootstrap_user}@${host}"

	if should_use_local_self_target &&
		{ local_host_matches_identifier "${node}" || local_host_matches_identifier "${host}"; }; then
		self_target_match=1
	fi
	if [ "${self_target_match}" -eq 1 ] &&
		can_execute_self_target_locally_as_deploy_user "${user}"; then
		emit_self_target_notice_once \
			"${node}:local-exec" \
			"==> Deploy target ${ssh_target} matches current host; using local execution as $(id -un)"
		set_prepared_deploy_context \
			"${node}" \
			"" \
			"" \
			0 \
			"${age_identity_key}" \
			1
		return 0
	elif [ "${self_target_match}" -eq 1 ] && [ "${mode}" != "primary-only" ]; then
		emit_self_target_notice_once \
			"${node}:preserve-ssh" \
			"==> Self-target ${ssh_target}; current user $(id -un) != ${user}, keeping SSH route"
	fi
	if [ -n "${proxy_jump}" ]; then
		full_proxy_chain="$(resolve_proxy_chain "${proxy_jump}")"
		effective_proxy_chain="$(resolve_effective_proxy_chain "${proxy_jump}")"
	fi

	build_deploy_ssh_contexts \
		"${node}" \
		"${host}" \
		"${port}" \
		"${bootstrap_port}" \
		"${known_hosts}" \
		"${effective_proxy_chain}" \
		"${proxy_command}" \
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
			"${proxy_command}" \
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
		elif [ "${self_target_match}" -eq 1 ] &&
			can_execute_self_target_locally_as_deploy_user "${user}" &&
			[ "${primary_target_ready}" -eq 0 ]; then
			echo "==> Primary deploy target ${ssh_target} is unavailable on self-target run; falling back to local execution as $(id -un)" >&2
			local_exec=1
			set_prepared_deploy_context \
				"${node}" \
				"" \
				"" \
				0 \
				"${age_identity_key}" \
				1
			return 0
		elif [ -n "${bootstrap_user}" ] && [ "${bootstrap_user}" != "${user}" ]; then
			if [ "${primary_target_ready}" -eq 0 ]; then
				local bootstrap_readiness_source=""

				if primary_probe_failure_is_temporary_transport "${PRIMARY_PROBE_LAST_OUTPUT}"; then
					echo "==> Primary deploy target ${ssh_target} has a temporary transport failure; delaying bootstrap fallback" >&2
					return 255
				fi

				if is_bootstrap_ready "${node}"; then
					echo "==> Reusing bootstrap readiness for ${node} from earlier step"
					bootstrap_readiness_source="cached"
				elif [ -n "${bootstrap_key}" ]; then
					clear_control_master_socket "${node}" primary
					if check_bootstrap_via_forced_command "${node}" "${ssh_target}" "${ssh_opts[@]}"; then
						bootstrap_readiness_source="forced-command"
						mark_bootstrap_ready "${node}"
					else
						ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
						bootstrap_readiness_source="injected"
					fi
				else
					ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
					bootstrap_readiness_source="injected"
				fi

				if [ "${bootstrap_readiness_source}" != "forced-command" ]; then
					clear_control_master_socket "${node}" primary
					if ensure_primary_deploy_connectivity \
						"${node}" \
						"${host}" \
						"${port}" \
						"${bootstrap_port}" \
						"${known_hosts}" \
						"${ssh_target}" \
						"${full_proxy_chain}" \
						"${effective_proxy_chain}" \
						"${proxy_command}" \
						"${key_path}" \
						"${bootstrap_key_path}" \
						"${age_identity_key}" \
						ssh_opts \
						nix_sshopts \
						bootstrap_ssh_opts \
						bootstrap_nix_sshopts; then
						echo "==> Bootstrap preparation restored primary deploy target ${ssh_target}"
						return 0
					fi
				fi

				case "${bootstrap_readiness_source}" in
				forced-command)
					echo "==> Bootstrap check passed for ${ssh_target}, but primary shell access is still unavailable; using bootstrap target ${bootstrap_ssh_target} for deploy"
					;;
				cached)
					echo "==> Primary deploy target ${ssh_target} is still unavailable; reusing cached bootstrap path ${bootstrap_ssh_target}"
					;;
				*)
					echo "==> Primary deploy target ${ssh_target} is unavailable; falling back to bootstrap target ${bootstrap_ssh_target} for this run"
					;;
				esac

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
	elif [ -n "${bootstrap_key}" ] && [ "${mode}" != "primary-only" ]; then
		ensure_bootstrap_key_ready "${node}" "${bootstrap_ssh_target}" "${bootstrap_key}" "${bootstrap_ssh_opts[@]}" || return 1
	fi
}

run_prepared_deploy_command() {
	local tty_mode="$1" target_cmd="$2"
	local rc=0

	if ! require_prepared_deploy_context "run_prepared_deploy_command"; then
		return 1
	fi

	if [ "${DRY_RUN}" -eq 1 ]; then
		if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 1 ]; then
			printf 'bash -c %q\n' "${target_cmd}"
		else
			if [ "${tty_mode}" -eq 1 ]; then
				printf 'ssh -tt '
			elif [ -n "${RUN_TARGET_COMMAND_TIMEOUT_SECS:-}" ]; then
				printf 'timeout --foreground %q ssh ' "${RUN_TARGET_COMMAND_TIMEOUT_SECS}s"
			else
				printf 'ssh '
			fi
			printf '%q ' "${PREP_DEPLOY_SSH_OPTS[@]}" "${PREP_DEPLOY_SSH_TARGET}" "${target_cmd}"
			echo
		fi
		return 0
	fi

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
	else
		rc="$?"
	fi

	return "${rc}"
}

ssh_opts_without_control_master() {
	local out_name="$1"
	shift
	# shellcheck disable=SC2178
	local -n sowcm_out_ref="${out_name}"
	local opt="" value="" i=0
	local -a opts=("$@")

	sowcm_out_ref=()
	for ((i = 0; i < ${#opts[@]}; i++)); do
		opt="${opts[${i}]}"
		if [ "${opt}" = "-o" ] && [ $((i + 1)) -lt "${#opts[@]}" ]; then
			value="${opts[$((i + 1))]}"
			case "${value}" in
			ControlMaster=* | ControlPath=* | ControlPersist=*)
				i=$((i + 1))
				continue
				;;
			esac
			sowcm_out_ref+=("${opt}" "${value}")
			i=$((i + 1))
			continue
		fi

		case "${opt}" in
		-oControlMaster=* | -oControlPath=* | -oControlPersist=*)
			continue
			;;
		esac
		sowcm_out_ref+=("${opt}")
	done

	sowcm_out_ref+=(-o ControlMaster=no -o ControlPath=none)
}

run_prepared_deploy_command_without_control_master() {
	local tty_mode="$1" target_cmd="$2" rc=0
	local -a saved_ssh_opts=("${PREP_DEPLOY_SSH_OPTS[@]}") isolated_ssh_opts=()

	ssh_opts_without_control_master isolated_ssh_opts "${saved_ssh_opts[@]}"
	PREP_DEPLOY_SSH_OPTS=("${isolated_ssh_opts[@]}")
	run_prepared_deploy_command "${tty_mode}" "${target_cmd}" || rc="$?"
	PREP_DEPLOY_SSH_OPTS=("${saved_ssh_opts[@]}")
	return "${rc}"
}

require_prepared_deploy_context() {
	local caller="${1:-prepared deploy command}"

	if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 1 ]; then
		return 0
	fi
	if [ -n "${PREP_DEPLOY_SSH_TARGET}" ]; then
		return 0
	fi

	echo "${caller}: missing prepared SSH target; call prepare_deploy_context in the same shell before running prepared commands" >&2
	return 1
}

refresh_prepared_primary_target() {
	local node="${PREP_DEPLOY_NODE}"

	[ -n "${PREP_DEPLOY_NODE}" ] || return 0
	[ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 0 ] || return 0
	# Bootstrap-fallback retries are already operating on the prepared bootstrap
	# transport. Re-probing the primary path here only adds misleading fallback
	# noise and does not affect the in-flight retry arguments.
	[ "${PREP_USING_BOOTSTRAP_FALLBACK}" -eq 0 ] || return 0

	clear_primary_ready "${node}"
	clear_control_master_socket "${node}" primary
	prepare_deploy_context "${node}" primary-only
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

run_prepared_deploy_command_with_bounded_retry() {
	local tty_mode="$1" retry_label="$2" timeout_secs="$3" target_cmd="$4"

	retry_transport_command \
		"${retry_label}" \
		refresh_prepared_primary_target \
		run_prepared_deploy_command_with_timeout \
		"${tty_mode}" \
		"${timeout_secs}" \
		"${target_cmd}"
}

run_prepared_deploy_command_with_timeout() {
	local tty_mode="$1" timeout_secs="$2" target_cmd="$3"

	RUN_TARGET_COMMAND_TIMEOUT_SECS="${timeout_secs}" \
		run_prepared_deploy_command "${tty_mode}" "${target_cmd}"
}

run_prepared_deploy_command_without_control_master_with_timeout() {
	local tty_mode="$1" timeout_secs="$2" target_cmd="$3"

	RUN_TARGET_COMMAND_TIMEOUT_SECS="${timeout_secs}" \
		run_prepared_deploy_command_without_control_master "${tty_mode}" "${target_cmd}"
}

prepared_target_has_passwordless_sudo() {
	local deploy_user=""

	[ -n "${PREP_DEPLOY_SSH_TARGET}" ] || return 1

	deploy_user="$(resolve_target_command_user "${PREP_DEPLOY_LOCAL_EXEC}" "${PREP_DEPLOY_SSH_TARGET}")"
	if [ "${deploy_user}" = "root" ]; then
		return 0
	fi

	if run_prepared_deploy_command 0 "sudo -n true" >/dev/null 2>&1; then
		return 0
	fi

	return 1
}

_remote_check_activation_context_file_value() {
	local remote_dest="$1" expected_value="$2" read_cmd="$3" sudo_cmd="$4"
	local current=""
	local activation_runtime_path="/run/wrappers/bin:/run/current-system/sw/bin"
	local activation_shell="/run/current-system/sw/bin/sh"
	export PATH="${activation_runtime_path}${PATH:+:${PATH}}"
	if ! command -v sudo >/dev/null 2>&1; then
		echo "sudo is required to validate ${remote_dest}" >&2
		return 1
	fi

	current="$(
		DEST="${remote_dest}" \
			${sudo_cmd} env DEST="${remote_dest}" sh -c \
			"systemd-run --wait --pipe --quiet --service-type=exec env PATH=\"${activation_runtime_path}\" DEST=\"\$DEST\" \"${activation_shell}\" -c $(printf '%q' "${read_cmd}") 2>/dev/null" \
			2>/dev/null || true
	)"
	[ "${current}" = "${expected_value}" ]
}

build_remote_activation_context_file_value_check_cmd() {
	local remote_dest="$1" expected_value="$2" read_cmd="$3" ask_sudo_password="${4:-0}"
	local sudo_cmd="sudo -n" invoke_cmd=""

	if [ "${ask_sudo_password}" -eq 1 ]; then
		sudo_cmd="sudo"
	fi

	printf -v invoke_cmd '_remote_check_activation_context_file_value %q %q %q %q' \
		"${remote_dest}" \
		"${expected_value}" \
		"${read_cmd}" \
		"${sudo_cmd}"

	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_check_activation_context_file_value
}

wait_for_prepared_host_age_identity_activation_visibility() {
	local node="$1" expected_sha="$2"
	local check_cmd="" ask_sudo_password=0 tty_mode=0
	local -a sudo_policy=()
	local attempt=1 max_attempts=10

	[ "${DRY_RUN}" -eq 0 ] || return 0

	[ -n "${expected_sha}" ] || return 0

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
		sleep_for_retry_or_signal 1 || return "$?"
		attempt=$((attempt + 1))
	done
}

build_wrapped_root_command() {
	local target_cmd="$1" deploy_user="$2" ask_sudo_password="$3"
	local shell_cmd="" sudo_prefix=""

	printf -v shell_cmd 'env PATH=%q %q -lc %q' \
		"${REMOTE_RUNTIME_PATH}" \
		"${REMOTE_SYSTEM_BASH}" \
		"${target_cmd}"
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

run_prepared_root_command_without_control_master() {
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
	run_prepared_deploy_command_without_control_master "${tty_mode}" "${wrapped_cmd}"
}

run_prepared_root_command_with_retry() {
	local retry_label="$1" target_cmd="$2"

	retry_transport_command \
		"${retry_label}" \
		refresh_prepared_primary_target \
		run_prepared_root_command \
		"${target_cmd}"
}

run_named_prepared_root_command() {
	local phase_name="$1" parent="$2" resources="$3" target_cmd="$4"
	local rc=0 start_epoch="" elapsed_secs=0

	start_epoch="$(date +%s)"

	if retry_transport_command \
		"Parent readiness ${phase_name} on ${parent}" \
		refresh_prepared_primary_target \
		run_prepared_root_command \
		"${target_cmd}"; then
		elapsed_secs="$(($(date +%s) - start_epoch))"
		NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS="${elapsed_secs}"
		if [ "${elapsed_secs}" -ge "${NIXBOT_PARENT_READINESS_SLOW_SECS}" ]; then
			echo "[parent-readiness] ${parent}: ${phase_name} ok for ${resources} after ${elapsed_secs}s" >&2
		fi
		return 0
	else
		rc="$?"
	fi

	elapsed_secs="$(($(date +%s) - start_epoch))"
	echo "[parent-readiness] ${parent}: ${phase_name} failed for ${resources} after ${elapsed_secs}s" >&2
	return "${rc}"
}

log_parent_readiness_ok() {
	local parent="$1" elapsed_secs="$2"

	echo "[parent-readiness] ${parent}: ok (${elapsed_secs}s)" >&2
}

run_host_operation_with_retry_budget() {
	local node="$1" operation_label="$2" ready_timeout="$3" ready_interval_secs="$4"
	shift 4

	local parent_host="" max_attempts=0 attempt=1 rc=0

	[ "${DRY_RUN}" -eq 0 ] || {
		"$@"
		return "$?"
	}

	parent_host="$(host_parent_for "${node}")"
	if [ "${ready_interval_secs}" -lt 1 ]; then
		ready_interval_secs=1
	fi
	max_attempts=$((((ready_timeout - 1) / ready_interval_secs) + 1))

	while :; do
		clear_primary_ready "${node}"
		if "$@"; then
			return 0
		else
			rc="$?"
		fi
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		if [ "${attempt}" -ge "${max_attempts}" ]; then
			return "${rc}"
		fi

		if [ -n "${parent_host}" ]; then
			echo "[${node}] deploy | ${operation_label} attempt ${attempt}/${max_attempts} failed after parent barrier (${parent_host}); retrying in ${ready_interval_secs}s" >&2
		else
			echo "[${node}] deploy | ${operation_label} attempt ${attempt}/${max_attempts} failed; retrying in ${ready_interval_secs}s" >&2
		fi
		sleep_for_retry_or_signal "${ready_interval_secs}" || return "$?"
		attempt=$((attempt + 1))
	done
}

run_parented_host_operation_with_retry() {
	local node="$1" operation_label="$2"
	shift 2

	local parent_host="" ready_timeout=0 ready_interval_secs=0

	parent_host="$(host_parent_for "${node}")"
	if [ -n "${parent_host}" ]; then
		ready_timeout="${NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT}"
		ready_interval_secs="${NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS}"
	else
		ready_interval_secs="${NIXBOT_TRANSPORT_RETRY_DELAY_SECS}"
		ready_timeout="$((NIXBOT_TRANSPORT_RETRY_ATTEMPTS * ready_interval_secs))"
	fi

	run_host_operation_with_retry_budget \
		"${node}" \
		"${operation_label}" \
		"${ready_timeout}" \
		"${ready_interval_secs}" \
		"$@"
}

run_post_switch_health_transport_preparation_with_retry() {
	local node="$1"

	run_host_operation_with_retry_budget \
		"${node}" \
		"health-check transport preparation" \
		"${NIXBOT_PARENT_SNAPSHOT_READY_TIMEOUT}" \
		"${NIXBOT_PARENT_SNAPSHOT_READY_INTERVAL_SECS}" \
		prepare_deploy_context \
		"${node}" \
		primary-only
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
	*"{resource}"* | *"{resourceArgs}"* | *"{timeout}"*)
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
	local group_elapsed_secs=0
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

		group_elapsed_secs=0
		log_subsection "Parent Readiness: ${grouped_parents["${group_key}"]}"
		prepare_deploy_context "${grouped_parents["${group_key}"]}" || return 1
		if parent_template_supports_batching "${grouped_reconcile_templates["${group_key}"]}" &&
			parent_template_supports_batching "${grouped_settle_templates["${group_key}"]}"; then
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
			group_elapsed_secs=$((group_elapsed_secs + NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS))
			run_named_prepared_root_command \
				"settle" \
				"${grouped_parents["${group_key}"]}" \
				"${rendered_resource_args}" \
				"${settle_cmd}" || return 1
			group_elapsed_secs=$((group_elapsed_secs + NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS))
			log_parent_readiness_ok "${grouped_parents["${group_key}"]}" "${group_elapsed_secs}"
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
			group_elapsed_secs=$((group_elapsed_secs + NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS))
			run_named_prepared_root_command \
				"settle" \
				"${grouped_parents["${group_key}"]}" \
				"${resource}" \
				"${settle_cmd}" || return 1
			group_elapsed_secs=$((group_elapsed_secs + NIXBOT_PARENT_READINESS_LAST_ELAPSED_SECS))
		done
		log_parent_readiness_ok "${grouped_parents["${group_key}"]}" "${group_elapsed_secs}"
	done
}

read_prepared_current_system_path() {
	run_prepared_deploy_command_with_bounded_retry \
		0 \
		"Current system read for ${PREP_DEPLOY_NODE:-target}" \
		"${NIXBOT_REMOTE_READ_TIMEOUT_SECS}" \
		"${REMOTE_SYSTEM_BIN_DIR}/readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true"
}

read_prepared_current_system_path_without_control_master() {
	run_prepared_deploy_command_without_control_master_with_timeout \
		0 \
		"${NIXBOT_REMOTE_READ_TIMEOUT_SECS}" \
		"${REMOTE_SYSTEM_BIN_DIR}/readlink -f ${REMOTE_CURRENT_SYSTEM_PATH} 2>/dev/null || true"
}

read_prepared_system_profile_path() {
	run_prepared_deploy_command_with_bounded_retry \
		0 \
		"System profile read for ${PREP_DEPLOY_NODE:-target}" \
		"${NIXBOT_REMOTE_READ_TIMEOUT_SECS}" \
		"${REMOTE_SYSTEM_BIN_DIR}/readlink -f ${REMOTE_SYSTEM_PROFILE_PATH} 2>/dev/null || true"
}

prepare_host_age_identity_for_deploy() {
	local node="$1" require_age_identity_activation_visibility="${2:-0}"
	local age_identity_key=""

	prepare_deploy_context "${node}" || return 1
	age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"
	ensure_prepared_host_age_identity_material "${node}" "${age_identity_key}" || return 1

	inject_host_age_identity_key \
		"${node}" \
		"${PREP_DEPLOY_LOCAL_EXEC}" \
		"${PREP_DEPLOY_SSH_TARGET}" \
		"${PREP_DEPLOY_AGE_IDENTITY_FILE}" \
		"${PREP_DEPLOY_AGE_IDENTITY_SHA}" \
		"${PREP_USING_BOOTSTRAP_FALLBACK}" \
		"${PREP_DEPLOY_SSH_OPTS[@]}" || return 1

	if [ "${require_age_identity_activation_visibility}" -eq 1 ]; then
		wait_for_prepared_host_age_identity_activation_visibility \
			"${node}" \
			"${PREP_DEPLOY_AGE_IDENTITY_SHA}" || return 1
	fi
}

require_local_build_primary_deploy_context() {
	local node="$1" prepared_user=""

	if [ "${PREP_DEPLOY_LOCAL_EXEC}" -ne 0 ] ||
		[ "${PREP_USING_BOOTSTRAP_FALLBACK}" -ne 1 ] ||
		{ [ "${BUILD_HOST}" != "local" ] && ! remote_build_deploy_uses_local_relay; }; then
		return 0
	fi

	prepared_user="${PREP_DEPLOY_SSH_TARGET%%@*}"
	if [ "${prepared_user}" = "root" ] || [ "${prepared_user}" = "nixbot" ]; then
		return 0
	fi

	echo "==> Local relay deploy for ${node} needs primary deploy user; rechecking primary target"
	prepare_deploy_context "${node}" primary-only
}

prepare_host_transport_for_deploy() {
	local node="$1" require_age_identity_activation_visibility="${2:-0}"

	prepare_host_age_identity_for_deploy "${node}" "${require_age_identity_activation_visibility}" || return 1
	require_local_build_primary_deploy_context "${node}"
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

	printf '%s\n' "${remote_current_path}" >"${snapshot_file}"
	echo "${remote_current_path}"
}

extract_nixos_system_path() {
	local input="$1" line="" system_path="" count=0

	while IFS= read -r line; do
		if [[ "${line}" =~ ^/nix/store/[^[:space:]]+-nixos-system-[^[:space:]]+$ ]]; then
			system_path="${line}"
			count=$((count + 1))
		fi
	done <<<"${input}"

	[ "${count}" -eq 1 ] || return 1
	printf '%s\n' "${system_path}"
}

read_snapshot_system_path_file() {
	local snapshot_file="$1" snapshot_content="" system_path=""

	[ -s "${snapshot_file}" ] || return 1
	snapshot_content="$(<"${snapshot_file}")"
	if ! system_path="$(extract_nixos_system_path "${snapshot_content}")"; then
		return 1
	fi

	printf '%s\n' "${system_path}"
}

snapshot_exists() {
	local snapshot_file="$1"

	read_snapshot_system_path_file "${snapshot_file}" >/dev/null
}

snapshot_deploy_skip_marker_file() {
	local snapshot_dir="$1" node="$2"

	printf '%s/%s.deploy-skip\n' "${snapshot_dir}" "${node}"
}

snapshot_deploy_skip_marked() {
	local snapshot_dir="$1" node="$2"

	[ -e "$(snapshot_deploy_skip_marker_file "${snapshot_dir}" "${node}")" ]
}

log_snapshot_deploy_skip() {
	local node="$1" message="skip deploy: gen up-to-date"

	if [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
		printf '%s\n' "${message}" | host_log_filter "${node}" snapshot >&2
	else
		printf '[%s] snapshot | %s\n' "${node}" "${message}" >&2
	fi
}

wave_needs_snapshot_retry() {
	local snapshot_dir="$1"
	shift

	local node=""

	[ "${DRY_RUN}" -eq 0 ] || return 1
	[ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 1

	for node in "$@"; do
		[ -n "${node}" ] || continue
		if host_deploy_stage_skipped "${node}"; then
			continue
		fi
		if ! snapshot_exists "${snapshot_dir}/${node}.path"; then
			return 0
		fi
	done

	return 1
}

wait_for_job_slot() {
	local -n wfjs_active_jobs_inout_ref="$1"
	local max_jobs="$2" wait_rc=0

	if cancel_requested; then
		wait_active_deploy_jobs_to_finish || true
		return "${NIXBOT_CANCEL_EXIT_STATUS}"
	fi

	if [ "${wfjs_active_jobs_inout_ref}" -ge "${max_jobs}" ]; then
		if wait -n; then
			:
		else
			wait_rc="$?"
			if cancel_requested; then
				wait_active_deploy_jobs_to_finish || true
				return "${NIXBOT_CANCEL_EXIT_STATUS}"
			fi
			if is_signal_exit_status "${wait_rc}"; then
				if [ "${NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS:-0}" -gt 0 ]; then
					NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS=$((NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS - 1))
					wfjs_active_jobs_inout_ref=$((wfjs_active_jobs_inout_ref - 1))
					return 0
				fi
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
		if cancel_requested; then
			wait_active_deploy_jobs_to_finish || true
			return "${NIXBOT_CANCEL_EXIT_STATUS}"
		fi
		if wait -n; then
			:
		else
			wait_rc="$?"
			if cancel_requested; then
				wait_active_deploy_jobs_to_finish || true
				return "${NIXBOT_CANCEL_EXIT_STATUS}"
			fi
			if is_signal_exit_status "${wait_rc}"; then
				if [ "${NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS:-0}" -gt 0 ]; then
					NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS=$((NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS - 1))
					djs_active_jobs_inout_ref=$((djs_active_jobs_inout_ref - 1))
					continue
				fi
				return "${wait_rc}"
			fi
		fi
		djs_active_jobs_inout_ref=$((djs_active_jobs_inout_ref - 1))
	done
}

run_streamed_host_command() {
	local phase="$1" node="$2" log_file="${3:-}"
	shift 3

	if [ -n "${log_file}" ] && [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
		run_with_host_log_prefix_context "${phase}" \
			run_with_combined_output "$@" > >(tee_prefixed_host_logs "${node}" "${log_file}" "${phase}")
	elif [ -n "${log_file}" ]; then
		run_with_combined_output "$@" > >(tee_plain_host_logs "${log_file}")
	elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
		run_with_host_log_prefix_context "${phase}" \
			run_with_combined_output "$@" > >(prefix_host_logs "${node}" "${phase}")
	else
		"$@"
	fi
}

run_build_job() {
	local node="$1" out_file="$2" status_file="$3" log_file="${4:-}"
	local build_start_epoch="" built_out_path="" duration_file="" duration_secs=""
	local result_link="" rc="" safe_node=""

	safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
	result_link="$(tmp_runtime_dir_path build-results)/${safe_node}.result"
	duration_file="$(phase_dir_item_duration_file "$(dirname "${status_file}")" "${node}")"

	(
		set +e
		build_start_epoch="$(date +%s)"
		if [ -n "${log_file}" ]; then
			built_out_path="$(resolve_build_out_path "${node}" "${result_link}" \
				2> >(tee_host_log_filter "${node}" "${log_file}" build >&2))"
			rc="$?"
			if [ "${rc}" = "0" ] && [ -n "${built_out_path}" ]; then
				printf '%s\n' "${built_out_path}" | append_host_log_filter "${node}" "${log_file}" build
			fi
		elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
			built_out_path="$(resolve_build_out_path "${node}" "${result_link}" 2> >(host_log_filter "${node}" build >&2))"
			rc="$?"
		else
			built_out_path="$(resolve_build_out_path "${node}" "${result_link}")"
			rc="$?"
		fi
		if [ "${rc}" = "0" ]; then
			printf '%s\n' "${built_out_path}" >"${out_file}"
		fi
		duration_secs="$(elapsed_seconds "${build_start_epoch}")"
		write_duration_file "${duration_file}" "${duration_secs}"
		log_host_phase_duration "${node}" build "${duration_secs}" "${log_file}"
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

deploy_status_is_required_failure() {
	local node="$1" status="$2"

	case "${status}" in
	0 | skip)
		return 1
		;;
	esac
	if is_signal_exit_status "${status}"; then
		return 1
	fi
	if host_optional_deploy_enabled "${node}"; then
		return 1
	fi

	return 0
}

find_completed_required_deploy_failure() {
	local deploy_status_dir="$1" node="" status_file="" status=""
	shift

	for node in "$@"; do
		[ -n "${node}" ] || continue
		if [ -e "$(deploy_pre_activation_cancel_marker_file "${node}")" ]; then
			continue
		fi
		status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
		if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
			continue
		fi
		if deploy_status_is_required_failure "${node}" "${status}"; then
			printf '%s\n' "${node}"
			return 0
		fi
	done

	return 1
}

drain_deploy_wave_job_slots() {
	local -n ddwjs_active_jobs_inout_ref="$1"
	local deploy_status_dir="$2" started_hosts_name="$3" failed_node_out_name="$4"
	local -n ddwjs_started_hosts_in_ref="${started_hosts_name}"
	local -n ddwjs_failed_node_out_ref="${failed_node_out_name}"
	local wait_rc=0

	while [ "${ddwjs_active_jobs_inout_ref}" -gt 0 ]; do
		if cancel_requested; then
			wait_active_deploy_jobs_to_finish || true
			return "${NIXBOT_CANCEL_EXIT_STATUS}"
		fi
		if wait -n; then
			:
		else
			wait_rc="$?"
			if cancel_requested; then
				wait_active_deploy_jobs_to_finish || true
				return "${NIXBOT_CANCEL_EXIT_STATUS}"
			fi
			if is_signal_exit_status "${wait_rc}"; then
				if [ "${NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS:-0}" -gt 0 ]; then
					NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS=$((NIXBOT_DEPLOY_FAIL_FAST_PENDING_SIGNAL_JOBS - 1))
				else
					return "${wait_rc}"
				fi
			fi
		fi
		ddwjs_active_jobs_inout_ref=$((ddwjs_active_jobs_inout_ref - 1))
		if [ -z "${ddwjs_failed_node_out_ref}" ] &&
			ddwjs_failed_node_out_ref="$(
				find_completed_required_deploy_failure \
					"${deploy_status_dir}" \
					"${ddwjs_started_hosts_in_ref[@]}"
			)"; then
			terminate_pre_activation_deploy_jobs "${ddwjs_failed_node_out_ref}"
		fi
	done
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

	return 0
}

classify_completed_deploy_jobs() {
	local deploy_status_dir="$1"
	local success_hosts_out_name="$2" skipped_hosts_out_name="$3"
	local optional_failed_hosts_out_name="$4" required_failed_hosts_out_name="$5"
	# shellcheck disable=SC2178,SC2034
	local -n ccdj_success_hosts_out_ref="${success_hosts_out_name}"
	# shellcheck disable=SC2178,SC2034
	local -n ccdj_skipped_hosts_out_ref="${skipped_hosts_out_name}"
	# shellcheck disable=SC2178,SC2034
	local -n ccdj_optional_failed_hosts_out_ref="${optional_failed_hosts_out_name}"
	# shellcheck disable=SC2178,SC2034
	local -n ccdj_required_failed_hosts_out_ref="${required_failed_hosts_out_name}"
	shift 5

	local node="" status_file="" result_kind="" status=""

	for node in "$@"; do
		[ -n "${node}" ] || continue
		status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
		[ -s "${status_file}" ] || continue
		{
			read -r result_kind
			read -r status
		} < <(resolve_deploy_phase_result "${node}" "${status_file}")

		case "${result_kind}" in
		success)
			ccdj_success_hosts_out_ref+=("${node}")
			;;
		skip)
			ccdj_skipped_hosts_out_ref+=("${node}")
			;;
		optional-fail)
			ccdj_optional_failed_hosts_out_ref+=("${node}")
			;;
		signal)
			return "${status}"
			;;
		fail)
			ccdj_required_failed_hosts_out_ref+=("${node}")
			;;
		*)
			die "Unsupported deploy phase result for ${node}: ${result_kind}"
			;;
		esac
	done

	return 0
}

process_completed_deploy_wave_jobs() {
	local deploy_status_dir="$1" snapshot_dir="$2" rollback_log_dir="$3" rollback_status_dir="$4"
	local success_hosts_out_name="$5" skipped_hosts_out_name="$6" failed_hosts_out_name="$7"
	# shellcheck disable=SC2178
	local -n pcdwj_failed_hosts_out_ref="${failed_hosts_out_name}"
	shift 7

	local rc=0
	local -a optional_failed_hosts=() required_failed_hosts=()

	classify_completed_deploy_jobs \
		"${deploy_status_dir}" \
		"${success_hosts_out_name}" \
		"${skipped_hosts_out_name}" \
		optional_failed_hosts \
		required_failed_hosts \
		"$@" || return "$?"

	if [ "${#required_failed_hosts[@]}" -gt 0 ]; then
		pcdwj_failed_hosts_out_ref+=("${required_failed_hosts[@]}")
		rc=1
	fi

	if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ]; then
		rollback_optional_deploy_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${optional_failed_hosts[@]}"
		rollback_failed_deploy_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${required_failed_hosts[@]}"
	fi

	return "${rc}"
}

handle_deploy_interrupt() {
	local interrupt_rc="$1" snapshot_dir="$2" deploy_status_dir="$3"
	local rollback_log_dir="$4" rollback_status_dir="$5"
	local success_hosts_out_name="$6" skipped_hosts_out_name="$7" failed_hosts_out_name="$8"
	# shellcheck disable=SC2178
	local -n hdi_success_hosts_out_ref="${success_hosts_out_name}"
	shift 8

	if active_deploys_registered && ! force_cancel_requested; then
		wait_active_deploy_jobs_to_finish || true
		if ! force_cancel_requested; then
			process_completed_deploy_wave_jobs \
				"${deploy_status_dir}" \
				"${snapshot_dir}" \
				"${rollback_log_dir}" \
				"${rollback_status_dir}" \
				"${success_hosts_out_name}" \
				"${skipped_hosts_out_name}" \
				"${failed_hosts_out_name}" \
				"$@" || true
			return "${interrupt_rc}"
		fi
	fi
	if force_cancel_requested; then
		cancel_active_deploy_activation_units
	fi
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
	local node="$1" out_file="$2" status_file="$3" log_file="${4:-}"
	local built_out_path="" deploy_start_epoch="" duration_file="" duration_secs=""
	local rc="" skip_marker=""

	wait_before_host_phase "${node}" "deploy"
	duration_file="$(phase_dir_item_duration_file "$(dirname "${status_file}")" "${node}")"

	(
		set +e
		skip_marker="${status_file}.skip"
		rm -f "${skip_marker}"
		deploy_start_epoch="$(date +%s)"
		if [ ! -s "${out_file}" ]; then
			echo "Missing built output path for ${node}: ${out_file}" >&2
			rc=1
		else
			built_out_path="$(cat "${out_file}")"
			if run_streamed_host_command deploy "${node}" "${log_file}" deploy_host "${node}" "${built_out_path}" "${skip_marker}"; then
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
		duration_secs="$(elapsed_seconds "${deploy_start_epoch}")"
		write_duration_file "${duration_file}" "${duration_secs}"
		log_host_phase_duration "${node}" deploy "${duration_secs}" "${log_file}"
		if [ "${rc}" = "0" ] && [ ! -e "${skip_marker}" ]; then
			print_deploy_systemd_user_manager_report "${node}" "${deploy_start_epoch}" "${log_file}" || true
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
		plain | *)
			echo "  - ${node}" >&2
			;;
		esac
	done
}

maybe_rollback_successful_hosts() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	shift 3

	local -a successful_hosts=("$@")
	local rollback_rc=0

	if [ "${DRY_RUN}" -eq 0 ] && [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
		rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${successful_hosts[@]}" || {
			rollback_rc="$?"
			is_signal_exit_status "${rollback_rc}" && return "${rollback_rc}"
		}
	fi

	return 0
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
		ok) ;;
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

mark_snapshot_matched_deploy_skips() {
	local snapshot_dir="$1" build_out_dir="$2" deploy_status_dir="$3"
	local deploy_skipped_hosts_out_name="$4"
	# shellcheck disable=SC2178,SC2034
	local -n msmds_deploy_skipped_hosts_out_ref="${deploy_skipped_hosts_out_name}"
	shift 4

	local node="" snapshot_path="" built_out_file="" built_out_path=""
	local marker_file="" status_file="" duration_file=""

	[ "${NIXBOT_IF_CHANGED}" -eq 1 ] || return 0

	for node in "$@"; do
		[ -n "${node}" ] || continue
		if host_deploy_stage_skipped "${node}"; then
			continue
		fi
		if array_contains "${node}" "${OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS[@]}"; then
			continue
		fi
		if ! snapshot_path="$(read_snapshot_system_path_file "${snapshot_dir}/${node}.path")"; then
			continue
		fi

		built_out_file="${build_out_dir}/${node}.path"
		[ -s "${built_out_file}" ] || continue
		built_out_path="$(<"${built_out_file}")"
		if [ "${snapshot_path}" != "${built_out_path}" ]; then
			continue
		fi

		marker_file="$(snapshot_deploy_skip_marker_file "${snapshot_dir}" "${node}")"
		status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
		duration_file="$(phase_dir_item_duration_file "${deploy_status_dir}" "${node}")"
		: >"${marker_file}"
		write_status_file "${status_file}" "skip"
		write_duration_file "${duration_file}" 0
		append_unique_array_item msmds_deploy_skipped_hosts_out_ref "${node}"
		log_snapshot_deploy_skip "${node}"
	done
}

snapshot_host_with_retry() {
	local node="$1" snapshot_file="$2"
	local parent_host="" ready_timeout=0 ready_interval_secs=0 max_attempts=0 attempt=0 rc=0

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

	while :; do
		if snapshot_host_generation "${node}" "${snapshot_file}"; then
			return 0
		fi
		rc="$?"
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		if [ "${attempt}" -ge "${max_attempts}" ]; then
			return 1
		fi

		echo "[${node}] snapshot | attempt ${attempt}/${max_attempts} failed after parent barrier (${parent_host}); retrying in ${ready_interval_secs}s" >&2
		sleep_for_retry_or_signal "${ready_interval_secs}" || return "$?"
		attempt=$((attempt + 1))
	done
}

run_snapshot_job() {
	local node="$1" snapshot_file="$2" status_file="${3:-}" log_file="${4:-}" rc=0

	(
		set +e
		if [ -n "${status_file}" ]; then
			rm -f "${status_file}"
		fi
		if [ -n "${log_file}" ]; then
			run_streamed_host_command snapshot "${node}" "${log_file}" snapshot_host_with_retry "${node}" "${snapshot_file}"
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
	local verify_parallel="${5:-0}" verify_parallel_jobs="${6:-1}"
	local -a level_hosts=() snapshot_hosts=()
	local node="" active_jobs=0 status_file="" log_file="" status=""

	[ -n "${level_group}" ] || return 0

	mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
	for node in "${level_hosts[@]}"; do
		[ -n "${node}" ] || continue
		if host_deploy_stage_skipped "${node}"; then
			continue
		fi
		snapshot_hosts+=("${node}")
	done

	[ "${#snapshot_hosts[@]}" -gt 0 ] || return 0

	log_subsection "Snapshot Wave 0: $(join_by_comma "${snapshot_hosts[@]}")"
	for node in "${snapshot_hosts[@]}"; do
		[ -n "${node}" ] || continue
		if [ "${verify_parallel}" -eq 1 ]; then
			status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
			log_file="$(phase_dir_item_log_file "${snapshot_log_dir}" "${node}")"
			run_snapshot_job "${node}" "${snapshot_dir}/${node}.path" "${status_file}" "${log_file}" &
			active_jobs=$((active_jobs + 1))
			wait_for_job_slot active_jobs "${verify_parallel_jobs}" || return "$?"
			continue
		fi

		if ! run_snapshot_job "${node}" "${snapshot_dir}/${node}.path"; then
			echo "Initial snapshot for ${node} failed; will retry when its deploy wave is reached" >&2
		fi
	done

	if [ "${verify_parallel}" -eq 1 ]; then
		drain_job_slots active_jobs || return "$?"
		for node in "${snapshot_hosts[@]}"; do
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
	local verify_parallel="${4:-0}" verify_parallel_jobs="${5:-1}"
	shift 5

	local node="" snapshot_file="" rc=0 active_jobs=0 status_file="" log_file="" status=""

	[ "${DRY_RUN}" -eq 0 ] || return 0
	[ "${ROLLBACK_ON_FAILURE}" -eq 1 ] || return 0
	[ "$#" -gt 0 ] || return 0

	for node in "$@"; do
		[ -n "${node}" ] || continue
		if host_deploy_stage_skipped "${node}"; then
			continue
		fi
		snapshot_file="${snapshot_dir}/${node}.path"
		if snapshot_exists "${snapshot_file}"; then
			continue
		fi

		if [ "${verify_parallel}" -eq 1 ]; then
			status_file="$(phase_dir_item_status_file "${snapshot_status_dir}" "${node}")"
			log_file="$(phase_dir_item_log_file "${snapshot_log_dir}" "${node}")"
			run_snapshot_job "${node}" "${snapshot_file}" "${status_file}" "${log_file}" &
			active_jobs=$((active_jobs + 1))
			wait_for_job_slot active_jobs "${verify_parallel_jobs}" || return "$?"
			continue
		fi

		if ! run_snapshot_job "${node}" "${snapshot_file}"; then
			echo "Unable to record pre-deploy generation for ${node}; refusing deploy without rollback snapshot" >&2
			rc=1
		fi
	done

	if [ "${verify_parallel}" -eq 1 ]; then
		drain_job_slots active_jobs || return "$?"
		for node in "$@"; do
			[ -n "${node}" ] || continue
			if host_deploy_stage_skipped "${node}"; then
				continue
			fi
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

wait_for_in_flight_deploy_activation() {
	local node="$1"
	local deploy_unit="" wait_start_epoch="" elapsed_secs="" max_wait_secs="" poll_secs=5
	local state="" last_log_bucket=-1 bucket=0

	deploy_unit="$(deploy_activation_unit_name "${node}")"
	wait_start_epoch="$(date +%s)"
	max_wait_secs=$((NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS + NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS))

	while :; do
		elapsed_secs="$(($(date +%s) - wait_start_epoch))"
		bucket=$((elapsed_secs / 30))

		if [ "${elapsed_secs}" -ge "${max_wait_secs}" ]; then
			echo "==> ${node}: in-flight deploy activation (${deploy_unit}) did not finish within ${elapsed_secs}s; proceeding with rollback" >&2
			return 0
		fi

		if state="$(deploy_activation_unit_state "${node}" 2>/dev/null)"; then
			case "${state}" in
			active | activating | reloading | deactivating)
				if [ "${bucket}" -ne "${last_log_bucket}" ]; then
					echo "==> ${node}: waiting for in-flight deploy activation (${deploy_unit}, state=${state}) to release lock; elapsed ${elapsed_secs}s" >&2
					last_log_bucket="${bucket}"
				fi
				sleep_for_retry_or_signal "${poll_secs}" || return "$?"
				continue
				;;
			esac
			echo "==> ${node}: in-flight deploy activation settled (state=${state:-none}) after ${elapsed_secs}s; proceeding with rollback" >&2
			return 0
		fi

		# Transport failure: the host is likely still overloaded from activation.
		# Keep waiting until it recovers or the timeout expires.
		if [ "${bucket}" -ne "${last_log_bucket}" ]; then
			echo "==> ${node}: host unreachable while checking in-flight deploy activation (${deploy_unit}); elapsed ${elapsed_secs}s" >&2
			last_log_bucket="${bucket}"
		fi
		sleep_for_retry_or_signal "${poll_secs}" || return "$?"
	done
}

rollback_host_to_snapshot() {
	local node="$1" snapshot_path="$2" rollback_cmd="" rollback_script="" rollback_runner="" rollback_unit="" systemd_run_properties=""
	local post_promote_bootloader_goal=""
	local rollback_rc=0 rollback_start_epoch="" rollback_output=""

	[ -n "${snapshot_path}" ] || {
		echo "Rollback snapshot is empty for ${node}" >&2
		return 1
	}

	log_host_stage "rollback" "${node}"
	prepare_deploy_context "${node}" || return 1
	wait_for_in_flight_deploy_activation "${node}" || return "$?"
	rollback_unit="$(rollback_activation_unit_name "${node}")"
	post_promote_bootloader_goal="$(activation_post_promote_bootloader_goal "${node}" switch)" || return "$?"
	rollback_script="$(nixbot_activation_command "${snapshot_path}" switch 1 "${post_promote_bootloader_goal}")"
	rollback_runner="$(nixbot_activation_runner_command "${rollback_script}")"
	systemd_run_properties="$(nixbot_activation_systemd_run_properties)"
	printf -v rollback_cmd \
		'NIXOS_INSTALL_BOOTLOADER=%q systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK --wait --collect --no-ask-password --pipe --quiet --service-type=exec %s--unit=%q %s' \
		0 \
		"${systemd_run_properties}" \
		"${rollback_unit}" \
		"${rollback_runner}"

	echo "${snapshot_path}" >&2
	rollback_start_epoch="$(date +%s)"
	if run_activation_with_progress rollback_output "${node}" rollback "${rollback_unit}" "${rollback_start_epoch}" "${rollback_cmd}"; then
		print_deploy_systemd_user_manager_report "${node}" "${rollback_start_epoch}" || true
		return 0
	else
		rollback_rc="$?"
	fi

	report_activation_lock_contention_if_present "${node}" "${rollback_unit}" "${rollback_start_epoch}" "${rollback_output}" || true

	echo "==> Rollback transport closed or failed for ${node}; verifying target state" >&2
	if verify_rollback_target_state "${node}" "${snapshot_path}" "${rollback_unit}" "${rollback_start_epoch}"; then
		echo "==> Rollback for ${node} completed despite transport disconnect" >&2
		print_deploy_systemd_user_manager_report "${node}" "${rollback_start_epoch}" || true
		return 0
	fi

	return "${rollback_rc}"
}

remote_activation_unit_state_is_running() {
	local state="$1"

	case "${state}" in
	active | activating | reloading | deactivating)
		return 0
		;;
	esac
	return 1
}

verify_rollback_target_state() {
	local node="$1" snapshot_path="$2" rollback_unit="$3" rollback_start_epoch="$4"
	local elapsed_secs=0 max_wait_secs=0 poll_secs=5 last_log_bucket=-1 bucket=0
	local remote_current_path="" state="" state_cmd=""

	max_wait_secs=$((NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS + NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS))
	printf -v state_cmd 'systemctl show --property=ActiveState --value %q 2>/dev/null || true' "${rollback_unit}"

	while :; do
		elapsed_secs="$(($(date +%s) - rollback_start_epoch))"
		bucket=$((elapsed_secs / 30))

		if [ "${elapsed_secs}" -ge "${max_wait_secs}" ]; then
			echo "==> Rollback transport verification for ${node} timed out after ${elapsed_secs}s" >&2
			return 1
		fi

		if prepare_deploy_context "${node}" primary-only >/dev/null 2>&1; then
			remote_current_path="$(read_prepared_current_system_path_without_control_master 2>/dev/null || true)"
			state="$(run_prepared_root_command_without_control_master "${state_cmd}" 2>/dev/null || true)"
			if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${snapshot_path}" ]; then
				if remote_activation_unit_state_is_running "${state}"; then
					:
				elif [ "${state}" = "failed" ]; then
					echo "==> Rollback activation for ${node} settled as failed after switching to ${snapshot_path}" >&2
					return 1
				else
					return 0
				fi
			elif [ -z "${state}" ] || [ "${state}" = "inactive" ] || [ "${state}" = "failed" ]; then
				echo "==> Rollback activation for ${node} settled as ${state} without switching to ${snapshot_path}" >&2
				return 1
			fi
		else
			state="unreachable"
		fi

		if [ "${bucket}" -ne "${last_log_bucket}" ]; then
			echo "==> Rollback transport closed for ${node}; waiting for activation result (elapsed=${elapsed_secs}s state=${state:-unknown})" >&2
			last_log_bucket="${bucket}"
		fi
		sleep_for_retry_or_signal "${poll_secs}" || return "$?"
	done
}

verify_deploy_target_state_after_transport_loss() {
	local node="$1" system_path="$2" activation_unit="$3" activation_start_epoch="$4"
	local elapsed_secs=0 max_wait_secs=0 poll_secs=5 last_log_bucket=-1 bucket=0
	local remote_current_path="" state="" state_cmd=""

	max_wait_secs=$((NIXBOT_REMOTE_ACTIVATION_RUNTIME_MAX_SECS + NIXBOT_REMOTE_ACTIVATION_STOP_TIMEOUT_SECS))
	printf -v state_cmd 'systemctl show --property=ActiveState --value %q 2>/dev/null || true' "${activation_unit}"

	while :; do
		elapsed_secs="$(($(date +%s) - activation_start_epoch))"
		bucket=$((elapsed_secs / 30))

		if [ "${elapsed_secs}" -ge "${max_wait_secs}" ]; then
			echo "==> Deploy transport verification for ${node} timed out after ${elapsed_secs}s" >&2
			return 1
		fi

		if prepare_deploy_context "${node}" primary-only >/dev/null 2>&1; then
			remote_current_path="$(read_prepared_current_system_path_without_control_master 2>/dev/null || true)"
			if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${system_path}" ]; then
				state="$(run_prepared_root_command_without_control_master "${state_cmd}" 2>/dev/null || true)"
				if remote_activation_unit_state_is_running "${state}"; then
					:
				elif [ "${state}" = "failed" ]; then
					echo "==> Deploy activation for ${node} settled as failed after switching to ${system_path}" >&2
					return 1
				else
					return 0
				fi
			else
				state="$(run_prepared_root_command_without_control_master "${state_cmd}" 2>/dev/null || true)"
			fi

			case "${state}" in
			active | activating | reloading | deactivating)
				;;
			"" | inactive | failed)
				echo "==> Deploy activation for ${node} settled as ${state} without switching to ${system_path}" >&2
				return 2
				;;
			esac
		else
			state="unreachable"
		fi

		if [ "${bucket}" -ne "${last_log_bucket}" ]; then
			echo "==> Deploy transport closed for ${node}; waiting for activation result (elapsed=${elapsed_secs}s state=${state:-unknown})" >&2
			last_log_bucket="${bucket}"
		fi
		sleep_for_retry_or_signal "${poll_secs}" || return "$?"
	done
}

rollback_successful_hosts() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	shift 3

	local -a successful_hosts=("$@")
	local rollback_rc=0
	# shellcheck disable=SC2034
	ROLLBACK_OK_HOSTS=()
	# shellcheck disable=SC2034
	ROLLBACK_FAILED_HOSTS=()

	[ "${#successful_hosts[@]}" -gt 0 ] || return 0

	log_section "Phase: Rollback"
	echo "Rolling back ${#successful_hosts[@]} successful host(s) to pre-deploy generations" >&2

	rollback_hosts_to_snapshots \
		"${snapshot_dir}" \
		"${rollback_log_dir}" \
		"${rollback_status_dir}" \
		ROLLBACK_OK_HOSTS \
		ROLLBACK_FAILED_HOSTS \
		"${successful_hosts[@]}" || rollback_rc="$?"

	if [ "${rollback_rc}" -ne 0 ]; then
		echo "Rollback failed for one or more hosts. Check logs under ${rollback_log_dir}" >&2
	fi

	return "${rollback_rc}"
}

run_rollback_job() {
	local node="$1" snapshot_path="$2" status_file="$3" log_file="$4" rc=0

	(
		set +e
		rm -f "${status_file}"
		if run_streamed_host_command rollback "${node}" "${log_file}" rollback_host_to_snapshot "${node}" "${snapshot_path}"; then
			rc=0
		else
			rc="$?"
		fi
		write_status_file "${status_file}" "${rc}"
		exit "${rc}"
	)
}

record_rollback_status() {
	local node="$1" status_file="$2" ok_hosts_name="$3" failed_hosts_name="$4"
	# shellcheck disable=SC2178,SC2034
	local -n rrs_ok_hosts_out_ref="${ok_hosts_name}" rrs_failed_hosts_out_ref="${failed_hosts_name}"
	local status=""

	if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
		append_unique_array_item rrs_failed_hosts_out_ref "${node}"
		return 1
	fi
	if [ "${status}" = "0" ]; then
		append_unique_array_item rrs_ok_hosts_out_ref "${node}"
	else
		append_unique_array_item rrs_failed_hosts_out_ref "${node}"
		is_signal_exit_status "${status}" && return "${status}"
		return 1
	fi

	return 0
}

rollback_host_level_to_snapshots() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	local rollback_ok_hosts_name="$4" rollback_failed_hosts_name="$5"
	shift 5

	local node="" snapshot_file="" snapshot_path="" status_file="" log_file="" active_jobs=0 record_rc=0 rollback_rc=0
	local -a rollback_started_hosts=()

	for node in "$@"; do
		[ -n "${node}" ] || continue
		status_file="$(phase_dir_item_status_file "${rollback_status_dir}" "${node}")"
		log_file="$(phase_dir_item_log_file "${rollback_log_dir}" "${node}")"
		snapshot_file="${snapshot_dir}/${node}.path"

		if ! snapshot_path="$(read_snapshot_system_path_file "${snapshot_file}")"; then
			echo "Rollback unavailable for ${node}: no rollback snapshot recorded" >&2
			write_status_file "${status_file}" "snapshot-missing"
			append_unique_array_item "${rollback_failed_hosts_name}" "${node}"
			rollback_rc=1
			continue
		fi

		if [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ]; then
			run_rollback_job "${node}" "${snapshot_path}" "${status_file}" "${log_file}" &
			rollback_started_hosts+=("${node}")
			active_jobs=$((active_jobs + 1))
			wait_for_job_slot active_jobs "${NIXBOT_PARALLEL_JOBS}" || return "$?"
			continue
		fi

		run_rollback_job "${node}" "${snapshot_path}" "${status_file}" "${log_file}" || true
		record_rollback_status "${node}" "${status_file}" "${rollback_ok_hosts_name}" "${rollback_failed_hosts_name}" || {
			record_rc="$?"
			is_signal_exit_status "${record_rc}" && return "${record_rc}"
			rollback_rc=1
		}
	done

	if [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ]; then
		drain_job_slots active_jobs || return "$?"
		for node in "${rollback_started_hosts[@]}"; do
			[ -n "${node}" ] || continue
			status_file="$(phase_dir_item_status_file "${rollback_status_dir}" "${node}")"
			record_rollback_status "${node}" "${status_file}" "${rollback_ok_hosts_name}" "${rollback_failed_hosts_name}" || {
				record_rc="$?"
				is_signal_exit_status "${record_rc}" && return "${record_rc}"
				rollback_rc=1
			}
		done
	fi

	return "${rollback_rc}"
}

rollback_hosts_to_snapshots() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	local rollback_ok_hosts_name="$4" rollback_failed_hosts_name="$5"
	shift 5

	local selected_json="" levels_json="" level_group="" level_index=0 level_rc=0 rollback_rc=0
	local -a host_levels=() level_hosts=()

	[ "$#" -gt 0 ] || return 0

	selected_json="$(bash_args_to_json_array "$@")"
	levels_json="$(selected_host_levels_json "${selected_json}")"
	mapfile -t host_levels < <(jq -c '.[]' <<<"${levels_json}")

	# Roll back dependency levels in reverse while preserving parallelism within
	# each level. This keeps children/dependents ahead of parent hosts.
	for ((level_index = ${#host_levels[@]} - 1; level_index >= 0; level_index--)); do
		level_group="${host_levels[${level_index}]}"
		mapfile -t level_hosts < <(jq -r '.[]' <<<"${level_group}")
		rollback_host_level_to_snapshots \
			"${snapshot_dir}" \
			"${rollback_log_dir}" \
			"${rollback_status_dir}" \
			"${rollback_ok_hosts_name}" \
			"${rollback_failed_hosts_name}" \
			"${level_hosts[@]}" || {
			level_rc="$?"
			is_signal_exit_status "${level_rc}" && return "${level_rc}"
			rollback_rc="${level_rc}"
		}
	done

	return "${rollback_rc}"
}

rollback_optional_deploy_hosts() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	shift 3

	local node="" rc=0

	[ "$#" -gt 0 ] || return 0
	for node in "$@"; do
		echo "Optional deploy failed for ${node}; attempting host-only rollback" >&2
	done
	rollback_hosts_to_snapshots \
		"${snapshot_dir}" \
		"${rollback_log_dir}" \
		"${rollback_status_dir}" \
		OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS \
		OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS \
		"$@" || {
		rc="$?"
		is_signal_exit_status "${rc}" && return "${rc}"
	}
	return 0
}

rollback_failed_deploy_hosts() {
	rollback_failed_hosts "$1" "$2" "$3" deploy DEPLOY_FAILED_ROLLBACK_OK_HOSTS DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS "${@:4}"
}

rollback_failed_health_hosts() {
	rollback_failed_hosts "$1" "$2" "$3" health HEALTH_FAILED_ROLLBACK_OK_HOSTS HEALTH_FAILED_ROLLBACK_FAILED_HOSTS "${@:4}"
}

rollback_failed_hosts() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	local failure_label="$4" rollback_ok_hosts_name="$5" rollback_failed_hosts_name="$6"
	shift 6

	local node="" rc=0

	[ "$#" -gt 0 ] || return 0
	for node in "$@"; do
		echo "${failure_label} failed for ${node}; attempting host-local rollback" >&2
	done
	rollback_hosts_to_snapshots \
		"${snapshot_dir}" \
		"${rollback_log_dir}" \
		"${rollback_status_dir}" \
		"${rollback_ok_hosts_name}" \
		"${rollback_failed_hosts_name}" \
		"$@" || {
		rc="$?"
		is_signal_exit_status "${rc}" && return "${rc}"
	}
	return 0
}

_remote_pre_switch_system_failed_state_reset() {
	local failed_output=""

	failed_output="$(systemctl list-units --failed --no-legend --plain 2>/dev/null || true)"
	if [ -z "${failed_output}" ]; then
		return 0
	fi

	echo "[pre-switch] resetting failed system units:" >&2
	echo "${failed_output}" >&2
	systemctl reset-failed
}

_remote_pre_switch_user_failed_state_report() {
	local units="" unit="" user="" uid="" runtime_dir="" bus="" failed_output=""

	units="$(systemctl list-unit-files 'systemd-user-manager-dispatcher-*.service' --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' | sort -u || true)"
	if [ -z "${units}" ]; then
		return 0
	fi

	while IFS= read -r unit; do
		[ -n "${unit}" ] || continue
		user="$(systemctl show --property=Environment --value "${unit}" 2>/dev/null | grep -oP 'SYSTEMD_USER_MANAGER_USER=\K[^ ]+' || true)"
		[ -n "${user}" ] || continue
		uid="$(id -u "${user}" 2>/dev/null || true)"
		[ -n "${uid}" ] || continue
		if ! systemctl is-active --quiet "user@${uid}.service" 2>/dev/null; then
			continue
		fi

		runtime_dir="/run/user/${uid}"
		bus="unix:path=${runtime_dir}/bus"
		failed_output="$(
			setpriv --reuid="${user}" --regid="$(id -g "${user}")" --init-groups \
				env XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="${bus}" \
				systemctl --user list-units --failed --no-legend --plain 2>/dev/null || true
		)"

		if [ -z "${failed_output}" ]; then
			continue
		fi

		echo "[pre-switch] preserving failed user units for ${user} for post-switch reconciliation:" >&2
		echo "${failed_output}" >&2
	done <<EOF_USER_RESET_UNITS
${units}
EOF_USER_RESET_UNITS
}

build_pre_switch_user_failed_state_reset_cmd() {
	emit_remote_function_command \
		$'_remote_pre_switch_system_failed_state_reset\n_remote_pre_switch_user_failed_state_report' \
		_remote_pre_switch_system_failed_state_reset \
		_remote_pre_switch_user_failed_state_report
}

run_pre_switch_user_failed_state_reset() {
	local reset_cmd=""

	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi

	reset_cmd="$(build_pre_switch_user_failed_state_reset_cmd)"
	run_prepared_root_command "${reset_cmd}"
}

command_failure_is_host_key_verification() {
	local output_path="$1"

	[ -s "${output_path}" ] || return 1

	command_output_is_host_key_verification "$(<"${output_path}")"
}

command_output_is_host_key_verification() {
	local output="$1"

	[ -n "${output}" ] || return 1

	grep -Eq \
		"REMOTE HOST IDENTIFICATION HAS CHANGED|Host key verification failed|WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key in " \
		<<<"${output}"
}

command_output_is_transport_loss() {
	local output="$1"

	[ -n "${output}" ] || return 1
	if command_output_is_host_key_verification "${output}"; then
		return 1
	fi

	grep -Eq \
		"failed to start SSH connection|mux_client_request_session|kex_exchange_identification|ssh_exchange_identification|Connection reset by peer|Connection closed by remote host|Connection closed by .* port [0-9]+|Received disconnect|client_loop: send disconnect: Broken pipe|Broken pipe|Bad file descriptor|stdio forwarding failed|Connection timed out|No route to host" \
		<<<"${output}"
}

command_failure_is_transport_loss() {
	local output_path="$1"

	[ -s "${output_path}" ] || return 1
	command_output_is_transport_loss "$(<"${output_path}")"
}

remote_store_failure_is_transport_loss() {
	local output_path="$1"

	command_failure_is_transport_loss "${output_path}" && return 0

	[ -s "${output_path}" ] || return 1
	grep -Eq "Nix daemon disconnected unexpectedly|cannot connect to socket at .*nix/daemon-socket/socket" "${output_path}"
}

start_remote_build_heartbeat() {
	local retry_label="$1" interval="${NIXBOT_BUILD_HEARTBEAT_SECS}" start_seconds="${SECONDS}"

	case "${retry_label}" in
	"Remote build on "*) ;;
	*) return 1 ;;
	esac
	[ "${interval}" -gt 0 ] || return 1

	(
		while sleep "${interval}"; do
			echo "${retry_label} still running ($((SECONDS - start_seconds))s)" >&2
		done
	) >/dev/null &
	printf '%s\n' "$!"
}

stop_remote_build_heartbeat() {
	local heartbeat_pid="${1:-}"

	[ -n "${heartbeat_pid}" ] || return 0
	terminate_pid_tree "${heartbeat_pid}" TERM
	wait "${heartbeat_pid}" 2>/dev/null || true
}

_remote_activation_filter_user_units() {
	awk '!($0 ~ /\[systemd-run\].*podman.*healthcheck run / || $0 ~ /\.podman-wrapped healthcheck run /)'
}

_remote_activation_progress_probe() {
	local node="$1" unit="$2" started_at="$3"
	local now="" elapsed=0 active="" sub="" result="" main_pid="" jobs=""
	local failed="" user_managers="" managed_users="" managed_user=""
	local managed_unit="" managed_uid="" managed_runtime="" managed_home="" user_units=""

	now="$(date +%s)"
	elapsed=$((now - started_at))
	active="$(systemctl show "${unit}" --property=ActiveState --value 2>/dev/null || true)"
	sub="$(systemctl show "${unit}" --property=SubState --value 2>/dev/null || true)"
	result="$(systemctl show "${unit}" --property=Result --value 2>/dev/null || true)"
	main_pid="$(systemctl show "${unit}" --property=MainPID --value 2>/dev/null || true)"
	printf '[activation] %s: unit=%s elapsed=%ss state=%s/%s result=%s main_pid=%s\n' "${node}" "${unit}" "${elapsed}" "${active:-unknown}" "${sub:-unknown}" "${result:-unknown}" "${main_pid:-0}"
	jobs="$(systemctl list-jobs --no-legend --plain 2>/dev/null | head -5 || true)"
	if [ -n "${jobs}" ]; then
		printf '[activation] %s: active systemd jobs:\n%s\n' "${node}" "${jobs}"
	else
		printf '[activation] %s: no active systemd jobs; waiting for activation process or remote systemd-run timeout\n' "${node}"
	fi
	failed="$(systemctl --failed --no-legend --plain 2>/dev/null | head -5 || true)"
	if [ -n "${failed}" ]; then
		printf '[activation] %s: failed system units:\n%s\n' "${node}" "${failed}"
	fi
	user_managers="$(systemctl list-units 'systemd-user-manager-*.service' --all --no-legend --plain 2>/dev/null | head -8 || true)"
	if [ -n "${user_managers}" ]; then
		printf '[activation] %s: systemd-user-manager units:\n%s\n' "${node}" "${user_managers}"
	fi

	managed_users="$(
		{
			systemctl list-units 'systemd-user-manager-dispatcher-*.service' --all --no-legend --plain 2>/dev/null |
				awk '{print $1}'
			systemctl list-unit-files 'systemd-user-manager-dispatcher-*.service' --type=service --no-legend --plain 2>/dev/null |
				awk '{print $1}'
		} |
			while IFS= read -r managed_unit; do
				[ -n "$managed_unit" ] || continue
				managed_user="$(systemctl show --property=Environment --value "$managed_unit" 2>/dev/null | grep -oP 'SYSTEMD_USER_MANAGER_USER=\K[^ ]+' || true)"
				if [ -z "$managed_user" ]; then
					managed_user="$(printf '%s\n' "$managed_unit" | sed -E 's/^systemd-user-manager-dispatcher-(.*)\.service$/\1/')"
				fi
				[ -n "$managed_user" ] && printf '%s\n' "$managed_user"
			done |
			sort -u
	)"
	while IFS= read -r managed_user; do
		[ -n "${managed_user}" ] || continue
		managed_uid="$(id -u "${managed_user}" 2>/dev/null || true)"
		[ -n "${managed_uid}" ] || continue
		managed_runtime="/run/user/${managed_uid}"
		[ -d "${managed_runtime}" ] || continue
		managed_home="$(getent passwd "${managed_user}" 2>/dev/null | awk -F: '{print $6}')"
		user_units="$(
			runuser -u "${managed_user}" -- env HOME="${managed_home:-/}" XDG_RUNTIME_DIR="${managed_runtime}" \
				systemctl --user list-units --type=service --state=activating,failed --no-legend --plain 2>/dev/null |
				_remote_activation_filter_user_units |
				head -8 || true
		)"
		if [ -n "${user_units}" ]; then
			printf '[activation] %s: pending/failed user units for %s:\n%s\n' "${node}" "${managed_user}" "${user_units}"
		fi
	done <<<"${managed_users}"
}

activation_progress_probe_script() {
	local node="$1" unit="$2" started_at="$3" invoke_cmd=""

	printf -v invoke_cmd '_remote_activation_progress_probe %q %q %q' \
		"${node}" \
		"${unit}" \
		"${started_at}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_activation_filter_user_units \
		_remote_activation_progress_probe
}

start_activation_progress_heartbeat() {
	local -n saph_pid_out_ref="$1"
	local node="$2" unit="$3" started_at="$4" label="$5"
	local interval="${NIXBOT_ACTIVATION_HEARTBEAT_SECS}" probe_script=""

	saph_pid_out_ref=""
	[ "${interval}" -gt 0 ] || return 1
	probe_script="$(activation_progress_probe_script "${node}" "${unit}" "${started_at}")"

	(
		local remaining=0
		trap 'exit 0' TERM INT
		while :; do
			remaining="${interval}"
			while [ "${remaining}" -gt 0 ]; do
				sleep 1 &
				wait "$!" || exit 0
				remaining=$((remaining - 1))
			done
			if ! run_prepared_root_command_without_control_master "${probe_script}" >&2; then
				echo "[activation] ${node}: ${label} heartbeat probe failed; activation may still be running" >&2
			fi
		done
	) >/dev/null &
	# shellcheck disable=SC2034
	saph_pid_out_ref="$!"
}

stop_activation_progress_heartbeat() {
	local heartbeat_pid="${1:-}"

	[ -n "${heartbeat_pid}" ] || return 0
	terminate_pid_tree "${heartbeat_pid}" TERM
	wait "${heartbeat_pid}" 2>/dev/null || true
}

run_activation_with_progress() {
	# shellcheck disable=SC2034
	local output_out_name="$1" node="$2" label="$3" unit="$4" started_at="$5" command="$6"
	local heartbeat_pid="" rc=0

	start_activation_progress_heartbeat heartbeat_pid "${node}" "${unit}" "${started_at}" "${label}" || true
	if run_with_combined_stream_capture "${output_out_name}" run_prepared_root_command_without_control_master "${command}"; then
		rc=0
	else
		rc="$?"
	fi
	stop_activation_progress_heartbeat "${heartbeat_pid}"
	return "${rc}"
}

restore_saved_trap() {
	local signal_name="$1" saved_trap="$2"

	if [ -n "${saved_trap}" ]; then
		eval "${saved_trap}"
	else
		trap - "${signal_name}"
	fi
}

restore_saved_trap_after_signal() {
	local signal_name="$1" saved_trap="$2"

	if [ -n "${saved_trap}" ]; then
		eval "${saved_trap}"
	else
		trap : "${signal_name}"
	fi
}

mark_supervised_command_interrupted() {
	local exit_status="$1"

	NIXBOT_SUPERVISED_COMMAND_INTERRUPTED_STATUS="${exit_status}"
	NIXBOT_KEEP_DIAG_DIR=1
	[ -z "${heartbeat_pid:-}" ] || kill "${heartbeat_pid}" 2>/dev/null || true
	[ -z "${command_pid:-}" ] || terminate_pid_tree "${command_pid}" TERM
}

run_supervised_stdout_capture() {
	# shellcheck disable=SC2034
	local -n rssc_output_out_ref="$1"
	local stderr_path="${2:-}"
	shift 2
	local rssc_captured="" command_pid="" rc=0 saved_int_trap="" saved_term_trap="" stdout_path=""
	local NIXBOT_SUPERVISED_COMMAND_INTERRUPTED_STATUS=""

	ensure_tmp_dir
	stdout_path="$(tmp_runtime_mktemp stdout "command.stdout.XXXXXX")"
	: >"${stdout_path}"
	saved_int_trap="$(trap -p INT || true)"
	saved_term_trap="$(trap -p TERM || true)"
	trap 'mark_supervised_command_interrupted 130' INT
	trap 'mark_supervised_command_interrupted 143' TERM

	if [ -n "${stderr_path}" ]; then
		"$@" >"${stdout_path}" 2> >(tee "${stderr_path}" >&2) &
	else
		"$@" >"${stdout_path}" &
	fi
	command_pid="$!"

	if wait "${command_pid}"; then
		rc=0
	else
		rc="$?"
	fi

	rssc_captured="$(<"${stdout_path}")"
	# shellcheck disable=SC2034
	rssc_output_out_ref="${rssc_captured}"
	rm -f "${stdout_path}"

	if [ -n "${NIXBOT_SUPERVISED_COMMAND_INTERRUPTED_STATUS}" ] ||
		is_signal_exit_status "${rc}"; then
		restore_saved_trap_after_signal INT "${saved_int_trap}"
		restore_saved_trap_after_signal TERM "${saved_term_trap}"
		return "${NIXBOT_SUPERVISED_COMMAND_INTERRUPTED_STATUS:-${rc}}"
	fi

	restore_saved_trap INT "${saved_int_trap}"
	restore_saved_trap TERM "${saved_term_trap}"
	return "${rc}"
}

run_supervised_combined_capture() {
	# shellcheck disable=SC2034
	local -n rscc_output_out_ref="$1"
	shift
	local rscc_captured=""

	if run_supervised_stdout_capture rscc_captured "" run_with_combined_output "$@"; then
		# shellcheck disable=SC2034
		rscc_output_out_ref="${rscc_captured}"
		return 0
	fi
	local rc="$?"
	# shellcheck disable=SC2034
	rscc_output_out_ref="${rscc_captured}"
	return "${rc}"
}

run_with_combined_stream_capture() {
	# shellcheck disable=SC2034
	local -n rwcsc_output_out_ref="$1"
	shift
	local rwcsc_tmp_dir="" rwcsc_tmp_file="" rwcsc_fifo="" rwcsc_tee_pid="" rwcsc_rc=0

	rwcsc_output_out_ref=""
	rwcsc_tmp_dir="$(mktemp -d)"
	rwcsc_tmp_file="${rwcsc_tmp_dir}/output"
	rwcsc_fifo="${rwcsc_tmp_dir}/stream"
	: >"${rwcsc_tmp_file}"
	if ! mkfifo "${rwcsc_fifo}"; then
		rm -f "${rwcsc_tmp_file}"
		rmdir "${rwcsc_tmp_dir}" 2>/dev/null || true
		return 1
	fi

	tee "${rwcsc_tmp_file}" <"${rwcsc_fifo}" &
	rwcsc_tee_pid="$!"
	if run_with_combined_output "$@" >"${rwcsc_fifo}"; then
		rwcsc_rc=0
	else
		rwcsc_rc="$?"
	fi
	wait "${rwcsc_tee_pid}" || true

	# shellcheck disable=SC2034
	rwcsc_output_out_ref="$(cat "${rwcsc_tmp_file}" 2>/dev/null || true)"
	rm -f "${rwcsc_tmp_file}" "${rwcsc_fifo}"
	rmdir "${rwcsc_tmp_dir}" 2>/dev/null || true
	return "${rwcsc_rc}"
}

run_remote_store_command_with_retry() {
	# shellcheck disable=SC2034
	local -n rrsc_output_out_ref="$1"
	local retry_label="$2" nix_sshopts="$3"
	shift 3
	local attempt=1 rc=0 retry_sleep_secs=0 output_path="" captured="" heartbeat_pid=""

	ensure_tmp_dir
	output_path="$(tmp_runtime_mktemp stderr "remote-store.stderr.XXXXXX")"

	while :; do
		: >"${output_path}"
		heartbeat_pid="$(start_remote_build_heartbeat "${retry_label}" || true)"
		if run_supervised_stdout_capture \
			captured \
			"${output_path}" \
			run_nix_with_optional_sshopts \
			"${nix_sshopts}" \
			"$@"; then
			stop_remote_build_heartbeat "${heartbeat_pid}"
			# shellcheck disable=SC2034
			rrsc_output_out_ref="${captured}"
			rm -f "${output_path}"
			return 0
		else
			rc="$?"
		fi
		stop_remote_build_heartbeat "${heartbeat_pid}"
		# shellcheck disable=SC2034
		rrsc_output_out_ref="${captured}"

		if is_signal_exit_status "${rc}"; then
			rm -f "${output_path}"
			return "${rc}"
		fi

		if [ "${attempt}" -ge "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ] ||
			! remote_store_failure_is_transport_loss "${output_path}"; then
			rm -f "${output_path}"
			return "${rc}"
		fi

		attempt=$((attempt + 1))
		retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
		echo "${retry_label} transport unavailable; retrying (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
		sleep_for_retry_or_signal "${retry_sleep_secs}" || {
			rc="$?"
			rm -f "${output_path}"
			return "${rc}"
		}
	done
}

require_remote_build_cache_for_deploy() {
	require_build_host_cache_config "${BUILD_HOST}"
}

_remote_pre_activation_podman_image_pulls() {
	local system_path="$1" plan="" runner=""

	plan="${system_path}/share/podman-compose/image-pulls.json"
	runner="${system_path}/sw/bin/podman-compose-image-pull-all"

	if [ ! -e "${plan}" ] && [ ! -x "${runner}" ]; then
		return 0
	fi
	if [ ! -s "${plan}" ]; then
		return 0
	fi
	if [ ! -x "${runner}" ]; then
		echo "podman compose image-pull plan exists but runner is missing: ${runner}" >&2
		return 1
	fi

	echo "[pre-activation] pulling declared Podman Compose images from ${plan}" >&2
	NIX_PODMAN_COMPOSE_IMAGE_PULL_PLAN="${plan}" "${runner}"
}

build_pre_activation_podman_image_pulls_cmd() {
	local system_path="$1" invoke_cmd=""

	printf -v invoke_cmd '_remote_pre_activation_podman_image_pulls %q' "${system_path}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_pre_activation_podman_image_pulls
}

run_pre_activation_podman_image_pulls() {
	local node="$1" system_path="$2" pull_cmd=""

	pull_cmd="$(build_pre_activation_podman_image_pulls_cmd "${system_path}")"
	run_prepared_root_command_with_retry \
		"Pre-activation Podman image pulls on ${node}" \
		"${pull_cmd}"
}

activate_prepared_system_path() {
	local node="$1" system_path="$2" activate_cmd="" activation_script="" activation_runner="" activation_unit="" systemd_run_properties=""
	local post_promote_bootloader_goal="" persist_profile=0
	local activation_rc=0 activation_start_epoch="" activation_output="" verification_rc=0
	local attempt=1 retry_sleep_secs=0

	if activation_goal_persists_profile "${GOAL}"; then
		persist_profile=1
	fi
	post_promote_bootloader_goal="$(activation_post_promote_bootloader_goal "${node}" "${GOAL}")" || return "$?"
	activation_script="$(nixbot_activation_command "${system_path}" "${GOAL}" "${persist_profile}" "${post_promote_bootloader_goal}")"
	activation_runner="$(nixbot_activation_runner_command "${activation_script}")"
	systemd_run_properties="$(nixbot_activation_systemd_run_properties)"

	echo "${system_path}" >&2
	while :; do
		activation_unit="$(deploy_activation_attempt_unit_name "${node}" "${attempt}")"
		printf -v activate_cmd \
			'NIXOS_INSTALL_BOOTLOADER=%q systemd-run -E LOCALE_ARCHIVE -E NIXOS_INSTALL_BOOTLOADER -E NIXOS_NO_CHECK --wait --collect --no-ask-password --pipe --quiet --service-type=exec %s--unit=%q %s' \
			0 \
			"${systemd_run_properties}" \
			"${activation_unit}" \
			"${activation_runner}"
		activation_start_epoch="$(date +%s)"
		if run_activation_with_progress activation_output "${node}" deploy "${activation_unit}" "${activation_start_epoch}" "${activate_cmd}"; then
			return 0
		else
			activation_rc="$?"
		fi

		report_activation_lock_contention_if_present "${node}" "${activation_unit}" "${activation_start_epoch}" "${activation_output}" || true
		if command_output_is_transport_loss "${activation_output}" || transport_status_is_retryable "${activation_rc}"; then
			echo "==> Deploy transport closed or failed for ${node}; verifying target state" >&2
			if verify_deploy_target_state_after_transport_loss "${node}" "${system_path}" "${activation_unit}" "${activation_start_epoch}"; then
				echo "==> Deploy for ${node} completed despite transport disconnect" >&2
				print_deploy_systemd_user_manager_report "${node}" "${activation_start_epoch}" || true
				return 0
			else
				verification_rc="$?"
			fi
			if [ "${verification_rc}" -eq 2 ] && [ "${attempt}" -lt "${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}" ]; then
				attempt=$((attempt + 1))
				retry_sleep_secs="$(transport_retry_backoff_seconds "${attempt}")"
				echo "==> Deploy activation for ${node} did not reach ${system_path}; retrying activation (${attempt}/${NIXBOT_TRANSPORT_RETRY_ATTEMPTS}) in ${retry_sleep_secs}s" >&2
				sleep_for_retry_or_signal "${retry_sleep_secs}" || return "$?"
				continue
			fi
		fi
		return "${activation_rc}"
	done
}

target_trusted_public_keys_for_copy() {
	local node="$1" settings_json=""

	run_supervised_stdout_capture settings_json "" nix eval --json --no-write-lock-file ".#nixosConfigurations.${node}.config.nix.settings" || return 1
	jq -r '
		[
			(."trusted-public-keys" // []),
			(."extra-trusted-public-keys" // [])
		]
		| add
		| unique
		| join(" ")
	' <<<"${settings_json}"
}

append_extra_trusted_public_keys_option() {
	local trusted_public_keys="$1"
	# shellcheck disable=SC2178
	local -n aetpko_args_out_ref="$2"

	if [ -n "${trusted_public_keys}" ]; then
		# shellcheck disable=SC2034
		aetpko_args_out_ref+=(--option extra-trusted-public-keys "${trusted_public_keys}")
	fi
}

copy_system_path_from_build_cache_to_prepared_target() {
	local node="$1" system_path="$2" cache_url="" copy_script="" trusted_public_keys=""
	local -a copy_cmd=()

	cache_url="$(build_host_cache_url_for "${BUILD_HOST}")"
	trusted_public_keys="$(target_trusted_public_keys_for_copy "${node}")" || return 1
	copy_cmd=(nix)
	append_extra_trusted_public_keys_option "${trusted_public_keys}" copy_cmd
	copy_cmd+=(copy --from "${cache_url}" "${system_path}")
	copy_script="$(shell_quote_argv "${copy_cmd[@]}")"
	echo "Copying built closure to ${node} from ${BUILD_HOST} cache: ${system_path}" >&2
	run_prepared_root_command_with_retry \
		"Build-cache copy to ${node}" \
		"${copy_script}"
}

copy_system_path_from_build_cache_via_local_to_prepared_target() {
	# shellcheck disable=SC2034
	local node="$1" system_path="$2" cache_url="" target_store_uri="" copy_nix_sshopts="" remote_copy_output="" trusted_public_keys=""
	local -a copy_cmd=()

	if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 1 ]; then
		return 0
	fi

	cache_url="$(build_host_cache_url_for "${BUILD_HOST}")"
	trusted_public_keys="$(target_trusted_public_keys_for_copy "${node}")" || return 1
	target_store_uri="$(format_ssh_store_uri "${PREP_DEPLOY_SSH_TARGET}")"
	copy_nix_sshopts="${PREP_DEPLOY_NIX_SSHOPTS}"
	if [ -n "${copy_nix_sshopts}" ]; then
		copy_nix_sshopts="-S none -o ControlMaster=no ${copy_nix_sshopts}"
	fi
	copy_cmd=(nix)
	append_extra_trusted_public_keys_option "${trusted_public_keys}" copy_cmd
	copy_cmd+=(copy --from "${cache_url}" --to "${target_store_uri}" "${system_path}")

	echo "Relaying built closure to ${node} from ${BUILD_HOST} cache via local client: ${system_path}" >&2
	run_remote_store_command_with_retry \
		remote_copy_output \
		"Build-cache relay to ${node}" \
		"${copy_nix_sshopts}" \
		"${copy_cmd[@]}"
}

copy_system_path_from_local_to_prepared_target() {
	local node="$1" system_path="$2" target_store_uri="" copy_nix_sshopts="" copy_output=""
	local -a copy_cmd=()

	if [ "${PREP_DEPLOY_LOCAL_EXEC}" -eq 1 ]; then
		return 0
	fi

	target_store_uri="$(format_ssh_store_uri "${PREP_DEPLOY_SSH_TARGET}")"
	copy_nix_sshopts="${PREP_DEPLOY_NIX_SSHOPTS}"
	if [ -n "${copy_nix_sshopts}" ]; then
		copy_nix_sshopts="-S none -o ControlMaster=no ${copy_nix_sshopts}"
	fi
	copy_cmd=(nix copy --no-check-sigs --to "${target_store_uri}" "${system_path}")

	echo "Copying built closure to ${node}: ${system_path}" >&2
	if [ "${DRY_RUN}" -eq 1 ]; then
		if [ -n "${copy_nix_sshopts}" ]; then
			printf 'env NIX_SSHOPTS=%q ' "${copy_nix_sshopts}"
		fi
		printf '%q ' "${copy_cmd[@]}"
		echo
		return 0
	fi

	run_remote_store_command_with_retry \
		copy_output \
		"Local build copy to ${node}" \
		"${copy_nix_sshopts}" \
		"${copy_cmd[@]}" || return "$?"
	: "${copy_output}"
}

deploy_remote_build_host_path() {
	local node="$1" built_out_path="$2"
	local age_identity_key="" deploy_rc=0

	run_parented_host_operation_with_retry \
		"${node}" \
		"deploy transport preparation" \
		prepare_host_transport_for_deploy \
		"${node}" \
		1 || return 1

	age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"

	if [ -n "${age_identity_key}" ]; then
		ensure_prepared_host_age_identity_material "${node}" "${age_identity_key}" || return 1
	fi

	run_pre_switch_user_failed_state_reset || return 1

	register_active_deploy "${node}"
	if copy_system_path_from_build_cache_to_prepared_target "${node}" "${built_out_path}" &&
		run_pre_activation_podman_image_pulls "${node}" "${built_out_path}" &&
		mark_deploy_activation_started "${node}" &&
		activate_prepared_system_path "${node}" "${built_out_path}"; then
		deploy_rc=0
	else
		deploy_rc="$?"
	fi
	unregister_active_deploy "${node}"
	return "${deploy_rc}"
}

deploy_build_cache_via_local_client() {
	local node="$1" built_out_path="$2"
	local age_identity_key="" deploy_rc=0

	run_parented_host_operation_with_retry \
		"${node}" \
		"deploy transport preparation" \
		prepare_host_transport_for_deploy \
		"${node}" \
		1 || return 1

	age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"

	if [ -n "${age_identity_key}" ]; then
		ensure_prepared_host_age_identity_material "${node}" "${age_identity_key}" || return 1
	fi

	run_pre_switch_user_failed_state_reset || return 1

	register_active_deploy "${node}"
	if copy_system_path_from_build_cache_via_local_to_prepared_target "${node}" "${built_out_path}" &&
		run_pre_activation_podman_image_pulls "${node}" "${built_out_path}" &&
		mark_deploy_activation_started "${node}" &&
		activate_prepared_system_path "${node}" "${built_out_path}"; then
		deploy_rc=0
	else
		deploy_rc="$?"
	fi

	unregister_active_deploy "${node}"
	return "${deploy_rc}"
}

deploy_host() {
	local node="$1" built_out_path="$2" skip_marker="${3:-}"
	local remote_current_path="" age_identity_key=""
	local deploy_rc=0

	log_host_stage "deploy" "${node}" "${GOAL}"
	if [ -n "$(host_parent_for "${node}")" ]; then
		clear_primary_ready "${node}"
	fi

	if [ "${NIXBOT_IF_CHANGED}" -eq 1 ]; then
		if prepare_deploy_context "${node}" primary-only; then
			remote_current_path="$(read_prepared_current_system_path 2>/dev/null || true)"
		fi
		if [ -n "${remote_current_path}" ] && [ "${remote_current_path}" = "${built_out_path}" ]; then
			echo "[${node}] deploy | skip" >&2
			echo "${built_out_path}" >&2
			if [ -n "${skip_marker}" ]; then
				: >"${skip_marker}"
			fi
			return 0
		fi
		if [ -z "${remote_current_path}" ]; then
			echo "==> Current system read for ${node} unavailable; continuing to deploy transport preparation" >&2
		fi
	fi

	if [ "${BUILD_HOST}" != "local" ]; then
		if remote_build_deploy_uses_local_relay; then
			deploy_build_cache_via_local_client "${node}" "${built_out_path}"
			return "$?"
		fi
		deploy_remote_build_host_path "${node}" "${built_out_path}"
		return "$?"
	fi

	run_parented_host_operation_with_retry \
		"${node}" \
		"deploy transport preparation" \
		prepare_host_transport_for_deploy \
		"${node}" \
		1 || return 1

	age_identity_key="${PREP_DEPLOY_AGE_IDENTITY_KEY}"

	# Missing local age-identity material is a hard precondition failure, not a
	# parent-settle race.
	if [ -n "${age_identity_key}" ]; then
		ensure_prepared_host_age_identity_material "${node}" "${age_identity_key}" || return 1
	fi

	run_pre_switch_user_failed_state_reset || return 1

	if [ "${DRY_RUN}" -eq 1 ]; then
		copy_system_path_from_local_to_prepared_target "${node}" "${built_out_path}" &&
			run_pre_activation_podman_image_pulls "${node}" "${built_out_path}" &&
			activate_prepared_system_path "${node}" "${built_out_path}"
	else
		register_active_deploy "${node}"
		if copy_system_path_from_local_to_prepared_target "${node}" "${built_out_path}" &&
			run_pre_activation_podman_image_pulls "${node}" "${built_out_path}" &&
			mark_deploy_activation_started "${node}" &&
			activate_prepared_system_path "${node}" "${built_out_path}"; then
			deploy_rc=0
		else
			deploy_rc="$?"
		fi

		unregister_active_deploy "${node}"
		return "${deploy_rc}"
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
	keep_diag_on_failure
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

clean_nixbot_root() {
	local root="$1" mode="$2" path=""

	if [ "${mode}" = "all" ]; then
		if [ -e "${root}" ] || [ -L "${root}" ]; then
			if [ "${DRY_RUN}" -eq 1 ]; then
				printf 'would remove %s\n' "${root}"
			else
				printf 'remove %s\n' "${root}"
				rm -rf -- "${root}"
			fi
		else
			printf 'absent %s\n' "${root}"
		fi
		return 0
	fi

	if [ ! -d "${root}" ]; then
		printf 'absent %s\n' "${root}"
		return 0
	fi

	while IFS= read -r path; do
		[ -n "${path}" ] || continue
		if [ "${DRY_RUN}" -eq 1 ]; then
			printf 'would remove %s\n' "${path}"
		else
			printf 'remove %s\n' "${path}"
			rm -rf -- "${path}"
		fi
	done < <(
		find "${root}" -maxdepth 1 -mindepth 1 -type d \
			\( -name 'run-*' -o -name 'diag-*' \) \
			-mmin +1440 -print 2>/dev/null
	)
	rmdir "${root}" 2>/dev/null || true
}

run_clean_action() {
	local mode="${NIXBOT_CLEAN_MODE:-auto}" rc=0

	log_section "nixbot"
	echo "Version: ${NIXBOT_VERSION}" >&2
	echo "Action: clean" >&2
	echo "Started: ${NIXBOT_RUN_STARTED_AT}" >&2

	log_section "Phase: Clean"
	echo "Mode: ${mode}" >&2
	clean_nixbot_root "${RUNTIME_WORK_ROOT}" "${mode}" || rc=1
	clean_nixbot_root "${NIXBOT_DIAG_KEEP_ROOT}" "${mode}" || rc=1

	log_section "Phase: Summary"
	echo "Action: clean" >&2
	echo "Started: ${NIXBOT_RUN_STARTED_AT}" >&2
	echo "Mode: ${mode}" >&2
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "Dry run: true" >&2
	fi
	if [ "${rc}" -eq 0 ]; then
		echo "Result: success" >&2
	else
		echo "Result: failure" >&2
	fi
	return "${rc}"
}

_remote_clear_lock_path() {
	local path="$1" holders_file="${2:-}" force_held="${3:-0}" holders=""

	if [ -n "$holders_file" ] && [ -f "$holders_file" ]; then
		holders="$(_remote_lock_holder_lines_from_file "$holders_file" "$path")"
	else
		holders="$(_remote_lock_holder_lines_for_path "$path")"
	fi
	if [ -n "$holders" ]; then
		if [ "$force_held" -eq 1 ]; then
			printf 'force-remove held %s\n' "$path" >&2
		else
			printf 'held %s\n' "$path" >&2
		fi
		printf '%s\n' "$holders" >&2
		[ "$force_held" -eq 1 ] || return 1
	fi

	if [ -e "$path" ] || [ -L "$path" ]; then
		printf 'remove %s\n' "$path"
		rm -rf -- "$path"
	else
		printf 'absent %s\n' "$path"
	fi
}

_remote_clear_lock_paths_from_find() {
	local holders_file="${1:-}" force_held="${2:-0}" path="" rc=0

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		_remote_clear_lock_path "$path" "$holders_file" "$force_held" || rc=1
	done
	return "$rc"
}

_remote_lock_fd_holder_line() {
	local fd_path="$1" link_target="$2"
	local pid="" fd="" user="" comm="" cgroup=""

	pid="${fd_path#/proc/}"
	pid="${pid%%/*}"
	fd="${fd_path##*/}"
	user="$(stat -c %U "/proc/$pid" 2>/dev/null || printf '?')"
	comm="$(cat "/proc/$pid/comm" 2>/dev/null || printf '?')"
	cgroup="$(sed -n 's|^[^:]*:[^:]*:||p' "/proc/$pid/cgroup" 2>/dev/null | tail -n 1)"
	printf '  pid=%s fd=%s user=%s comm=%s cgroup=%s target=%s\n' \
		"$pid" "$fd" "$user" "$comm" "${cgroup:-?}" "$link_target"
}

_remote_lock_holder_lines_for_path() {
	local path="$1" fd_path="" link_target=""

	for fd_path in /proc/[0-9]*/fd/*; do
		[ -e "$fd_path" ] || continue
		link_target="$(readlink "$fd_path" 2>/dev/null || true)"
		case "$link_target" in
		"$path" | "$path (deleted)")
			_remote_lock_fd_holder_line "$fd_path" "$link_target"
			;;
		esac
	done
}

_remote_collect_lock_holders_file() {
	local holders_file="$1" fd_path="" link_target="" lock_path="" holder_line=""

	: >"$holders_file"
	for fd_path in /proc/[0-9]*/fd/*; do
		[ -e "$fd_path" ] || continue
		link_target="$(readlink "$fd_path" 2>/dev/null || true)"
		case "$link_target" in
		*'/.podman-compose/lifecycle.lock' | *'/podman-compose/rootless-lifecycle-v1.lock' | *'/state-locks/'*'.lock' | *'/ssh-tty.lock' | *'/nixbot-worktree.lock' | *'/.nixbot-worktree.lock')
			lock_path="$link_target"
			;;
		*'/.podman-compose/lifecycle.lock (deleted)' | *'/podman-compose/rootless-lifecycle-v1.lock (deleted)' | *'/state-locks/'*'.lock (deleted)' | *'/ssh-tty.lock (deleted)' | *'/nixbot-worktree.lock (deleted)' | *'/.nixbot-worktree.lock (deleted)')
			lock_path="${link_target% (deleted)}"
			;;
		*)
			continue
			;;
		esac
		holder_line="$(_remote_lock_fd_holder_line "$fd_path" "$link_target")"
		printf '%s\t%s\n' "$lock_path" "$holder_line" >>"$holders_file"
	done
}

_remote_lock_holder_lines_from_file() {
	local holders_file="$1" path="$2"

	awk -F '\t' -v path="$path" '$1 == path { sub(/^[^\t]*\t/, ""); print }' "$holders_file"
}

_remote_audit_lock_path() {
	local path="$1" holders=""

	holders="$(_remote_lock_holder_lines_for_path "$path")"
	if [ -n "$holders" ]; then
		printf 'held %s\n' "$path"
		printf '%s\n' "$holders"
		return 0
	fi
	return 1
}

_remote_clear_locks_from_emitter() {
	local emitter="$1" force_held="${2:-0}" holders_file="" rc=0

	holders_file="$(mktemp "${TMPDIR:-/tmp}/nixbot-lock-holders.XXXXXX")"
	_remote_collect_lock_holders_file "$holders_file"
	"$emitter" |
		awk 'NF && !seen[$0]++' |
		_remote_clear_lock_paths_from_find "$holders_file" "$force_held" || rc="$?"
	rm -f "$holders_file"
	return "$rc"
}

_remote_clear_emit_nixbot_locks() {
	local root=""

	for root in /dev/shm/nixbot "${TMPDIR:-/tmp}/nixbot"; do
		[ -d "$root" ] || continue
		find "$root" -xdev -depth -path '*/state-locks/*.lock' -type d -print 2>/dev/null
		find "$root" -xdev -depth -name 'ssh-tty.lock' -type d -print 2>/dev/null
	done

	if [ -d /var/lib/nixbot ]; then
		find /var/lib/nixbot -xdev -depth \
			\( -name 'nixbot-worktree.lock' -o -name '.nixbot-worktree.lock' \) \
			-type d -print 2>/dev/null
	fi
}

_remote_clear_nixbot_locks() {
	local force_held="${1:-0}"

	_remote_clear_locks_from_emitter _remote_clear_emit_nixbot_locks "$force_held"
}

_remote_clear_emit_declared_podman_lifecycle_locks() {
	local registry="/run/current-system/share/podman-compose/control-registry.json"
	local metadata_file="" working_dir=""

	[ -f "$registry" ] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	while IFS= read -r metadata_file; do
		[ -n "$metadata_file" ] || continue
		[ -f "$metadata_file" ] || continue
		working_dir="$(jq -r '.workingDir // empty' "$metadata_file" 2>/dev/null || true)"
		[ -n "$working_dir" ] || continue
		printf '%s/.podman-compose/lifecycle.lock\n' "$working_dir"
	done < <(jq -r 'to_entries[]?.value.metadataFile // empty' "$registry" 2>/dev/null || true)
}

_remote_clear_emit_fallback_podman_lifecycle_locks() {
	[ -d /var/lib ] || return 0
	find /var/lib -xdev -path '*/.podman-compose/lifecycle.lock' -type f -print 2>/dev/null || true
}

_remote_clear_emit_rootless_podman_lifecycle_locks() {
	[ -d /run/user ] || return 0
	find /run/user -xdev -path '*/podman-compose/rootless-lifecycle-v1.lock' -type f -print 2>/dev/null || true
}

_remote_clear_emit_podman_locks() {
	{
		_remote_clear_emit_rootless_podman_lifecycle_locks
		_remote_clear_emit_declared_podman_lifecycle_locks
		_remote_clear_emit_fallback_podman_lifecycle_locks
	}
}

_remote_clear_podman_locks() {
	local force_held="${1:-0}"

	_remote_clear_locks_from_emitter _remote_clear_emit_podman_locks "$force_held"
}

_remote_audit_nixbot_locks() {
	local emitted=0 path=""

	while IFS= read -r path; do
		[ -n "$path" ] || continue
		_remote_audit_lock_path "$path" && emitted=1
	done < <(_remote_clear_emit_nixbot_locks | awk 'NF && !seen[$0]++')
	[ "$emitted" -eq 1 ] || printf 'no held nixbot locks\n'
}

_remote_audit_podman_locks() {
	local emitted=0 fd_path="" link_target="" lock_path="" deleted=""

	for fd_path in /proc/[0-9]*/fd/*; do
		[ -e "$fd_path" ] || continue
		link_target="$(readlink "$fd_path" 2>/dev/null || true)"
		deleted=0
		case "$link_target" in
		*'/.podman-compose/lifecycle.lock' | *'/podman-compose/rootless-lifecycle-v1.lock')
			lock_path="$link_target"
			;;
		*'/.podman-compose/lifecycle.lock (deleted)' | *'/podman-compose/rootless-lifecycle-v1.lock (deleted)')
			lock_path="${link_target% (deleted)}"
			deleted=1
			;;
		*)
			continue
			;;
		esac
		if [ "$deleted" -eq 1 ]; then
			printf 'held deleted %s\n' "$lock_path"
		else
			printf 'held %s\n' "$lock_path"
		fi
		_remote_lock_fd_holder_line "$fd_path" "$link_target"
		emitted=1
	done
	[ "$emitted" -eq 1 ] || printf 'no held podman lifecycle locks\n'
}

_remote_audit_remote_locks() {
	local clear_remote_locks_mode="$1"

	set -Eeuo pipefail
	case "$clear_remote_locks_mode" in
	all)
		_remote_audit_nixbot_locks
		_remote_audit_podman_locks
		;;
	nixbot)
		_remote_audit_nixbot_locks
		;;
	podman)
		_remote_audit_podman_locks
		;;
	*)
		printf 'unsupported clear-remote-locks mode: %s\n' "$clear_remote_locks_mode" >&2
		exit 2
		;;
	esac
}

_remote_clear_remote_locks() {
	local clear_remote_locks_mode="$1" force_held="${2:-0}"

	set -Eeuo pipefail
	case "$clear_remote_locks_mode" in
	all)
		_remote_clear_nixbot_locks "$force_held"
		_remote_clear_podman_locks "$force_held"
		;;
	nixbot)
		_remote_clear_nixbot_locks "$force_held"
		;;
	podman)
		_remote_clear_podman_locks "$force_held"
		;;
	*)
		printf 'unsupported clear-remote-locks mode: %s\n' "$clear_remote_locks_mode" >&2
		exit 2
		;;
	esac
}

build_clear_remote_locks_command() {
	local mode="$1" force_held="${2:-0}" invoke_cmd=""

	printf -v invoke_cmd '_remote_clear_remote_locks %q %q' "${mode}" "${force_held}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_clear_lock_path \
		_remote_clear_lock_paths_from_find \
		_remote_lock_fd_holder_line \
		_remote_lock_holder_lines_for_path \
		_remote_collect_lock_holders_file \
		_remote_lock_holder_lines_from_file \
		_remote_audit_lock_path \
		_remote_clear_locks_from_emitter \
		_remote_clear_emit_nixbot_locks \
		_remote_clear_nixbot_locks \
		_remote_clear_emit_declared_podman_lifecycle_locks \
		_remote_clear_emit_fallback_podman_lifecycle_locks \
		_remote_clear_emit_rootless_podman_lifecycle_locks \
		_remote_clear_emit_podman_locks \
		_remote_clear_podman_locks \
		_remote_clear_remote_locks
}

build_audit_remote_locks_command() {
	local mode="$1" invoke_cmd=""

	printf -v invoke_cmd '_remote_audit_remote_locks %q' "${mode}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_lock_fd_holder_line \
		_remote_lock_holder_lines_for_path \
		_remote_audit_lock_path \
		_remote_clear_emit_nixbot_locks \
		_remote_clear_emit_declared_podman_lifecycle_locks \
		_remote_clear_emit_fallback_podman_lifecycle_locks \
		_remote_clear_emit_rootless_podman_lifecycle_locks \
		_remote_audit_nixbot_locks \
		_remote_audit_podman_locks \
		_remote_audit_remote_locks
}

run_clear_remote_locks_for_host() {
	local node="$1" mode="${2:-all}" script="" action_label="Clear locks"

	log_host_stage clear-remote-locks "${node}" "mode=${mode}"
	if ! prepare_deploy_context "${node}" primary-only; then
		log_group_end_host_stage clear-remote-locks
		return 1
	fi

	if [ "${DRY_RUN}" -eq 1 ]; then
		script="$(build_audit_remote_locks_command "${mode}")"
		action_label="Audit held locks"
		DRY_RUN=0
		if run_prepared_root_command_with_retry "${action_label} on ${node}" "${script}"; then
			DRY_RUN=1
			log_group_end_host_stage clear-remote-locks
			return 0
		fi
		DRY_RUN=1
		log_group_end_host_stage clear-remote-locks
		return 1
	else
		script="$(build_clear_remote_locks_command "${mode}" "${FORCE_REQUESTED}")"
	fi

	if run_prepared_root_command_with_retry "${action_label} on ${node}" "${script}"; then
		log_group_end_host_stage clear-remote-locks
		return 0
	fi
	log_group_end_host_stage clear-remote-locks
	return 1
}

run_clear_remote_locks_job() {
	local node="$1" mode="$2" status_file="$3" rc=0

	(
		set +e
		if [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
			run_with_prefixed_combined_output \
				clear-remote-locks \
				"${node}" \
				"" \
				run_clear_remote_locks_for_host \
				"${node}" \
				"${mode}"
		else
			run_clear_remote_locks_for_host "${node}" "${mode}"
		fi
		rc="$?"
		write_status_file "${status_file}" "${rc}"
		exit "${rc}"
	)
}

run_clear_remote_locks_action() {
	local selected_json="$1" runnable_selected_json="" node="" final_rc=0 mode="${NIXBOT_CLEAR_REMOTE_LOCKS_MODE:-all}"
	local status_dir="" status_file="" active_jobs=0 clear_parallel=0 phase_rc=0
	local -a selected_hosts=() cleared_hosts=() failed_hosts=()

	runnable_selected_json="$(filter_runnable_hosts_json "${selected_json}")"
	json_array_to_bash_array "${runnable_selected_json}" selected_hosts

	ensure_tmp_dir
	status_dir="${NIXBOT_TMP_DIR}/clear-remote-locks-status"
	mkdir -p "${status_dir}"

	if [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ] && [ "${#selected_hosts[@]}" -gt 1 ]; then
		clear_parallel=1
	fi

	if [ "${clear_parallel}" -eq 1 ]; then
		log_grouped_phase_section "Phase: Clear Remote Locks" "clear-remote-locks" 1
	else
		log_grouped_phase_section "Phase: Clear Remote Locks" "clear-remote-locks" 0
	fi

	for node in "${selected_hosts[@]}"; do
		[ -n "${node}" ] || continue

		status_file="$(phase_dir_item_status_file "${status_dir}" "${node}")"
		if [ "${clear_parallel}" -eq 1 ]; then
			run_clear_remote_locks_job "${node}" "${mode}" "${status_file}" &
			active_jobs=$((active_jobs + 1))
			if wait_for_job_slot active_jobs "${NIXBOT_PARALLEL_JOBS}"; then
				:
			else
				phase_rc="$?"
				log_group_scope_end
				return "${phase_rc}"
			fi
			continue
		fi

		if run_clear_remote_locks_job "${node}" "${mode}" "${status_file}"; then
			:
		else
			:
		fi
	done

	if [ "${clear_parallel}" -eq 1 ]; then
		if drain_job_slots active_jobs; then
			:
		else
			phase_rc="$?"
			log_group_scope_end
			return "${phase_rc}"
		fi
	fi

	for node in "${selected_hosts[@]}"; do
		[ -n "${node}" ] || continue

		status_file="$(phase_dir_item_status_file "${status_dir}" "${node}")"
		if [ "$(read_status_file "${status_file}" 2>/dev/null || printf '1')" = "0" ]; then
			cleared_hosts+=("${node}")
		else
			failed_hosts+=("${node}")
			final_rc=1
		fi
	done
	log_group_scope_end

	capture_current_run_summary_state \
		"${ACTION}" \
		selected_hosts \
		cleared_hosts \
		failed_hosts \
		empty_hosts \
		empty_hosts \
		empty_hosts \
		empty_hosts
	return "${final_rc}"
}

##### Host Phase Artifacts #####

init_run_dirs() {
	local diag_dir="$1" run_dir="$2" phase=""
	local -n ird_build_log_dir_out_ref="$3" ird_build_status_dir_out_ref="$4"
	local -n ird_snapshot_log_dir_out_ref="$5" ird_snapshot_status_dir_out_ref="$6"
	local -n ird_deploy_log_dir_out_ref="$7" ird_deploy_status_dir_out_ref="$8"
	local -n ird_build_out_dir_out_ref="$9" ird_snapshot_dir_out_ref="${10}"
	local -n ird_rollback_log_dir_out_ref="${11}" ird_rollback_status_dir_out_ref="${12}"
	local -n ird_health_log_dir_out_ref="${13}" ird_health_status_dir_out_ref="${14}"

	# shellcheck disable=SC2034
	{
		ird_build_log_dir_out_ref="$(phase_log_dir_path "${diag_dir}" "build")"
		ird_build_status_dir_out_ref="$(phase_status_dir_path "${diag_dir}" "build")"
		ird_snapshot_log_dir_out_ref="$(phase_log_dir_path "${diag_dir}" "snapshot")"
		ird_snapshot_status_dir_out_ref="$(phase_status_dir_path "${diag_dir}" "snapshot")"
		ird_deploy_log_dir_out_ref="$(phase_log_dir_path "${diag_dir}" "deploy")"
		ird_deploy_status_dir_out_ref="$(phase_status_dir_path "${diag_dir}" "deploy")"
		ird_build_out_dir_out_ref="${run_dir}/build-outs"
		ird_snapshot_dir_out_ref="${run_dir}/snapshots"
		ird_rollback_log_dir_out_ref="$(phase_log_dir_path "${diag_dir}" "rollback")"
		ird_rollback_status_dir_out_ref="$(phase_status_dir_path "${diag_dir}" "rollback")"
		ird_health_log_dir_out_ref="$(phase_log_dir_path "${diag_dir}" "health")"
		ird_health_status_dir_out_ref="$(phase_status_dir_path "${diag_dir}" "health")"
	}

	ensure_phase_artifact_dirs "${diag_dir}" build snapshot deploy rollback health
	for phase in build snapshot deploy rollback health; do
		mkdir -p "$(phase_artifact_dir_path "${run_dir}" "${phase}")"
	done
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

phase_dir_item_duration_file() {
	local status_dir="$1" item="$2"

	printf '%s/%s.duration\n' "${status_dir}" "${item}"
}

_remote_systemd_user_manager_unit_is_terminal() {
	local unit="$1" active_state="" sub_state="" result=""

	active_state="$(systemctl show --property=ActiveState --value "${unit}" 2>/dev/null || true)"
	sub_state="$(systemctl show --property=SubState --value "${unit}" 2>/dev/null || true)"
	result="$(systemctl show --property=Result --value "${unit}" 2>/dev/null || true)"
	case "${active_state}:${sub_state}:${result}" in
	active:exited:success | inactive:dead:success | failed:failed:* | inactive:dead:failed)
		return 0
		;;
	esac
	return 1
}

_remote_systemd_user_manager_journal_line_is_noise() {
	local line="$1"
	local journal_noise_re='^(Starting |Started |Finished |Stopped |systemd-user-manager-(dispatcher|reconciler)-.*: Deactivated successfully\.)'

	[[ "${line}" =~ ${journal_noise_re} ]]
}

_remote_systemd_user_manager_emit_journal_file_lines() {
	local journal_file="$1" line=""

	[ -s "${journal_file}" ] || return 0

	while IFS= read -r line || [ -n "${line}" ]; do
		if _remote_systemd_user_manager_journal_line_is_noise "${line}"; then
			continue
		fi
		printf '  %s\n' "${line}"
	done <"${journal_file}"
}

_remote_systemd_user_manager_emit_new_journal() {
	local cursor_file="$1"
	shift
	local tmp_file="" content_file="" last_line="" cursor="" journalctl_rc=0

	tmp_file="$(mktemp)"
	if [ -s "${cursor_file}" ]; then
		if timeout 1s \
			journalctl \
			--after-cursor "$(cat "${cursor_file}")" \
			--show-cursor \
			--no-pager \
			-o cat \
			"$@" >"${tmp_file}" 2>/dev/null; then
			:
		else
			journalctl_rc=$?
		fi
	else
		if timeout 1s \
			journalctl \
			--show-cursor \
			--no-pager \
			-o cat \
			"$@" >"${tmp_file}" 2>/dev/null; then
			:
		else
			journalctl_rc=$?
		fi
	fi

	if [ "${journalctl_rc}" -eq 124 ]; then
		rm -f "${tmp_file}"
		return 124
	fi

	if [ ! -s "${tmp_file}" ]; then
		rm -f "${tmp_file}"
		return 1
	fi

	content_file="${tmp_file}"
	last_line="$(tail -n 1 "${tmp_file}")"
	if [[ "${last_line}" == --\ cursor:\ * ]]; then
		cursor="${last_line#-- cursor: }"
		printf '%s\n' "${cursor}" >"${cursor_file}"
		content_file="$(mktemp)"
		sed '$d' "${tmp_file}" >"${content_file}"
		rm -f "${tmp_file}"
	fi

	_remote_systemd_user_manager_emit_journal_file_lines "${content_file}"
	rm -f "${content_file}"
	return 0
}

_remote_systemd_user_manager_stream_unit() {
	local unit="$1"
	local active_state="" sub_state="" result="" exec_main_status="" summary=""
	local dispatcher_invocation_id="" dispatcher_cursor_file=""

	dispatcher_invocation_id="$(systemctl show --property=InvocationID --value "${unit}" 2>/dev/null || true)"
	dispatcher_cursor_file="$(mktemp)"

	while :; do
		if [ -n "${dispatcher_invocation_id}" ]; then
			_remote_systemd_user_manager_emit_new_journal \
				"${dispatcher_cursor_file}" \
				_SYSTEMD_INVOCATION_ID="${dispatcher_invocation_id}" ||
				true
		fi

		if _remote_systemd_user_manager_unit_is_terminal "${unit}"; then
			break
		fi

		sleep 0.5
	done

	if [ -n "${dispatcher_invocation_id}" ]; then
		_remote_systemd_user_manager_emit_new_journal \
			"${dispatcher_cursor_file}" \
			_SYSTEMD_INVOCATION_ID="${dispatcher_invocation_id}" ||
			true
	fi

	active_state="$(systemctl show --property=ActiveState --value "${unit}" 2>/dev/null || true)"
	sub_state="$(systemctl show --property=SubState --value "${unit}" 2>/dev/null || true)"
	result="$(systemctl show --property=Result --value "${unit}" 2>/dev/null || true)"
	exec_main_status="$(systemctl show --property=ExecMainStatus --value "${unit}" 2>/dev/null || true)"
	if [ "${result}" = "success" ] || [ -z "${result}" ]; then
		summary='ok'
	else
		summary='FAIL'
	fi
	printf '%s\n' "${unit}: ${summary} (${active_state}/${sub_state}, result=${result:-unknown}, exec=${exec_main_status:-unknown})"

	rm -f "${dispatcher_cursor_file}"
}

_remote_systemd_user_manager_report() {
	local since="$1" units="" unit="" recent=""

	units="$(systemctl list-unit-files 'systemd-user-manager-dispatcher-*.service' --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' | sort -u || true)"
	if [ -z "${units}" ]; then
		return 0
	fi

	while IFS= read -r unit; do
		[ -n "${unit}" ] || continue
		recent="$(journalctl -u "${unit}" --since "${since}" --no-pager -n 1 -o cat 2>/dev/null || true)"
		[ -n "${recent}" ] || continue
		_remote_systemd_user_manager_stream_unit "${unit}"
	done <<EOF_UNITS
${units}
EOF_UNITS
}

_remote_post_switch_user_health_check_once() {
	local units="" unit="" user="" uid="" home="" runtime_dir="" bus=""
	local raw_failed_output="" failed_output="" ignored_failed_output=""
	local raw_system_failed_output="" system_failed_output="" ignored_system_failed_output=""
	local raw_transitional_output="" transitional_output=""
	local raw_system_transitional_output="" system_transitional_output=""
	local podman_unhealthy_output="" podman_starting_output=""
	local system_podman_unhealthy_output="" system_podman_starting_output=""
	local had_failures=0 had_starting=0
	local starting_output=""

	raw_system_failed_output="$(systemctl list-units --failed --no-legend --plain 2>/dev/null || true)"
	system_failed_output="$(printf '%s\n' "${raw_system_failed_output}" | _remote_health_check_filter_failed_units)"
	ignored_system_failed_output="$(printf '%s\n' "${raw_system_failed_output}" | _remote_health_check_ignored_failed_units)"
	if [ -n "${ignored_system_failed_output}" ]; then
		echo "[health-check] transient system Podman healthcheck units observed; checking current container health:" >&2
		echo "${ignored_system_failed_output}" >&2
	fi
	if [ -n "${system_failed_output}" ]; then
		had_failures=1
		echo "[health-check] FAILED system units:" >&2
		echo "${system_failed_output}" >&2
	fi
	raw_system_transitional_output="$(systemctl list-units --state=activating,deactivating,reloading --type=service --no-legend --plain 2>/dev/null || true)"
	system_transitional_output="$(printf '%s\n' "${raw_system_transitional_output}" | _remote_health_check_filter_transitional_units)"
	if [ -n "${system_transitional_output}" ]; then
		had_starting=1
		starting_output="${starting_output}${starting_output:+
}[system units still settling]
${system_transitional_output}"
	fi
	system_podman_unhealthy_output="$(_remote_health_check_podman_unhealthy_containers)"
	if [ -n "${system_podman_unhealthy_output}" ]; then
		had_failures=1
		echo "[health-check] UNHEALTHY system Podman containers:" >&2
		echo "${system_podman_unhealthy_output}" >&2
	fi
	system_podman_starting_output="$(_remote_health_check_podman_starting_containers)"
	if [ -n "${system_podman_starting_output}" ]; then
		had_starting=1
		starting_output="${starting_output}${starting_output:+
}[system]
${system_podman_starting_output}"
	fi

	units="$(systemctl list-unit-files 'systemd-user-manager-dispatcher-*.service' --type=service --no-legend --plain 2>/dev/null | awk '{print $1}' | sort -u || true)"
	while IFS= read -r unit; do
		[ -n "${unit}" ] || continue
		user="$(systemctl show --property=Environment --value "${unit}" 2>/dev/null | grep -oP 'SYSTEMD_USER_MANAGER_USER=\K[^ ]+' || true)"
		[ -n "${user}" ] || continue
		uid="$(id -u "${user}" 2>/dev/null || true)"
		[ -n "${uid}" ] || continue
		home="$(getent passwd "${user}" | cut -d: -f6 || true)"
		[ -n "${home}" ] || home="/"
		if ! systemctl is-active --quiet "user@${uid}.service" 2>/dev/null; then
			continue
		fi
		runtime_dir="/run/user/${uid}"
		bus="unix:path=${runtime_dir}/bus"
		raw_failed_output="$(
			setpriv --reuid="${user}" --regid="$(id -g "${user}")" --init-groups \
				env XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="${bus}" \
				systemctl --user list-units --failed --no-legend --plain 2>/dev/null || true
		)"
		failed_output="$(printf '%s\n' "${raw_failed_output}" | _remote_health_check_filter_failed_units)"
		ignored_failed_output="$(printf '%s\n' "${raw_failed_output}" | _remote_health_check_ignored_failed_units)"
		if [ -n "${ignored_failed_output}" ]; then
			echo "[health-check] transient Podman healthcheck units observed for user ${user}; checking current container health:" >&2
			echo "${ignored_failed_output}" >&2
		fi
		if [ -n "${failed_output}" ]; then
			had_failures=1
			echo "[health-check] FAILED units for user ${user}:" >&2
			echo "${failed_output}" >&2
		fi
		raw_transitional_output="$(
			setpriv --reuid="${user}" --regid="$(id -g "${user}")" --init-groups \
				env XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="${bus}" \
				systemctl --user list-units --state=activating,deactivating,reloading --type=service --no-legend --plain 2>/dev/null || true
		)"
		transitional_output="$(printf '%s\n' "${raw_transitional_output}" | _remote_health_check_filter_transitional_units)"
		if [ -n "${transitional_output}" ]; then
			had_starting=1
			starting_output="${starting_output}${starting_output:+
}[user ${user} units still settling]
${transitional_output}"
		fi
		podman_unhealthy_output="$(
			cd /
			setpriv --reuid="${user}" --regid="$(id -g "${user}")" --init-groups \
				env HOME="${home}" XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="${bus}" \
				sh -c 'cd /; podman ps --filter health=unhealthy --format "unhealthy {{.Names}} {{.Status}}" 2>/dev/null || true'
		)"
		if [ -n "${podman_unhealthy_output}" ]; then
			had_failures=1
			echo "[health-check] UNHEALTHY Podman containers for user ${user}:" >&2
			echo "${podman_unhealthy_output}" >&2
		fi
		podman_starting_output="$(
			cd /
			setpriv --reuid="${user}" --regid="$(id -g "${user}")" --init-groups \
				env HOME="${home}" XDG_RUNTIME_DIR="${runtime_dir}" DBUS_SESSION_BUS_ADDRESS="${bus}" \
				sh -c 'cd /; podman ps --filter health=starting --format "starting {{.Names}} {{.Status}}" 2>/dev/null || true'
		)"
		if [ -n "${podman_starting_output}" ]; then
			had_starting=1
			starting_output="${starting_output}${starting_output:+
}[user ${user}]
${podman_starting_output}"
		fi
	done <<EOF_HC_UNITS
${units}
EOF_HC_UNITS

	if [ "${had_failures}" -eq 1 ]; then
		echo "[health-check] FAILED — service failures detected after deploy" >&2
		return 1
	fi
	if [ "${had_starting}" -eq 1 ]; then
		echo "[health-check] deployment work still settling:" >&2
		echo "${starting_output}" >&2
		return 2
	fi

	echo "[health-check] ok" >&2
}

_remote_health_check_starting_timeout_seconds() {
	local pointer_file="" metadata_file="" timeout="" max_timeout=0 unit_count=0

	for pointer_file in /etc/systemd-user-manager/dispatchers/*.metadata; do
		[ -e "${pointer_file}" ] || continue
		metadata_file="$(tr -d '\n' <"${pointer_file}")"
		[ -r "${metadata_file}" ] || continue
		unit_count="$((unit_count + $(grep -Eo '"timeout(Ready|Stable)Seconds":[[:space:]]*[0-9]+' "${metadata_file}" | wc -l)))"
		while IFS= read -r timeout; do
			case "${timeout}" in
			"" | *[!0-9]*) continue ;;
			esac
			if [ "${timeout}" -gt "${max_timeout}" ]; then
				max_timeout="${timeout}"
			fi
		done < <(grep -Eo '"timeout(Ready|Stable)Seconds":[[:space:]]*[0-9]+' "${metadata_file}" | sed -E 's/.*:[[:space:]]*//')
	done

	if [ "${max_timeout}" -gt 0 ]; then
		if [ "${unit_count}" -gt 1 ]; then
			max_timeout="$((max_timeout + (unit_count - 1) * 30))"
		fi
		printf '%s\n' "${max_timeout}"
		return 0
	fi

	return 1
}

_remote_post_switch_user_health_check() {
	local timeout_seconds="" poll_seconds=5 start_epoch="" now_epoch="" rc=0

	start_epoch="$(date +%s)"

	while :; do
		if _remote_post_switch_user_health_check_once; then
			return 0
		else
			rc="$?"
		fi

		if [ "${rc}" -ne 2 ]; then
			return "${rc}"
		fi

		if [ -z "${timeout_seconds}" ]; then
			if ! timeout_seconds="$(_remote_health_check_starting_timeout_seconds)"; then
				echo "[health-check] FAILED — deployment work is still settling, but no service-owned timeoutReadySeconds metadata was found" >&2
				return 1
			fi
			echo "[health-check] waiting up to ${timeout_seconds}s for deployment work to settle" >&2
		fi

		now_epoch="$(date +%s)"
		if [ $((now_epoch - start_epoch)) -ge "${timeout_seconds}" ]; then
			echo "[health-check] FAILED — deployment work still settling after ${timeout_seconds}s" >&2
			return 1
		fi

		sleep "${poll_seconds}"
	done
}

_remote_health_check_filter_failed_units() {
	awk '!($0 ~ /\[systemd-run\].*podman.*healthcheck run / || $0 ~ /\.podman-wrapped healthcheck run /)'
}

_remote_health_check_ignored_failed_units() {
	awk '($0 ~ /\[systemd-run\].*podman.*healthcheck run / || $0 ~ /\.podman-wrapped healthcheck run /)'
}

_remote_health_check_filter_transitional_units() {
	awk '!($0 ~ /\[systemd-run\].*podman.*healthcheck run / || $0 ~ /\.podman-wrapped healthcheck run /)'
}

_remote_health_check_podman_unhealthy_containers() {
	cd /
	podman ps --filter health=unhealthy --format 'unhealthy {{.Names}} {{.Status}}' 2>/dev/null || true
}

_remote_health_check_podman_starting_containers() {
	cd /
	podman ps --filter health=starting --format 'starting {{.Names}} {{.Status}}' 2>/dev/null || true
}

build_post_switch_health_check_cmd() {
	emit_remote_function_command \
		"_remote_post_switch_user_health_check" \
		_remote_health_check_filter_failed_units \
		_remote_health_check_ignored_failed_units \
		_remote_health_check_filter_transitional_units \
		_remote_health_check_podman_unhealthy_containers \
		_remote_health_check_podman_starting_containers \
		_remote_health_check_starting_timeout_seconds \
		_remote_post_switch_user_health_check_once \
		_remote_post_switch_user_health_check
}

run_prepared_post_switch_health_check() {
	local node="$1" health_check_cmd="$2"

	if ! run_post_switch_health_transport_preparation_with_retry "${node}"; then
		printf '%s\n' "[health-check] unavailable: failed to prepare deploy context" >&2
		return 1
	fi

	retry_transport_command \
		"Health check on ${node}" \
		refresh_prepared_primary_target \
		run_prepared_root_command \
		"${health_check_cmd}"
}

run_post_switch_health_check() {
	local node="$1" log_file="${2:-}" health_check_cmd=""

	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi

	health_check_cmd="$(build_post_switch_health_check_cmd)"
	run_with_prefixed_combined_output \
		health \
		"${node}" \
		"${log_file}" \
		run_prepared_post_switch_health_check \
		"${node}" \
		"${health_check_cmd}"
}

run_post_switch_health_check_job() {
	local node="$1" status_file="$2" log_file="$3" rc=0

	(
		set +e
		rm -f "${status_file}"
		run_post_switch_health_check "${node}" "${log_file}"
		rc="$?"
		write_status_file "${status_file}" "${rc}"
		exit "${rc}"
	)
}

run_post_switch_health_check_phase() {
	local snapshot_dir="$1" rollback_log_dir="$2" rollback_status_dir="$3"
	local health_log_dir="$4" health_status_dir="$5" verify_parallel="$6" verify_parallel_jobs="$7"
	# shellcheck disable=SC2178
	local -n hcp_successful_hosts_ref="$8"
	local node="" phase_rc=0 active_jobs=0 status_file="" log_file="" status=""
	local -a health_check_failed_hosts=() remaining_successful=()

	log_section "Phase: Health Check"
	echo "Scanning.." >&2

	for node in "${hcp_successful_hosts_ref[@]}"; do
		[ -n "${node}" ] || continue
		status_file="$(phase_dir_item_status_file "${health_status_dir}" "${node}")"
		log_file="$(phase_dir_item_log_file "${health_log_dir}" "${node}")"
		if [ "${verify_parallel}" -eq 1 ]; then
			run_post_switch_health_check_job "${node}" "${status_file}" "${log_file}" &
			active_jobs=$((active_jobs + 1))
			wait_for_job_slot active_jobs "${verify_parallel_jobs}" || return "$?"
			continue
		fi
		if run_post_switch_health_check "${node}" "${log_file}"; then
			remaining_successful+=("${node}")
		else
			echo "Health check failed for ${node}" >&2
			health_check_failed_hosts+=("${node}")
		fi
	done

	if [ "${verify_parallel}" -eq 1 ]; then
		drain_job_slots active_jobs || return "$?"
		for node in "${hcp_successful_hosts_ref[@]}"; do
			[ -n "${node}" ] || continue
			status_file="$(phase_dir_item_status_file "${health_status_dir}" "${node}")"
			if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
				echo "Health check failed for ${node}" >&2
				health_check_failed_hosts+=("${node}")
				continue
			fi
			if [ "${status}" = "0" ]; then
				remaining_successful+=("${node}")
			else
				echo "Health check failed for ${node}" >&2
				health_check_failed_hosts+=("${node}")
			fi
		done
	fi

	[ "${#health_check_failed_hosts[@]}" -ne 0 ] || return 0

	phase_rc=1

	for node in "${health_check_failed_hosts[@]}"; do
		append_unique_array_item HEALTH_FAILED_HOSTS "${node}"
	done
	if [ "${ROLLBACK_ON_FAILURE}" -eq 1 ]; then
		rollback_failed_health_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${health_check_failed_hosts[@]}"
	fi

	hcp_successful_hosts_ref=("${remaining_successful[@]}")

	if [ "${ROLLBACK_ON_FAILURE}" -eq 1 ] && [ "${#remaining_successful[@]}" -gt 0 ]; then
		maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${remaining_successful[@]}"
		hcp_successful_hosts_ref=()
	fi

	return "${phase_rc}"
}

build_systemd_user_manager_report_cmd() {
	local since_epoch="$1"
	local invoke_cmd=""

	printf -v invoke_cmd '_remote_systemd_user_manager_report %q' "@${since_epoch}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_systemd_user_manager_unit_is_terminal \
		_remote_systemd_user_manager_journal_line_is_noise \
		_remote_systemd_user_manager_emit_journal_file_lines \
		_remote_systemd_user_manager_emit_new_journal \
		_remote_systemd_user_manager_stream_unit \
		_remote_systemd_user_manager_report
}

_remote_activation_lock_contention_report() {
	local node="$1" activation_unit="$2" since="$3" force_report="$4"
	local journal_unit="" unit_log="" units="" recent=""

	case "${activation_unit}" in
	*.service)
		journal_unit="${activation_unit}"
		;;
	*)
		journal_unit="${activation_unit}.service"
		;;
	esac

	unit_log="$(journalctl -u "${journal_unit}" --since "${since}" --no-pager -o cat 2>/dev/null || true)"
	if [ "${force_report}" -ne 1 ] &&
		! printf '%s\n' "${unit_log}" | grep -Eq 'Could not acquire lock|/run/nixos/switch-to-configuration.lock'; then
		return 0
	fi

	echo "==> ${node}: switch-to-configuration lock contention detected" >&2
	echo "Current nixbot activation units:" >&2
	units="$(systemctl list-units 'nixbot-switch-to-configuration-*.service' 'nixbot-rollback-to-configuration-*.service' --all --no-legend --plain 2>/dev/null || true)"
	if [ -n "${units}" ]; then
		echo "${units}" >&2
	else
		echo "(none)" >&2
	fi

	echo "Recent switch-to-configuration journal:" >&2
	recent="$(
		journalctl --since "${since}" --no-pager -o short-iso 2>/dev/null |
			grep -E 'nixbot-(switch|rollback)-to-configuration|switch-to-configuration|/run/nixos/switch-to-configuration.lock|Could not acquire lock|Acquiring lock|Creating lock file' |
			tail -n 120 || true
	)"
	if [ -n "${recent}" ]; then
		echo "${recent}" >&2
	elif [ -n "${unit_log}" ]; then
		echo "${unit_log}" | tail -n 80 >&2
	else
		echo "(no recent switch-to-configuration journal entries found)" >&2
	fi
}

build_activation_lock_contention_report_cmd() {
	local node="$1" activation_unit="$2" since_epoch="$3" force_report="$4"
	local invoke_cmd=""

	printf -v invoke_cmd '_remote_activation_lock_contention_report %q %q %q %q' \
		"${node}" \
		"${activation_unit}" \
		"@${since_epoch}" \
		"${force_report}"
	emit_remote_function_command \
		"${invoke_cmd}" \
		_remote_activation_lock_contention_report
}

report_activation_lock_contention_if_present() {
	local node="$1" activation_unit="$2" since_epoch="$3" activation_output="${4:-}"
	local report_cmd="" report_output="" force_report=0

	if [ -z "${since_epoch}" ]; then
		return 0
	fi

	if printf '%s\n' "${activation_output}" | grep -Eq 'Could not acquire lock|/run/nixos/switch-to-configuration.lock'; then
		force_report=1
	fi

	report_cmd="$(build_activation_lock_contention_report_cmd "${node}" "${activation_unit}" "${since_epoch}" "${force_report}")"
	if run_supervised_combined_capture report_output run_prepared_root_command "${report_cmd}" &&
		[ -n "${report_output}" ]; then
		printf '%s\n' "${report_output}" >&2
	fi
}

run_deploy_systemd_user_manager_report_command() {
	local node="$1" report_cmd="$2" report_rc=0

	if prepare_deploy_context "${node}"; then
		:
	else
		report_rc="$?"
		echo "systemd-user-manager report unavailable for ${node}: failed to prepare deploy context" >&2
		return "${report_rc}"
	fi

	if run_prepared_root_command "${report_cmd}"; then
		return 0
	else
		report_rc="$?"
	fi

	echo "systemd-user-manager report unavailable for ${node}: remote report collection failed (exit=${report_rc})" >&2
	return "${report_rc}"
}

print_deploy_systemd_user_manager_report() {
	local node="$1" since_epoch="$2" log_file="${3:-}"
	local report_cmd=""

	if [ "${DRY_RUN}" -eq 1 ]; then
		return 0
	fi

	report_cmd="$(build_systemd_user_manager_report_cmd "${since_epoch}")"

	if [ -n "${log_file}" ]; then
		run_with_combined_output \
			run_deploy_systemd_user_manager_report_command \
			"${node}" \
			"${report_cmd}" > >(tee_host_log_filter "${node}" "${log_file}" report >&2)
	elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
		run_with_combined_output \
			run_deploy_systemd_user_manager_report_command \
			"${node}" \
			"${report_cmd}" > >(host_log_filter "${node}" report >&2)
	else
		run_with_combined_output \
			run_deploy_systemd_user_manager_report_command \
			"${node}" \
			"${report_cmd}" >&2
	fi
}

write_status_file() {
	local status_file="$1" rc="$2"

	printf '%s\n' "${rc}" >"${status_file}"
}

read_status_file() {
	local status_file="$1"

	[ -s "${status_file}" ] || return 1
	cat "${status_file}"
}

write_duration_file() {
	local duration_file="$1" seconds="$2"

	printf '%s\n' "${seconds}" >"${duration_file}"
}

read_duration_file() {
	local duration_file="$1"

	[ -s "${duration_file}" ] || return 1
	cat "${duration_file}"
}

elapsed_seconds() {
	local start_epoch="$1" now_epoch=""

	[ -n "${start_epoch}" ] || return 1
	now_epoch="$(date +%s)"
	printf '%s\n' "$((now_epoch - start_epoch))"
}

format_duration() {
	local seconds="${1:-}" hours=0 minutes=0 remainder=0

	[[ "${seconds}" =~ ^[0-9]+$ ]] || return 1
	if [ "${seconds}" -lt 60 ]; then
		printf '%ss' "${seconds}"
		return
	fi
	if [ "${seconds}" -lt 3600 ]; then
		printf '%sm%02ds' "$((seconds / 60))" "$((seconds % 60))"
		return
	fi
	hours=$((seconds / 3600))
	remainder=$((seconds % 3600))
	minutes=$((remainder / 60))
	printf '%sh%02dm%02ds' "${hours}" "${minutes}" "$((remainder % 60))"
}

format_epoch() {
	local epoch="$1"

	date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S %z'
}

log_host_phase_duration() {
	local node="$1" phase="$2" seconds="$3" log_file="${4:-}" label="" line=""

	case "${phase}" in
	build) label="Build" ;;
	deploy) label="Deploy" ;;
	*) label="${phase}" ;;
	esac
	line="${label} duration: $(format_duration "${seconds}")"
	if [ -n "${log_file}" ]; then
		printf '%s\n' "${line}" | tee_host_log_filter "${node}" "${log_file}" "${phase}" >&2
	elif [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
		printf '%s\n' "${line}" | host_log_filter "${node}" "${phase}" >&2
	else
		printf '%s\n' "${line}" >&2
	fi
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

format_ssh_store_uri() {
	local ssh_target="$1" user_prefix="" host_only=""

	if [[ "${ssh_target}" == *@* ]]; then
		user_prefix="${ssh_target%@*}@"
	fi
	host_only="$(ssh_host_from_target "${ssh_target}")"
	if [[ "${host_only}" == *:* ]]; then
		host_only="[${host_only}]"
	fi
	printf 'ssh-ng://%s%s\n' "${user_prefix}" "${host_only}"
}

prepare_role_host_ssh_context() {
	local role_host="$1"
	# shellcheck disable=SC2178,SC2034
	local -n prhsc_ssh_target_out_ref="$2" prhsc_ssh_opts_out_ref="$3" prhsc_nix_sshopts_out_ref="$4"
	local target_info="" user="" host="" port="" key_path="" known_hosts=""
	local bootstrap_key="" bootstrap_user="" bootstrap_port="" bootstrap_key_path=""
	local _age_identity_key="" proxy_jump="" proxy_command="" effective_proxy_chain=""
	local -a bootstrap_ssh_opts=()
	local bootstrap_nix_sshopts=""

	target_info="$(resolve_deploy_target "${role_host}")"
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
		read -r _age_identity_key
		read -r proxy_jump
		read -r proxy_command
	} < <(jq -r '[.user, .target, (.port // "22"), (.keyPath // ""), (.knownHosts // ""), (.bootstrapKey // ""), (.bootstrapUser // ""), (.bootstrapPort // .port // "22"), (.bootstrapKeyPath // ""), (.ageIdentityKey // ""), (.proxyJump // ""), (.proxyCommand // "")] | .[]' <<<"${target_info}")

	if [ -n "${proxy_jump}" ]; then
		effective_proxy_chain="$(resolve_effective_proxy_chain "${proxy_jump}")"
	fi

	build_deploy_ssh_contexts \
		"${role_host}" \
		"${host}" \
		"${port}" \
		"${bootstrap_port}" \
		"${known_hosts}" \
		"${effective_proxy_chain}" \
		"${proxy_command}" \
		"${key_path}" \
		"${bootstrap_key_path}" \
		prhsc_ssh_opts_out_ref \
		prhsc_nix_sshopts_out_ref \
		bootstrap_ssh_opts \
		bootstrap_nix_sshopts || return 1

	# shellcheck disable=SC2034
	prhsc_ssh_target_out_ref="${user}@${host}"
}

prepare_build_host_store_context() {
	local build_host="$1"
	# shellcheck disable=SC2178,SC2034
	local -n pbhsc_store_uri_out_ref="$2" pbhsc_nix_sshopts_out_ref="$3"
	local ssh_target=""
	local -a ssh_opts=()

	prepare_role_host_ssh_context \
		"${build_host}" \
		ssh_target \
		ssh_opts \
		pbhsc_nix_sshopts_out_ref || return 1

	# shellcheck disable=SC2034
	pbhsc_store_uri_out_ref="$(format_ssh_store_uri "${ssh_target}")"
}

prewarm_build_host_control_master() {
	local ssh_target="" nix_sshopts="" control_path=""
	local -a ssh_opts=()

	[ "${BUILD_HOST}" != "local" ] || return 0
	[ "${DRY_RUN}" -eq 0 ] || return 0

	prepare_role_host_ssh_context "${BUILD_HOST}" ssh_target ssh_opts nix_sshopts || return 0
	control_path="$(control_master_socket_path "${BUILD_HOST}" primary)"
	if ssh "${ssh_opts[@]}" -O check "${ssh_target}" >/dev/null 2>&1; then
		return 0
	fi
	rm -f "${control_path}" 2>/dev/null || true
	if ! ssh "${ssh_opts[@]}" -M -N -f "${ssh_target}" >/dev/null 2>&1; then
		rm -f "${control_path}" 2>/dev/null || true
		echo "warning: unable to prewarm SSH control master for ${BUILD_HOST}; continuing without prewarm" >&2
	fi
}

host_build_plan_file() {
	local node="$1"

	[ -n "${NIXBOT_BUILD_PLAN_DIR}" ] || return 1
	printf '%s/%s.drv-path\n' "${NIXBOT_BUILD_PLAN_DIR}" "${node}"
}

resolve_host_build_drv_path() {
	local node="$1" plan_file="" drv_path=""

	plan_file="$(host_build_plan_file "${node}")" || {
		echo "Build plan directory is not initialized" >&2
		return 1
	}
	if [ ! -s "${plan_file}" ]; then
		echo "Build plan missing for ${node}: ${plan_file}" >&2
		return 1
	fi
	drv_path="$(cat "${plan_file}")"
	if [ -z "${drv_path}" ]; then
		echo "Build plan is empty for ${node}: ${plan_file}" >&2
		return 1
	fi
	printf '%s\n' "${drv_path}"
}

build_drv_output_installable() {
	local drv_path="$1"

	printf '%s^out\n' "${drv_path}"
}

host_build_plan_status_file() {
	local node="$1"

	[ -n "${NIXBOT_BUILD_PLAN_DIR}" ] || return 1
	printf '%s/%s.rc\n' "${NIXBOT_BUILD_PLAN_DIR}" "${node}"
}

host_build_plan_cache_root() {
	local cache_home=""

	if [ -n "${NIXBOT_BUILD_PLAN_CACHE_DIR:-}" ]; then
		printf '%s\n' "${NIXBOT_BUILD_PLAN_CACHE_DIR}"
		return 0
	fi
	cache_home="${XDG_CACHE_HOME:-}"
	if [ -z "${cache_home}" ]; then
		[ -n "${HOME:-}" ] || return 1
		cache_home="${HOME}/.cache"
	fi
	printf '%s/nixbot/build-plans/v1\n' "${cache_home}"
}

build_plan_cache_enabled() {
	parse_bool_env "${BUILD_PLAN_CACHE_ENABLED}"
}

build_plan_cache_context_key() {
	local head="" index_tree="" nix_version="" key_input=""

	if [ "${NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY}" = "__disabled__" ]; then
		return 1
	fi
	if [ -n "${NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY}" ]; then
		printf '%s\n' "${NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY}"
		return 0
	fi
	build_plan_cache_enabled || return 1
	git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
	git update-index --refresh >/dev/null 2>&1 || return 1
	[ -z "$(git diff --name-only --diff-filter=U)" ] || return 1
	if ! git diff --quiet; then
		return 1
	fi

	head="$(git rev-parse HEAD)" || return 1
	index_tree="$(git write-tree)" || return 1
	nix_version="$(nix --version)"
	key_input="$(
		printf 'schema=build-plan-v1\n'
		printf 'nix=%s\n' "${nix_version}"
		printf 'head=%s\n' "${head}"
		printf 'indexTree=%s\n' "${index_tree}"
	)"
	NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY="$(printf '%s' "${key_input}" | sha256sum | awk '{print $1}')"
	printf '%s\n' "${NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY}"
}

prepare_build_plan_cache_context() {
	if ! build_plan_cache_context_key >/dev/null; then
		NIXBOT_BUILD_PLAN_CACHE_CONTEXT_KEY="__disabled__"
	fi
}

host_build_plan_cache_file() {
	local node="$1" cache_root="" context_key="" safe_node=""

	cache_root="$(host_build_plan_cache_root)" || return 1
	context_key="$(build_plan_cache_context_key)" || return 1
	safe_node="$(tr -c 'a-zA-Z0-9._-' '_' <<<"${node}")"
	printf '%s/%s/%s.drv-path\n' "${cache_root}" "${context_key}" "${safe_node}"
}

read_cached_host_build_plan() {
	local node="$1" cache_file="" drv_path=""

	cache_file="$(host_build_plan_cache_file "${node}")" || return 1
	[ -s "${cache_file}" ] || return 1
	drv_path="$(<"${cache_file}")"
	case "${drv_path}" in
	/nix/store/*.drv) ;;
	*) return 1 ;;
	esac
	[ -e "${drv_path}" ] || return 1
	printf '%s\n' "${drv_path}"
}

write_cached_host_build_plan() {
	local node="$1" drv_path="$2" cache_file="" cache_tmp=""

	cache_file="$(host_build_plan_cache_file "${node}")" || return 0
	mkdir -p "$(dirname "${cache_file}")"
	cache_tmp="${cache_file}.$$"
	printf '%s\n' "${drv_path}" >"${cache_tmp}"
	mv -f "${cache_tmp}" "${cache_file}"
}

validate_build_plan_drv_path() {
	local node="$1" drv_path="$2"

	case "${drv_path}" in
	/nix/store/*.drv) ;;
	*)
		echo "Build plan for ${node} did not evaluate to a derivation path: ${drv_path}" >&2
		return 1
		;;
	esac
}

eval_host_build_plan_drv_path() {
	local node="$1" drv_path="" rc=0

	if ! run_supervised_stdout_capture drv_path "" \
		nix eval "${NIXBOT_BUILD_PLAN_NIX_ARGS[@]}" --raw --no-write-lock-file ".#${NIXBOT_BUILD_PLAN_ATTR_BASE}.${node}.${NIXBOT_BUILD_PLAN_ATTR_SUFFIX}"; then
		rc="$?"
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		echo "Build plan evaluation failed for ${node}" >&2
		return 1
	fi
	validate_build_plan_drv_path "${node}" "${drv_path}" || return 1
	printf '%s\n' "${drv_path}"
}

select_build_plan_attr_base() {
	# shellcheck disable=SC2034
	local plans_json=""

	if run_supervised_stdout_capture plans_json "" \
		nix eval "${NIXBOT_BUILD_PLAN_NIX_ARGS[@]}" --json --no-write-lock-file .#nixbot.plans --apply builtins.attrNames; then
		NIXBOT_BUILD_PLAN_ATTR_BASE="nixbot.plans"
		NIXBOT_BUILD_PLAN_ATTR_SUFFIX="drvPath"
		return 0
	fi

	NIXBOT_BUILD_PLAN_ATTR_BASE="nixosConfigurations"
	NIXBOT_BUILD_PLAN_ATTR_SUFFIX="config.system.build.toplevel.drvPath"
	echo "nixbot: flake out nixbot.plans unavailable; using fallback" >&2
}

resolve_host_build_plan_drv_path() {
	local node="$1" drv_path=""

	if drv_path="$(read_cached_host_build_plan "${node}")"; then
		echo "Build plan cache hit for ${node}" >&2
		printf '%s\n' "${drv_path}"
		return 0
	fi

	echo "Run: nix eval" >&2
	drv_path="$(eval_host_build_plan_drv_path "${node}")" || return "$?"
	write_cached_host_build_plan "${node}" "${drv_path}"
	printf '%s\n' "${drv_path}"
}

run_build_plan_job() {
	local node="$1" plan_file="$2" status_file="$3"
	local drv_path="" rc=0

	(
		set +e
		if [ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ]; then
			drv_path="$(resolve_host_build_plan_drv_path "${node}" 2> >(host_log_filter "${node}" build >&2))"
		else
			drv_path="$(resolve_host_build_plan_drv_path "${node}")"
		fi
		rc="$?"
		if [ "${rc}" = "0" ]; then
			printf '%s\n' "${drv_path}" >"${plan_file}"
		fi
		write_status_file "${status_file}" "${rc}"
		exit "${rc}"
	)
}

prepare_build_plan() {
	local node="" plan_file="" status_file="" status="" build_plan_jobs="$#" active_jobs=0 phase_rc=0
	local build_plan_start_epoch="" duration_secs=""

	[ "$#" -gt 0 ] || return 0
	if [ "${BUILD_PLAN_JOBS}" -lt "${build_plan_jobs}" ]; then
		build_plan_jobs="${BUILD_PLAN_JOBS}"
	fi
	if [ "${build_plan_jobs}" -gt 1 ]; then
		NIXBOT_BUILD_PLAN_NIX_ARGS=(--option eval-cache false)
	else
		NIXBOT_BUILD_PLAN_NIX_ARGS=()
	fi

	NIXBOT_BUILD_PLAN_DIR="$(tmp_runtime_dir_path build-plans)"
	mkdir -p "${NIXBOT_BUILD_PLAN_DIR}"

	log_section "Phase: Build Plan"
	build_plan_start_epoch="$(date +%s)"
	select_build_plan_attr_base
	prepare_build_plan_cache_context
	echo "Evaluating build plan for selected hosts (${build_plan_jobs} job(s)).." >&2
	for node in "$@"; do
		[ -n "${node}" ] || continue
		plan_file="$(host_build_plan_file "${node}")" || return 1
		status_file="$(host_build_plan_status_file "${node}")" || return 1
		if [ "${build_plan_jobs}" -gt 1 ]; then
			run_build_plan_job "${node}" "${plan_file}" "${status_file}" &
			active_jobs=$((active_jobs + 1))
			if ! wait_for_job_slot active_jobs "${build_plan_jobs}"; then
				phase_rc="$?"
				return "${phase_rc}"
			fi
			continue
		fi

		run_build_plan_job "${node}" "${plan_file}" "${status_file}"
		if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
			echo "Build plan failed for ${node}: no status recorded" >&2
			return 1
		fi
		if [ "${status}" != "0" ]; then
			echo "Build plan failed for ${node}" >&2
			if is_signal_exit_status "${status}"; then
				return "${status}"
			fi
			return 1
		fi
	done

	if [ "${build_plan_jobs}" -gt 1 ]; then
		if ! drain_job_slots active_jobs; then
			phase_rc="$?"
			return "${phase_rc}"
		fi
	fi

	for node in "$@"; do
		status_file="$(host_build_plan_status_file "${node}")" || return 1
		if ! status="$(read_status_file "${status_file}" 2>/dev/null)"; then
			echo "Build plan failed for ${node}: no status recorded" >&2
			return 1
		fi
		if [ "${status}" != "0" ]; then
			echo "Build plan failed for ${node}" >&2
			if is_signal_exit_status "${status}"; then
				return "${status}"
			fi
			return 1
		fi
		plan_file="$(host_build_plan_file "${node}")" || return 1
		if [ ! -s "${plan_file}" ]; then
			echo "Build plan did not include ${node}" >&2
			return 1
		fi
	done
	duration_secs="$(elapsed_seconds "${build_plan_start_epoch}")"
	echo "Build plan duration: $(format_duration "${duration_secs}")" >&2
}

copy_build_drv_to_remote_store() {
	local drv_path="$1" store_uri="$2" nix_sshopts="$3" copy_output=""
	local -a copy_cmd=()

	copy_cmd=(nix copy --to "${store_uri}" "${drv_path}")
	echo "Copying planned derivation to ${BUILD_HOST}: ${drv_path}" >&2
	run_remote_store_command_with_retry \
		copy_output \
		"Build derivation copy to ${BUILD_HOST}" \
		"${nix_sshopts}" \
		"${copy_cmd[@]}" || return "$?"
	: "${copy_output}"
}

run_nix_with_optional_sshopts() {
	local nix_sshopts="$1"
	shift

	if [ -n "${nix_sshopts}" ]; then
		env NIX_SSHOPTS="${nix_sshopts}" "$@"
	else
		"$@"
	fi
}

build_host() {
	local node="$1" result_link="${2:-}" drv_path="" build_installable="" out_path=""
	local rc=0
	local -a build_cmd=()

	log_host_stage "build" "${node}"
	echo "Starting local build" >&2
	drv_path="$(resolve_host_build_drv_path "${node}")" || return 1
	build_installable="$(build_drv_output_installable "${drv_path}")"
	build_cmd=(nix build "${NIXBOT_BUILD_NIX_ARGS[@]}" --print-out-paths)
	if [ "${BUILD_LOGS}" -eq 1 ]; then
		build_cmd+=(-L)
	fi
	if [ -n "${result_link}" ]; then
		build_cmd+=(-o "${result_link}")
	fi
	build_cmd+=("${build_installable}")
	if ! run_supervised_stdout_capture out_path "" "${build_cmd[@]}"; then
		rc="$?"
		echo "Build failed for ${node}" >&2
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		return 1
	fi

	[ -n "${out_path}" ] || {
		echo "Build produced no output path for ${node}" >&2
		return 1
	}

	echo "Built out path: ${out_path}" >&2
	if [ -n "${result_link}" ]; then
		echo "Result link: ${result_link}" >&2
	fi
	if ! nix path-info --closure-size --human-readable "${out_path}" >&2; then
		echo "Unable to resolve closure size for ${node}: ${out_path}" >&2
		return 1
	fi

	printf '%s\n' "${out_path}"
}

remote_build_host() {
	local node="$1" result_link="${2:-}" drv_path="" build_installable="" out_path="" store_uri="" nix_sshopts=""
	local rc=0
	local -a build_cmd=()

	log_host_stage "build" "${node}" "remote build"
	echo "Starting remote build on ${BUILD_HOST}" >&2
	drv_path="$(resolve_host_build_drv_path "${node}")" || return 1
	build_installable="$(build_drv_output_installable "${drv_path}")"
	prepare_build_host_store_context "${BUILD_HOST}" store_uri nix_sshopts || return 1
	copy_build_drv_to_remote_store "${drv_path}" "${store_uri}" "${nix_sshopts}" || return 1

	build_cmd=(nix build "${NIXBOT_BUILD_NIX_ARGS[@]}" --eval-store auto --store "${store_uri}" --print-out-paths --no-link)
	if [ "${BUILD_LOGS}" -eq 1 ]; then
		build_cmd+=(-L)
	fi
	build_cmd+=("${build_installable}")
	if ! run_remote_store_command_with_retry \
		out_path \
		"Remote build on ${BUILD_HOST}" \
		"${nix_sshopts}" \
		"${build_cmd[@]}"; then
		rc="$?"
		echo "Remote build failed for ${node} on ${BUILD_HOST}" >&2
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		return 1
	fi

	[ -n "${out_path}" ] || {
		echo "Remote build produced no output path for ${node}" >&2
		return 1
	}

	echo "Built out path on ${BUILD_HOST}: ${out_path}" >&2
	if is_deploy_style_action; then
		require_remote_build_cache_for_deploy || return 1
	else
		copy_remote_build_closure_to_local_store "${node}" "${store_uri}" "${nix_sshopts}" "${out_path}" || return 1
		if [ -n "${result_link}" ]; then
			ln -sfn "${out_path}" "${result_link}"
			echo "Result link: ${result_link}" >&2
		fi
	fi

	printf '%s\n' "${out_path}"
}

dev_build_host() {
	local node="$1" drv_path="" build_installable="" out_path="" result_link=""
	local rc=0
	local -a build_cmd=()

	result_link="result-dev/${node}"

	log_host_stage "build" "${node}" "dev build"
	echo "Starting dev build: ${result_link}" >&2
	drv_path="$(resolve_host_build_drv_path "${node}")" || return 1
	build_installable="$(build_drv_output_installable "${drv_path}")"
	mkdir -p "$(dirname "${result_link}")"
	build_cmd=(nix build "${NIXBOT_BUILD_NIX_ARGS[@]}" --print-out-paths -o "${result_link}")
	if [ "${BUILD_LOGS}" -eq 1 ]; then
		build_cmd+=(-L)
	fi
	build_cmd+=("${build_installable}")
	if ! run_supervised_stdout_capture out_path "" "${build_cmd[@]}"; then
		rc="$?"
		echo "Dev build failed for ${node}" >&2
		if is_signal_exit_status "${rc}"; then
			return "${rc}"
		fi
		return 1
	fi

	[ -n "${out_path}" ] || {
		echo "Dev build produced no output path for ${node}" >&2
		return 1
	}

	echo "Built out path: ${out_path}" >&2
	echo "Result link: ${result_link}" >&2
	if ! nix path-info --closure-size --human-readable "${out_path}" >&2; then
		echo "Unable to resolve closure size for ${node}: ${out_path}" >&2
		return 1
	fi

	printf '%s\n' "${out_path}"
}

resolve_build_out_path() {
	local node="$1" result_link="${2:-}"

	if [ "${ACTION}" = "dev-build" ]; then
		dev_build_host "${node}"
	elif [ "${BUILD_HOST}" != "local" ]; then
		remote_build_host "${node}" "${result_link}"
	else
		build_host "${node}" "${result_link}"
	fi
}

run_build_phase() {
	local build_jobs="$1" build_parallel="$2" prioritize_ci="$3" ci_host="$4"
	local build_log_dir="$5" build_status_dir="$6" build_out_dir="$7" built_hosts_out_name="$9"
	local -n rbp_build_hosts_in_ref="$8"
	# shellcheck disable=SC2178
	local -n rbp_failed_hosts_out_ref="${10}"

	local node="" active_jobs=0 status_file="" out_file="" log_file=""
	local build_sync_leading_ci=0 host_grouping=0 phase_rc=0

	if [ "${build_parallel}" -eq 0 ] && [ "${#rbp_build_hosts_in_ref[@]}" -gt 1 ]; then
		host_grouping=1
		log_grouped_phase_section "Phase: Build" "build" 1
	else
		log_grouped_phase_section "Phase: Build" "build" 0
	fi
	if [ "${build_parallel}" -eq 1 ]; then
		prewarm_build_host_control_master
	fi

	if [ "${build_parallel}" -eq 1 ] && [ "${prioritize_ci}" -eq 1 ] &&
		[ "${#rbp_build_hosts_in_ref[@]}" -gt 0 ] && [ "${rbp_build_hosts_in_ref[0]}" = "${ci_host}" ]; then
		build_sync_leading_ci=1
		node="${ci_host}"
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
		if [ "${build_sync_leading_ci}" -eq 1 ] && [ "${node}" = "${ci_host}" ]; then
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
			if [ "${build_sync_leading_ci}" -eq 1 ] && [ "${node}" = "${ci_host}" ]; then
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
	local deploy_parallel="$1" deploy_parallel_jobs="$2"
	local verify_parallel="$3" verify_parallel_jobs="$4" snapshot_dir="$5"
	local snapshot_log_dir="$6" snapshot_status_dir="$7"
	local deploy_log_dir="$8" deploy_status_dir="$9" build_out_dir="${10}"
	local rollback_log_dir="${11}" rollback_status_dir="${12}"
	local deploy_skipped_hosts_out_name="${15}" snapshot_failed_hosts_out_name="${16}"
	local -n rdp_level_groups_in_ref="${13}" rdp_successful_hosts_out_ref="${14}"
	# shellcheck disable=SC2178
	local -n rdp_deploy_failed_hosts_out_ref="${17}"

	local level_group="" node="" active_jobs="" level_index=0 failed_node="" deploy_job_pid=""
	local -a level_hosts=() deploy_level_hosts=() deploy_started_hosts=() completed_deploy_hosts=()
	local status_file="" out_file="" log_file="" snapshot_retry_logged=0
	local deploy_wave_failed=0 total_deploy_hosts=0 level_group_size=0 host_grouping=0 phase_rc=0

	local _success_hosts_out_name="${14}" _failed_hosts_out_name="${17}"

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
			"${verify_parallel}" \
			"${verify_parallel_jobs}" \
			"${deploy_level_hosts[@]}"; then
			if ! process_snapshot_wave_results "${snapshot_dir}" "${snapshot_failed_hosts_out_name}" "${_failed_hosts_out_name}" "${deploy_skipped_hosts_out_name}" "${deploy_level_hosts[@]}"; then
				print_host_failures "Deploy phase failed" snapshot "" "${rdp_deploy_failed_hosts_out_ref[@]}"
				maybe_rollback_successful_hosts "${snapshot_dir}" "${rollback_log_dir}" "${rollback_status_dir}" "${rdp_successful_hosts_out_ref[@]}"
				log_group_scope_end
				return 1
			fi
		fi
		mark_snapshot_matched_deploy_skips \
			"${snapshot_dir}" \
			"${build_out_dir}" \
			"${deploy_status_dir}" \
			"${deploy_skipped_hosts_out_name}" \
			"${deploy_level_hosts[@]}"
		if [ "${snapshot_retry_logged}" -eq 1 ]; then
			log_grouped_phase_section "Phase: Deploy" "deploy" "${host_grouping}"
		fi

		completed_deploy_hosts=()
		for node in "${deploy_level_hosts[@]}"; do
			[ -n "${node}" ] || continue
			if array_contains "${node}" "${OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS[@]}"; then
				continue
			fi
			if snapshot_deploy_skip_marked "${snapshot_dir}" "${node}"; then
				continue
			fi
			completed_deploy_hosts+=("${node}")
		done
		if [ "${#completed_deploy_hosts[@]}" -eq 0 ]; then
			echo "Skipping: No changed hosts" >&2
			level_index=$((level_index + 1))
			continue
		fi

		log_subsection "Deploy Wave: $(join_by_comma "${completed_deploy_hosts[@]}")"
		deploy_wave_failed=0
		deploy_started_hosts=()
		failed_node=""
		active_jobs=0

		for node in "${completed_deploy_hosts[@]}"; do
			[ -n "${node}" ] || continue

			status_file="$(phase_dir_item_status_file "${deploy_status_dir}" "${node}")"
			out_file="${build_out_dir}/${node}.path"
			log_file=""
			if [ "${deploy_parallel}" -eq 1 ]; then
				log_file="$(phase_dir_item_log_file "${deploy_log_dir}" "${node}")"
				mark_deploy_job_started
				run_deploy_job "${node}" "${out_file}" "${status_file}" "${log_file}" &
				deploy_job_pid="$!"
				register_deploy_job_pid "${node}" "${deploy_job_pid}"
				deploy_started_hosts+=("${node}")
				active_jobs=$((active_jobs + 1))
				if wait_for_job_slot active_jobs "${deploy_parallel_jobs}"; then
					:
				else
					phase_rc="$?"
					_try_abort_wave "${phase_rc}"
					phase_rc="$?"
					log_group_scope_end
					return "${phase_rc}"
				fi
				if failed_node="$(find_completed_required_deploy_failure "${deploy_status_dir}" "${deploy_started_hosts[@]}")"; then
					terminate_pre_activation_deploy_jobs "${failed_node}"
					deploy_wave_failed=1
					break
				fi
				continue
			fi

			mark_deploy_job_started
			run_deploy_job "${node}" "${out_file}" "${status_file}" &
			deploy_job_pid="$!"
			register_deploy_job_pid "${node}" "${deploy_job_pid}"
			deploy_started_hosts+=("${node}")
			active_jobs=1
			if drain_job_slots active_jobs; then
				:
			else
				phase_rc="$?"
				_try_abort_wave "${phase_rc}"
				phase_rc="$?"
				log_group_scope_end
				return "${phase_rc}"
			fi
			if process_completed_deploy_wave_jobs \
				"${deploy_status_dir}" \
				"${snapshot_dir}" \
				"${rollback_log_dir}" \
				"${rollback_status_dir}" \
				"${_success_hosts_out_name}" \
				"${deploy_skipped_hosts_out_name}" \
				"${_failed_hosts_out_name}" \
				"${node}"; then
				:
			else
				phase_rc="$?"
				_try_abort_wave "${phase_rc}"
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
			if drain_deploy_wave_job_slots active_jobs "${deploy_status_dir}" deploy_started_hosts failed_node; then
				:
			else
				phase_rc="$?"
				_try_abort_wave "${phase_rc}"
				phase_rc="$?"
				log_group_scope_end
				return "${phase_rc}"
			fi
			if [ -n "${failed_node}" ]; then
				deploy_wave_failed=1
			fi
			completed_deploy_hosts=()
			for node in "${deploy_started_hosts[@]}"; do
				[ -n "${node}" ] || continue
				if array_contains "${node}" "${OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS[@]}"; then
					continue
				fi
				if [ -e "$(deploy_pre_activation_cancel_marker_file "${node}")" ]; then
					continue
				fi
				completed_deploy_hosts+=("${node}")
			done
			if process_completed_deploy_wave_jobs \
				"${deploy_status_dir}" \
				"${snapshot_dir}" \
				"${rollback_log_dir}" \
				"${rollback_status_dir}" \
				"${_success_hosts_out_name}" \
				"${deploy_skipped_hosts_out_name}" \
				"${_failed_hosts_out_name}" \
				"${completed_deploy_hosts[@]}"; then
				:
			else
				phase_rc="$?"
				_try_abort_wave "${phase_rc}"
				phase_rc="$?"
				if is_signal_exit_status "${phase_rc}"; then
					log_group_scope_end
					return "${phase_rc}"
				fi
			fi
			if [ "${#rdp_deploy_failed_hosts_out_ref[@]}" -gt 0 ]; then
				deploy_wave_failed=1
			fi
		fi

		if [ "${deploy_wave_failed}" -eq 1 ]; then
			if [ "${deploy_parallel}" -eq 1 ]; then
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
		ROLLBACK_FAILED_HOSTS \
		DEPLOY_FAILED_ROLLBACK_OK_HOSTS \
		DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS \
		HEALTH_FAILED_HOSTS \
		HEALTH_FAILED_ROLLBACK_OK_HOSTS \
		HEALTH_FAILED_ROLLBACK_FAILED_HOSTS
}

run_hosts() {
	local selected_json="$1" runnable_selected_json="" ci_host="${CI_TRIGGER_HOST}"
	# shellcheck disable=SC2034
	local -a selected_hosts=() failed_hosts=() successful_hosts=() built_hosts=()
	# shellcheck disable=SC2034
	local -a snapshot_failed_hosts=() deploy_skipped_hosts=() deploy_failed_hosts=()
	# shellcheck disable=SC2034
	local -a build_hosts=() level_groups=() bootstrap_ok_hosts=() bootstrap_failed_hosts=()

	local build_log_dir="" build_status_dir="" snapshot_log_dir="" snapshot_status_dir=""
	local deploy_log_dir="" deploy_status_dir="" build_out_dir="" snapshot_dir=""
	local rollback_log_dir="" rollback_status_dir="" health_log_dir="" health_status_dir=""
	local levels_json="" final_rc=0 build_parallel=0 deploy_parallel=0 verify_parallel=0
	local build_phase_start_epoch="" deploy_phase_start_epoch=""

	FULLY_SKIPPED_HOSTS=()
	# shellcheck disable=SC2034
	OPTIONAL_DEPLOY_SNAPSHOT_SKIPPED_HOSTS=()
	# shellcheck disable=SC2034
	OPTIONAL_DEPLOY_ROLLBACK_OK_HOSTS=()
	# shellcheck disable=SC2034
	OPTIONAL_DEPLOY_ROLLBACK_FAILED_HOSTS=()
	# shellcheck disable=SC2034
	DEPLOY_FAILED_ROLLBACK_OK_HOSTS=()
	# shellcheck disable=SC2034
	DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS=()
	# shellcheck disable=SC2034
	HEALTH_FAILED_HOSTS=()
	# shellcheck disable=SC2034
	HEALTH_FAILED_ROLLBACK_OK_HOSTS=()
	# shellcheck disable=SC2034
	HEALTH_FAILED_ROLLBACK_FAILED_HOSTS=()
	runnable_selected_json="$(filter_runnable_hosts_json "${selected_json}")"
	json_array_to_bash_array "${runnable_selected_json}" selected_hosts

	if is_clear_remote_locks_action; then
		run_clear_remote_locks_action "${runnable_selected_json}"
		return
	fi

	if is_bootstrap_check_action; then
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

	levels_json="$(selected_host_levels_json "${runnable_selected_json}")"
	mapfile -t level_groups < <(jq -c '.[]' <<<"${levels_json}")
	# shellcheck disable=SC2034
	json_array_to_bash_array "${runnable_selected_json}" build_hosts
	if [ "${BUILD_JOBS}" -gt 1 ]; then
		build_parallel=1
		NIXBOT_BUILD_NIX_ARGS=(--option eval-cache false)
	fi
	if [ "${NIXBOT_PARALLEL_JOBS}" -gt 1 ]; then
		deploy_parallel=1
	fi
	if [ "${NIXBOT_VERIFY_JOBS}" -gt 1 ]; then
		verify_parallel=1
	fi

	ensure_tmp_dir
	keep_diag_on_failure
	init_run_dirs \
		"${NIXBOT_DIAG_DIR}" \
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
		rollback_status_dir \
		health_log_dir \
		health_status_dir
	RUN_SUMMARY_BUILD_STATUS_DIR="${build_status_dir}"
	RUN_SUMMARY_DEPLOY_STATUS_DIR="${deploy_status_dir}"

	build_phase_start_epoch="$(date +%s)"
	if ! prepare_build_plan "${build_hosts[@]}"; then
		final_rc=1
		for node in "${build_hosts[@]}"; do
			failed_hosts+=("${node}")
			write_status_file "$(phase_dir_item_status_file "${build_status_dir}" "${node}")" 1
		done
		RUN_SUMMARY_BUILD_DURATION_SECS="$(elapsed_seconds "${build_phase_start_epoch}")"
		echo "Build phase duration: $(format_duration "${RUN_SUMMARY_BUILD_DURATION_SECS}")" >&2
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

	if run_build_phase \
		"${BUILD_JOBS}" \
		"${build_parallel}" \
		"${PRIORITIZE_CI_FIRST}" \
		"${ci_host}" \
		"${build_log_dir}" \
		"${build_status_dir}" \
		"${build_out_dir}" \
		build_hosts \
		built_hosts \
		failed_hosts; then
		:
	else
		final_rc="$?"
		if is_signal_exit_status "${final_rc}"; then
			RUN_SUMMARY_BUILD_DURATION_SECS="$(elapsed_seconds "${build_phase_start_epoch}")"
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
	fi
	RUN_SUMMARY_BUILD_DURATION_SECS="$(elapsed_seconds "${build_phase_start_epoch}")"
	echo "Build phase duration: $(format_duration "${RUN_SUMMARY_BUILD_DURATION_SECS}")" >&2

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
				"${verify_parallel}" \
				"${NIXBOT_VERIFY_JOBS}"
		fi
	fi

	failed_hosts=()
	successful_hosts=()

	deploy_phase_start_epoch="$(date +%s)"
	if run_deploy_phase \
		"${deploy_parallel}" \
		"${NIXBOT_PARALLEL_JOBS}" \
		"${verify_parallel}" \
		"${NIXBOT_VERIFY_JOBS}" \
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
		:
	else
		final_rc="$?"
		if is_signal_exit_status "${final_rc}"; then
			RUN_SUMMARY_DEPLOY_DURATION_SECS="$(elapsed_seconds "${deploy_phase_start_epoch}")"
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
	fi
	RUN_SUMMARY_DEPLOY_DURATION_SECS="$(elapsed_seconds "${deploy_phase_start_epoch}")"

	# Health check phase: verify user services are healthy after deploy.
	if [ "${DRY_RUN}" -eq 0 ] && [ "${#successful_hosts[@]}" -gt 0 ]; then
		if [ "${VERIFY_AFTER_DEPLOY}" -eq 0 ]; then
			log_section "Phase: Health Check"
			echo "Skipping post-deploy health checks (--no-verify)" >&2
		elif run_post_switch_health_check_phase \
			"${snapshot_dir}" \
			"${rollback_log_dir}" \
			"${rollback_status_dir}" \
			"${health_log_dir}" \
			"${health_status_dir}" \
			0 \
			1 \
			successful_hosts; then
			:
		else
			final_rc="$?"
			if is_signal_exit_status "${final_rc}"; then
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
		fi
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
	"tf/${project_name}" | "tf/${project_name}/"*) return 0 ;;
	"tf/modules/${provider_name}" | "tf/modules/${provider_name}/"*) return 0 ;;
	"data/secrets/globals/${provider_name}" | "data/secrets/globals/${provider_name}/"*) return 0 ;;
	"data/secrets/globals/tf/${provider_name}.tfvars.age") return 0 ;;
	"data/secrets/globals/tf/${provider_name}" | "data/secrets/globals/tf/${provider_name}/"*) return 0 ;;
	"data/secrets/globals/tf/${project_name}.tfvars.age") return 0 ;;
	"data/secrets/globals/tf/${project_name}" | "data/secrets/globals/tf/${project_name}/"*) return 0 ;;
	"data/secrets/globals/cloudflare/r2-account-id.key.age" | "data/secrets/globals/cloudflare/r2-state-bucket.key.age" | "data/secrets/globals/cloudflare/r2-access-key-id.key.age" | "data/secrets/globals/cloudflare/r2-secret-access-key.key.age") return 0 ;;
	esac

	if [ "${phase}" = "apps" ]; then
		case "${path}" in
		services | services/*) return 0 ;;
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
	[ -f "${project_pkg_dir}/default.nix" ] || return 1

	printf '%s\n' "${project_pkg_dir}"
}

prepare_tf_apps_project_runtime() {
	local project_name="$1" project_pkg_dir=""

	if ! project_pkg_dir="$(tf_project_apps_package_dir "${project_name}")"; then
		return 0
	fi

	echo "Preparing Terraform apps package build: ${project_name}" >&2
	nix build --file "${project_pkg_dir}/default.nix" --no-link
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

tf_project_requires_secret_tfvars() {
	local project_name="$1" project_dir=""

	project_dir="tf/${project_name}"
	[ -d "${project_dir}" ] || return 1

	grep -R -E -q \
		--include='*.tfvars' \
		'config_secret_refs|secret_[a-zA-Z0-9_]*refs?' \
		"${project_dir}"
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
	done <<<"${diff_output}"

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
	done <<<"${status_output}"

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

	for ((i = 0; i < ${#args[@]}; i++)); do
		arg="${args[$i]}"
		case "${arg}" in
		-chdir)
			i=$((i + 1))
			;;
		-chdir=* | -help | --help | -version | --version) ;;
		-*) ;;
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
		-var | -var=* | -var-file | -var-file=*)
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
		-backend-config | -backend-config=*)
			return 0
			;;
		esac
	done

	return 1
}

tofu_subcommand_supports_var_files() {
	local subcommand="${1:-}"

	case "${subcommand}" in
	plan | apply | destroy | import | console)
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
	local -a cmd=() tf_var_files=() pre_sub=() post_sub=()
	local found_sub=0 i="" arg=""

	if [ -n "${project_name}" ] && subcommand="$(resolve_tofu_auto_var_file_subcommand "$@")"; then
		materialize_tf_var_files_for_project "${project_name}" tf_var_files discovered_tf_var_files 1

		if [ "${discovered_tf_var_files}" -eq 0 ]; then
			echo "Sensitive tfvars: no *.tfvars.age files found under ${TF_SECRETS_DIR}" >&2
			if tf_project_requires_secret_tfvars "${project_name}"; then
				case "${subcommand}" in
				plan | apply | destroy)
					die "Refusing Terraform ${subcommand} for ${project_name}: no encrypted tfvars were discovered"
					;;
				esac
			fi
		fi

		# Insert var-file flags right after the subcommand so they precede any
		# positional args (tofu's Go flag parser stops at the first non-flag arg).
		for arg in "$@"; do
			if [ "${found_sub}" -eq 0 ] && [ "${arg}" = "${subcommand}" ]; then
				pre_sub+=("${arg}")
				found_sub=1
			elif [ "${found_sub}" -eq 0 ]; then
				pre_sub+=("${arg}")
			else
				post_sub+=("${arg}")
			fi
		done
		cmd=(tofu "${pre_sub[@]}")
		append_tf_var_files_to_cmd cmd "${tf_var_files[@]}"
		cmd+=("${post_sub[@]}")

		if [ "${#tf_var_files[@]}" -gt 0 ]; then
			echo "Terraform ${project_name}: appended ${#tf_var_files[@]} decrypted var-file(s) for ${subcommand}" >&2
		fi
	else
		cmd=(tofu "$@")
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
	keep_diag_on_failure
	log_file="$(phase_item_log_file "${NIXBOT_DIAG_DIR}" "tf" "${phase}" "${project_name}")"
	status_file="$(phase_item_status_file "${NIXBOT_DIAG_DIR}" "tf" "${phase}" "${project_name}")"
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

	for ((i = 0; i < ${#args[@]}; i++)); do
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
	[ -z "${SSH_ORIGINAL_COMMAND:-}" ] || die "The nixbot tofu wrapper is local-only and cannot run via SSH forced-command/ci trigger."

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
		append_tf_backend_config_args_for_project cmd "${project_name}" "${provider_name}" ||
			die "Unsupported Terraform backend for wrapper init: ${project_name}"
		run_with_combined_output "${cmd[@]}"
		return
	fi

	_exec_tofu_cmd "${project_name}" "${tofu_args[@]}"
}

run_requested_tf_phase() {
	local phase="$1" project_dir="" found=0 project_name="" project_rc=0 phase_project_dirs=""

	log_section "Phase: Terraform (${phase})"

	if ! phase_project_dirs="$(tf_project_dirs_for_phase "${phase}")"; then
		return 1
	fi

	if [ -n "${phase_project_dirs}" ]; then
		while IFS= read -r project_dir; do
			[ -n "${project_dir}" ] || continue
			found=1
			project_name="$(tf_project_name_from_dir "${project_dir}")"
			project_rc=0

			run_requested_tf_project_by_name "${phase}" "${project_name}" "${project_dir}" || project_rc=1

			if [ "${project_rc}" -ne 0 ]; then
				return 1
			fi
		done <<<"${phase_project_dirs}"
	fi

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
	"Phase: Build" | "Phase: Snapshot" | "Phase: Deploy" | "Phase: Health Check" | "Phase: Rollback" | "Phase: Bootstrap Key Check")
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
	local phase="$1" node="$2" extra="${3:-}"
	local colored_node="" colored_phase=""

	if log_group_scope_matches "${phase}"; then
		log_grouped_item_start "$(log_group_host_stage_title "${phase}" "${node}")"
	fi

	_NIXBOT_HOST_LOG_PHASE="${phase}"
	colored_node="$(colorize "$(host_color_code "${node}" "${phase}")" "${node}")"
	colored_phase="$(colorize "${_NIXBOT_C_GRAY}" "${phase}")"
	printf '\n-------- %s | %s --------\n' "${colored_node}" "${colored_phase}" >&2
	if [ -n "${extra}" ]; then
		printf '[%s] %s | %s\n' "${colored_node}" "${colored_phase}" "${extra}" >&2
	else
		printf '[%s] %s\n' "${colored_node}" "${colored_phase}" >&2
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

prefix_host_logs_with_prefix() {
	local prefix_str="$1"

	awk -v prefix="${prefix_str}" '{ if (length($0) == 0) { print ""; } else { print prefix $0; } fflush(); }'
}

prefix_host_logs() {
	local node="$1" phase="${2:-${_NIXBOT_HOST_LOG_PHASE:-}}"
	local color="" reset=""

	if should_use_color; then
		color="$(host_color_code "${node}" "${phase}")"
		reset="${_NIXBOT_C_RESET}"
	fi
	prefix_host_logs_with_prefix "| ${color}${node}${reset} | "
}

prefix_host_logs_plain() {
	prefix_host_logs_with_prefix "| $1 | "
}

host_log_prefix_enabled() {
	[ "${FORCE_PREFIX_HOST_LOGS}" -eq 1 ] && ! host_log_prefix_active
}

tee_prefixed_host_logs() {
	local node="$1" log_file="$2" phase="${3:-${_NIXBOT_HOST_LOG_PHASE:-}}"

	if should_use_color; then
		tee >(strip_ansi_escape_sequences | prefix_host_logs_plain "${node}" >>"${log_file}") |
			prefix_host_logs "${node}" "${phase}"
	else
		tee >(strip_ansi_escape_sequences | prefix_host_logs_plain "${node}" >>"${log_file}") |
			prefix_host_logs_plain "${node}"
	fi
}

tee_plain_host_logs() {
	local log_file="$1"

	tee >(strip_ansi_escape_sequences >>"${log_file}")
}

host_log_prefix_active() {
	[ "${_NIXBOT_HOST_LOG_PREFIX_ACTIVE:-0}" -eq 1 ]
}

run_with_host_log_prefix_context() {
	local phase="$1"
	shift
	local previous_active="${_NIXBOT_HOST_LOG_PREFIX_ACTIVE:-0}"
	local previous_phase="${_NIXBOT_HOST_LOG_PHASE:-}" rc=0 shell_opts="$-"

	case "${shell_opts}" in
	*e*)
		set +e
		;;
	esac
	_NIXBOT_HOST_LOG_PREFIX_ACTIVE=1
	_NIXBOT_HOST_LOG_PHASE="${phase}"
	"$@"
	rc="$?"
	_NIXBOT_HOST_LOG_PREFIX_ACTIVE="${previous_active}"
	_NIXBOT_HOST_LOG_PHASE="${previous_phase}"
	case "${shell_opts}" in
	*e*)
		set -e
		;;
	esac
	return "${rc}"
}

run_with_prefixed_combined_output() {
	local phase="$1" node="$2" log_file="${3:-}"
	shift 3

	if [ -n "${log_file}" ]; then
		run_with_host_log_prefix_context "${phase}" \
			run_with_combined_output "$@" > >(tee_prefixed_host_logs "${node}" "${log_file}" "${phase}" >&2)
	else
		run_with_host_log_prefix_context "${phase}" \
			run_with_combined_output "$@" > >(prefix_host_logs "${node}" "${phase}" >&2)
	fi
}

host_log_filter() {
	local node="$1" phase="${2:-${_NIXBOT_HOST_LOG_PHASE:-}}"

	if host_log_prefix_enabled; then
		prefix_host_logs "${node}" "${phase}"
	else
		cat
	fi
}

tee_host_log_filter() {
	local node="$1" log_file="$2" phase="${3:-${_NIXBOT_HOST_LOG_PHASE:-}}"

	if host_log_prefix_enabled; then
		tee_prefixed_host_logs "${node}" "${log_file}" "${phase}"
	else
		tee_plain_host_logs "${log_file}"
	fi
}

append_host_log_filter() {
	local node="$1" log_file="$2"

	if host_log_prefix_enabled; then
		prefix_host_logs_plain "${node}" >>"${log_file}"
	else
		strip_ansi_escape_sequences >>"${log_file}"
	fi
}

strip_ansi_escape_sequences() {
	LC_ALL=C sed -E $'s|\x1B\\[[0-?]*[ -/]*[@-~]||g'
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
	local deploy_failed_rollback_ok_hosts_name="${15}"
	local deploy_failed_rollback_failed_hosts_name="${16}"
	local health_failed_hosts_name="${17}" health_failed_rollback_ok_hosts_name="${18}"
	local health_failed_rollback_failed_hosts_name="${19}"
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
	local -n hfs_deploy_failed_rollback_ok_hosts_in_ref="${deploy_failed_rollback_ok_hosts_name}"
	local -n hfs_deploy_failed_rollback_failed_hosts_in_ref="${deploy_failed_rollback_failed_hosts_name}"
	local -n hfs_health_failed_hosts_in_ref="${health_failed_hosts_name}"
	local -n hfs_health_failed_rollback_ok_hosts_in_ref="${health_failed_rollback_ok_hosts_name}"
	local -n hfs_health_failed_rollback_failed_hosts_in_ref="${health_failed_rollback_failed_hosts_name}"

	if array_contains "${node}" "${hfs_build_failed_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (build)'
		return
	fi

	if array_contains "${node}" "${hfs_fully_skipped_hosts_in_ref[@]}"; then
		printf '%s' 'skip'
		return
	fi

	if [ "${action}" = "build" ] || [ "${action}" = "check-bootstrap" ] || [ "${action}" = "clear-remote-locks" ]; then
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
	elif array_contains "${node}" "${hfs_health_failed_rollback_failed_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (health; rollback failed)'
	elif array_contains "${node}" "${hfs_health_failed_rollback_ok_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (health; rolled back)'
	elif array_contains "${node}" "${hfs_health_failed_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (health)'
	elif array_contains "${node}" "${hfs_deploy_failed_rollback_failed_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (deploy; rollback failed)'
	elif array_contains "${node}" "${hfs_snapshot_failed_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (snapshot)'
	elif array_contains "${node}" "${hfs_deploy_failed_rollback_ok_hosts_in_ref[@]}"; then
		printf '%s' 'FAIL (deploy; rolled back)'
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

	if [ "${#RUN_SUMMARY_BUILD_FAILED_HOSTS[@]}" -gt 0 ] ||
		[ "${#RUN_SUMMARY_SNAPSHOT_FAILED_HOSTS[@]}" -gt 0 ] ||
		[ "${#RUN_SUMMARY_DEPLOY_FAILED_HOSTS[@]}" -gt 0 ] ||
		[ "${#RUN_SUMMARY_HEALTH_FAILED_HOSTS[@]}" -gt 0 ] ||
		[ "${#RUN_SUMMARY_ROLLBACK_FAILED_HOSTS[@]}" -gt 0 ]; then
		return 0
	fi

	for tf_status in "${RUN_SUMMARY_TF_STATUSES[@]}"; do
		if [ "${tf_status}" = "fail" ]; then
			return 0
		fi
	done

	return 1
}

host_summary_timing_suffix() {
	local node="$1" build_duration="" deploy_duration=""
	local build_duration_file="" deploy_duration_file=""
	local -a parts=()

	if [ -n "${RUN_SUMMARY_BUILD_STATUS_DIR:-}" ]; then
		build_duration_file="$(phase_dir_item_duration_file "${RUN_SUMMARY_BUILD_STATUS_DIR}" "${node}")"
		if build_duration="$(read_duration_file "${build_duration_file}" 2>/dev/null)"; then
			parts+=("build $(format_duration "${build_duration}")")
		fi
	fi
	if [ -n "${RUN_SUMMARY_DEPLOY_STATUS_DIR:-}" ]; then
		deploy_duration_file="$(phase_dir_item_duration_file "${RUN_SUMMARY_DEPLOY_STATUS_DIR}" "${node}")"
		if deploy_duration="$(read_duration_file "${deploy_duration_file}" 2>/dev/null)"; then
			parts+=("deploy $(format_duration "${deploy_duration}")")
		fi
	fi

	if [ "${#parts[@]}" -eq 0 ]; then
		return 0
	fi
	printf ' (%s)' "$(join_by_comma "${parts[@]}")"
}

format_summary_duration_or_dash() {
	local seconds="${1:-}"

	if [ -n "${seconds}" ]; then
		format_duration "${seconds}"
	else
		printf '%s' '-'
	fi
}

print_run_summary() {
	local final_rc="$1" node="" status=""
	local -a failed_summary_hosts=()
	local tf_label="" tf_status="" tf_display_status=""
	local total_duration_secs="" timing_suffix=""
	local total_duration="" build_duration="" deploy_duration="" runtime_suffix=""
	local -a failed_summary_tf=()
	local -a runtime_parts=()
	local colored_tf_status="" result_label=""

	log_section "Phase: Summary"
	echo "Action: ${RUN_SUMMARY_ACTION:-${ACTION}}" >&2
	if [ -n "${RUN_SUMMARY_STARTED_AT:-}" ]; then
		echo "Started: ${RUN_SUMMARY_STARTED_AT}" >&2
	fi
	if [ -n "${RUN_SUMMARY_STARTED_EPOCH:-}" ]; then
		total_duration_secs="$(elapsed_seconds "${RUN_SUMMARY_STARTED_EPOCH}")"
	fi
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
			RUN_SUMMARY_ROLLBACK_FAILED_HOSTS \
			RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_OK_HOSTS \
			RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS \
			RUN_SUMMARY_HEALTH_FAILED_HOSTS \
			RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_OK_HOSTS \
			RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_FAILED_HOSTS)"

		timing_suffix="$(host_summary_timing_suffix "${node}")"
		format_summary_host_line "${node}" "${status}" "${timing_suffix}" >&2
		echo >&2
		if [[ "${status}" == FAIL* ]]; then
			failed_summary_hosts+=("${node}: ${status}")
		fi
	done
	echo "Terraform:" >&2
	if [ "${#RUN_SUMMARY_TF_LABELS[@]}" -eq 0 ]; then
		echo "  - (none)" >&2
	fi
	for ((i = 0; i < ${#RUN_SUMMARY_TF_LABELS[@]}; i++)); do
		tf_label="${RUN_SUMMARY_TF_LABELS[$i]}"
		tf_status="${RUN_SUMMARY_TF_STATUSES[$i]}"
		tf_display_status="$(tf_summary_display_status "${tf_status}")"
		colored_tf_status="$(colorize "$(status_color_code "${tf_display_status}")" "${tf_display_status}")"
		echo "  - ${tf_label}: ${colored_tf_status}" >&2
		if [ "${tf_status}" = "fail" ]; then
			failed_summary_tf+=("${tf_label}: FAIL (tf)")
		fi
	done
	total_duration="$(format_summary_duration_or_dash "${total_duration_secs}")"
	build_duration="$(format_summary_duration_or_dash "${RUN_SUMMARY_BUILD_DURATION_SECS:-}")"
	deploy_duration="$(format_summary_duration_or_dash "${RUN_SUMMARY_DEPLOY_DURATION_SECS:-}")"
	if [ -n "${RUN_SUMMARY_BUILD_DURATION_SECS:-}" ]; then
		runtime_parts+=("build: ${build_duration}")
	fi
	if [ -n "${RUN_SUMMARY_DEPLOY_DURATION_SECS:-}" ]; then
		runtime_parts+=("deploy: ${deploy_duration}")
	fi
	if [ "${#runtime_parts[@]}" -gt 0 ]; then
		runtime_suffix=" ($(join_by_comma "${runtime_parts[@]}"))"
	fi
	echo "Run time: ${total_duration}${runtime_suffix}" >&2
	if [ "${#failed_summary_hosts[@]}" -gt 0 ] || [ "${#failed_summary_tf[@]}" -gt 0 ]; then
		printf '\n%s!!!!!!!!!! FAILURE !!!!!!!!!!%s\n' \
			"$(should_use_color && printf '%s' "${_NIXBOT_C_RED}" || true)" \
			"$(should_use_color && printf '%s' "${_NIXBOT_C_RESET}" || true)" >&2
		for node in "${failed_summary_hosts[@]}"; do
			echo "  - ${node}" >&2
		done
		for tf_label in "${failed_summary_tf[@]}"; do
			echo "  - ${tf_label}" >&2
		done
	fi
	if [ "${final_rc}" -ne 0 ] && [ -n "${NIXBOT_DIAG_DIR}" ]; then
		NIXBOT_KEEP_DIAG_DIR=1
	fi
	if [ "${NIXBOT_KEEP_DIAG_DIR:-0}" -eq 1 ] && [ -n "${NIXBOT_DIAG_DIR}" ]; then
		keep_diag_dir
	fi
	result_label="$([ "${final_rc}" -eq 0 ] && printf 'success' || printf 'failure')"
	printf '\nResult: %s\n' \
		"$(colorize \
			"$([ "${final_rc}" -eq 0 ] && printf '%s' "${_NIXBOT_C_GREEN}" || printf '%s' "${_NIXBOT_C_RED}")" \
			"${result_label}")" >&2
}

clear_run_summary_state() {
	RUN_SUMMARY_ACTION=""
	RUN_SUMMARY_STARTED_AT="${NIXBOT_RUN_STARTED_AT:-}"
	RUN_SUMMARY_STARTED_EPOCH="${NIXBOT_RUN_STARTED_EPOCH:-}"
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
	RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_OK_HOSTS=()
	RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS=()
	RUN_SUMMARY_HEALTH_FAILED_HOSTS=()
	RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_OK_HOSTS=()
	RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_FAILED_HOSTS=()
	RUN_SUMMARY_TF_LABELS=()
	RUN_SUMMARY_TF_STATUSES=()
	RUN_SUMMARY_BUILD_DURATION_SECS=""
	RUN_SUMMARY_DEPLOY_DURATION_SECS=""
	RUN_SUMMARY_BUILD_STATUS_DIR=""
	RUN_SUMMARY_DEPLOY_STATUS_DIR=""
}

set_run_summary_host_state() {
	local action="$1" selected_hosts_name="$2"
	local fully_skipped_hosts_name="$3" build_ok_hosts_name="$4" build_failed_hosts_name="$5"
	local snapshot_failed_hosts_name="$6" deploy_ok_hosts_name="$7"
	local deploy_skipped_hosts_name="$8" deploy_failed_hosts_name="$9"
	local optional_snapshot_skipped_hosts_name="${10}" optional_rollback_ok_hosts_name="${11}"
	local optional_rollback_failed_hosts_name="${12}"
	local rollback_ok_hosts_name="${13}" rollback_failed_hosts_name="${14}"
	local deploy_failed_rollback_ok_hosts_name="${15}"
	local deploy_failed_rollback_failed_hosts_name="${16}"
	local health_failed_hosts_name="${17}" health_failed_rollback_ok_hosts_name="${18}"
	local health_failed_rollback_failed_hosts_name="${19}"
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
	local -n srshs_deploy_failed_rollback_ok_hosts_in_ref="${deploy_failed_rollback_ok_hosts_name}"
	local -n srshs_deploy_failed_rollback_failed_hosts_in_ref="${deploy_failed_rollback_failed_hosts_name}"
	local -n srshs_health_failed_hosts_in_ref="${health_failed_hosts_name}"
	local -n srshs_health_failed_rollback_ok_hosts_in_ref="${health_failed_rollback_ok_hosts_name}"
	local -n srshs_health_failed_rollback_failed_hosts_in_ref="${health_failed_rollback_failed_hosts_name}"

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
		RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_OK_HOSTS=("${srshs_deploy_failed_rollback_ok_hosts_in_ref[@]}")
		RUN_SUMMARY_DEPLOY_FAILED_ROLLBACK_FAILED_HOSTS=("${srshs_deploy_failed_rollback_failed_hosts_in_ref[@]}")
		RUN_SUMMARY_HEALTH_FAILED_HOSTS=("${srshs_health_failed_hosts_in_ref[@]}")
		RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_OK_HOSTS=("${srshs_health_failed_rollback_ok_hosts_in_ref[@]}")
		RUN_SUMMARY_HEALTH_FAILED_ROLLBACK_FAILED_HOSTS=("${srshs_health_failed_rollback_failed_hosts_in_ref[@]}")
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
	local -a runtime_env=(NIXBOT_IN_NIX_SHELL=1)

	if [ "${RUNTIME_SHELL_FLAG}" = "1" ]; then
		return
	fi

	require_cmds nix

	script_path="${BASH_SOURCE[0]:-$0}"
	script_dir="$(cd "$(dirname "${script_path}")" && pwd -P)"
	if [ -n "${SSH_ORIGINAL_COMMAND:-}" ]; then
		nix_shell_cmd=(nix --quiet --no-warn-dirty shell "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
	else
		flake_path="$(git -C "${script_dir}" rev-parse --show-toplevel 2>/dev/null || true)"
		if [ -z "${flake_path}" ]; then
			flake_path="$(cd "${script_dir}/../.." && pwd -P)"
		fi
		nix_shell_cmd=(nix --quiet --no-warn-dirty shell --inputs-from "${flake_path}" "${NIXBOT_RUNTIME_INSTALLABLES[@]}")
	fi

	if [ -n "${NIXBOT_CONFIG_PATH:-}" ]; then
		runtime_env+=(NIXBOT_CONFIG_OVERRIDE_PATH="${NIXBOT_CONFIG_OVERRIDE_PATH}")
	fi

	exec "${nix_shell_cmd[@]}" -c env "${runtime_env[@]}" bash "${script_path}" "$@"
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

run_list_hosts_action() {
	local selected_json=""

	prepare_run_context selected_json
	print_config_override_line
	print_selected_groups_block
	print_selected_hosts_block "${selected_json}"
}

run_list_groups_action() {
	local config_json=""

	config_json="$(load_deploy_config_json "${NIXBOT_CONFIG_PATH}")"
	init_deploy_settings "${config_json}"
	print_config_override_line
	print_groups_block
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

	if [ "${#hrafsc_request_args_out_ref[@]}" -ge 1 ] &&
		[ "${hrafsc_request_args_out_ref[0]}" = "${NIXBOT_SSH_ARGV_PREFIX}" ]; then
		encoded_args="${hrafsc_request_args_out_ref[1]:-}"
		[ -n "${encoded_args}" ] || die "Empty encoded argv payload"
		mapfile -d '' -t hrafsc_request_args_out_ref < <(decode_ssh_command_args "${encoded_args}") ||
			die "Failed to decode argv payload"
		return
	fi

	if [ "${#hrafsc_request_args_out_ref[@]}" -ne 0 ] || [ -z "${SSH_ORIGINAL_COMMAND:-}" ]; then
		return
	fi

	if [[ "${SSH_ORIGINAL_COMMAND}" == "${encoded_prefix}"* ]]; then
		encoded_args="${SSH_ORIGINAL_COMMAND#"${encoded_prefix}"}"
		[ -n "${encoded_args}" ] || die "Empty forced-command argv payload"
		mapfile -d '' -t hrafsc_request_args_out_ref < <(decode_ssh_command_args "${encoded_args}") ||
			die "Failed to decode forced-command argv payload"
		return
	fi

	case "${SSH_ORIGINAL_COMMAND}" in
	*[\`\$\(\)\{\}\;\&\|\<\>\\\'\"]*)
		die "Unsupported SSH forced-command syntax. Use nixbot --ci-trigger or an unquoted simple argv form."
		;;
	esac

	read -r -a hrafsc_request_args_out_ref <<<"${SSH_ORIGINAL_COMMAND}"
	if [ "${#hrafsc_request_args_out_ref[@]}" -gt 0 ] && [ "${hrafsc_request_args_out_ref[0]}" = "--" ]; then
		hrafsc_request_args_out_ref=("${hrafsc_request_args_out_ref[@]:1}")
	fi
	if [ "${#hrafsc_request_args_out_ref[@]}" -gt 0 ]; then
		case "${hrafsc_request_args_out_ref[0]}" in
		nixbot | */nixbot | nixbot.sh | */nixbot.sh)
			hrafsc_request_args_out_ref=("${hrafsc_request_args_out_ref[@]:1}")
			;;
		esac
	fi
	if [ "${#hrafsc_request_args_out_ref[@]}" -ge 1 ] &&
		[ "${hrafsc_request_args_out_ref[0]}" = "${NIXBOT_SSH_ARGV_PREFIX}" ]; then
		encoded_args="${hrafsc_request_args_out_ref[1]:-}"
		[ -n "${encoded_args}" ] || die "Empty encoded argv payload"
		mapfile -d '' -t hrafsc_request_args_out_ref < <(decode_ssh_command_args "${encoded_args}") ||
			die "Failed to decode argv payload"
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
		echo "Started: ${NIXBOT_RUN_STARTED_AT}" >&2
		echo "Decrypt identities: $(announce_age_decrypt_identity_candidates)" >&2
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
	capture_initial_tty_state
	trap cleanup_trap EXIT
	trap request_hangup HUP
	trap 'request_cancel 130 INT' INT
	trap 'request_cancel 143 TERM' TERM

	hydrate_request_args_from_ssh_command request_args

	if [ "${#request_args[@]}" -eq 0 ]; then
		usage
		return 0
	fi

	case "${request_args[0]}" in
	--clean)
		ACTION="clean"
		if [ "${#request_args[@]}" -gt 1 ] && [[ "${request_args[1]}" != --* ]]; then
			NIXBOT_CLEAN_MODE="${request_args[1]}"
			request_args=("${request_args[@]:2}")
		else
			NIXBOT_CLEAN_MODE="auto"
			request_args=("${request_args[@]:1}")
		fi
		;;
	--clean=*)
		ACTION="clean"
		NIXBOT_CLEAN_MODE="${request_args[0]#--clean=}"
		request_args=("${request_args[@]:1}")
		;;
	--clear-remote-locks)
		ACTION="clear-remote-locks"
		if [ "${#request_args[@]}" -gt 1 ] && [[ "${request_args[1]}" != --* ]]; then
			NIXBOT_CLEAR_REMOTE_LOCKS_MODE="${request_args[1]}"
			request_args=("${request_args[@]:2}")
		else
			NIXBOT_CLEAR_REMOTE_LOCKS_MODE="all"
			request_args=("${request_args[@]:1}")
		fi
		;;
	--clear-remote-locks=*)
		ACTION="clear-remote-locks"
		NIXBOT_CLEAR_REMOTE_LOCKS_MODE="${request_args[0]#--clear-remote-locks=}"
		request_args=("${request_args[@]:1}")
		;;
	--list-hosts)
		ACTION="list-hosts"
		request_args=("${request_args[@]:1}")
		;;
	--list-groups)
		ACTION="list-groups"
		request_args=("${request_args[@]:1}")
		;;
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
	run | deploy | build | dev-build | tf | tf-dns | tf-platform | tf-apps | check-bootstrap | clear-remote-locks | clean | tf/*)
		ACTION="${request_args[0]}"
		request_args=("${request_args[@]:1}")
		;;
	tofu)
		ensure_runtime_ready "$@"
		run_tofu_wrapper "${request_args[@]:1}"
		return
		;;
	help | -h | --help)
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
	if [ "${ACTION}" != "clean" ]; then
		cleanup_stale_runtime_dirs
	fi
	if [ "${ACTION}" = "list-hosts" ]; then
		[ -z "${SHA}" ] || die "--list-hosts uses the current checkout; --sha is unsupported"
		[ "${CI_TRIGGER}" -eq 0 ] || die "--list-hosts is local-only and cannot run through --ci-trigger"
		run_list_hosts_action
		return
	fi
	if [ "${ACTION}" = "list-groups" ]; then
		[ -z "${SHA}" ] || die "--list-groups uses the current checkout; --sha is unsupported"
		[ "${CI_TRIGGER}" -eq 0 ] || die "--list-groups is local-only and cannot run through --ci-trigger"
		run_list_groups_action
		return
	fi
	if [ "${ACTION}" = "clean" ]; then
		[ -z "${SHA}" ] || die "clean uses the current checkout; --sha is unsupported"
	fi
	if [ "${ACTION}" = "clear-remote-locks" ]; then
		[ -z "${SHA}" ] || die "clear-remote-locks uses the current checkout; --sha is unsupported"
	fi
	if [ "${CI_TRIGGER}" -eq 1 ]; then
		[ "${ACTION}" != "dev-build" ] || die "dev-build is local-only and cannot run through --ci-trigger"
		run_ci_trigger
		return
	fi
	if [ "${ACTION}" = "clean" ]; then
		run_clean_action
		return
	fi

	if [ "${ACTION}" != "dev-build" ] && [ "${ACTION}" != "clear-remote-locks" ]; then
		prepare_repo_worktree
		reexec_repo_script_if_needed "${ACTION}" "${request_args[@]}"
	else
		if [ "${ACTION}" = "dev-build" ]; then
			prepare_dev_build_workspace
		fi
	fi

	run_requested_action
}

main "$@"
