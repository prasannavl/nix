#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Entrypoint setup
# -----------------------------------------------------------------------------

init_vars() {
	SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
	SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd -P)"
	REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd -P)"
	COMMON_PATH="${SCRIPT_DIR}/common.sh"
	# shellcheck source=pkgs/ext/gcp-vms/common.sh
	source "${COMMON_PATH}"
	gcp_init_defaults

	INSTANCE_NAME=""
	FLAKE_HOST=""
	INSTALL_MODE="repo"
	GCP_PROJECT_ID="${GCP_DEFAULT_PROJECT_ID}"
	GCP_ZONE=""
	TARGET_HOST=""
	TARGET_USER="${GCP_DEFAULT_BOOTSTRAP_SSH_USER}"
	TARGET_PORT="${GCP_DEFAULT_BOOTSTRAP_SSH_PORT}"
	BOOTSTRAP_SSH_KEY_PATH="${GCP_DEFAULT_BOOTSTRAP_SSH_KEY_PATH}"
	AGE_DECRYPT_IDENTITY_PATH="${GCP_DEFAULT_AGE_DECRYPT_IDENTITY_PATH}"
	BUILD_ON="${GCP_DEFAULT_BUILD_ON}"
	POST_INSTALL_TIMEOUT="${GCP_DEFAULT_POST_INSTALL_TIMEOUT}"
	BOOTSTRAP_SWAP_GB="${GCP_DEFAULT_BOOTSTRAP_SWAP_GB}"
	BOOTSTRAP_SWAP_MIN_MIB="${GCP_DEFAULT_BOOTSTRAP_SWAP_MIN_MIB}"
	PRINT_BUILD_LOGS="0"
	DEBUG_INSTALL="0"
	COPY_HOST_KEYS="0"
	KEEP_TMP="0"
	FORCE_NIXIFY="0"
	GENERIC_NIXOS_VERSION="${GCP_GENERIC_NIXOS_VERSION:-25.11}"
	GENERIC_NIXPKGS_REF="${GCP_GENERIC_NIXPKGS_REF:-github:NixOS/nixpkgs/nixos-${GENERIC_NIXOS_VERSION}}"
	GENERIC_SYSTEM="${GCP_GENERIC_NIXOS_SYSTEM:-x86_64-linux}"
	GENERIC_DISK_DEVICE="${GCP_GENERIC_NIXOS_DISK_DEVICE:-}"
	GCP_INSTALL_STAGE_DIR=""
}

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
	cat <<'EOF'
Usage:
  pkgs/ext/gcp-vms/nixify-vm.sh --name <instance> [options]

Turns an existing GCP bootstrap VM into the matching repo-defined NixOS host.
When the VM already appears to be NixOS, this is a no-op with a note unless
--force is given.

Required:
  --name <instance>              GCE instance name. Also defaults --host.

Options:
  --host <flake-host>            Repo flake host name. Default: same as --name.
  --generic                      Install a generated minimal NixOS host instead
                                  of requiring a repo flake host. Defaults to
                                  NixOS 25.11.
  --project <project>            GCP project ID. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --zone <zone>                  Optional GCP zone. Defaults to auto-discovery
                                  by instance name.
  --target-host <ip-or-host>     Optional direct SSH target override. When
                                  omitted, the external IP is resolved from GCP.
  --target-user <user>           Bootstrap SSH user. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --ssh-user <user>              Alias for --target-user.
  --target-port <port>           Bootstrap SSH port. Default: configured in
                                  pkgs/ext/gcp-vms/common.sh.
  --ssh-port <port>              Alias for --target-port.
  --ssh-key <path>               Bootstrap SSH private key. Default:
                                  configured in pkgs/ext/gcp-vms/common.sh.
  --age-identity <path>          Local age decrypt identity. Default:
                                  configured in pkgs/ext/gcp-vms/common.sh.
  --build-on auto|local|remote   Default: configured in pkgs/ext/gcp-vms/common.sh
  --post-install-timeout <sec>   Wait time for steady-state nixbot SSH.
                                  Default: configured in pkgs/ext/gcp-vms/common.sh
  --bootstrap-swap-gb <gb>       Temporary swap size before kexec. Default: -1
                                  auto. Use 0 to disable, or a positive integer
                                  to force that GiB size.
  --bootstrap-swap-min-mib <mib> Auto-mode physical RAM threshold. Swap is only
                                  created when MemTotal is below this value.
                                  Default: 4096.
  --generic-nixpkgs-ref <ref>    Generic-mode nixpkgs flake ref. Default:
                                  github:NixOS/nixpkgs/nixos-25.11
  --generic-disk-device <path>   Generic-mode target disk. Defaults to the
                                  bootstrap VM's current root disk.
  --force                        Re-run nixos-anywhere even when the target
                                  already appears to be NixOS.
  --print-build-logs             Pass through to nixos-anywhere.
  --debug                        Pass through to nixos-anywhere.
  --copy-host-keys               Preserve the bootstrap VM's SSH host keys.
  --keep-tmp                     Keep repo tmp staging files for debugging.
  -h, --help
EOF
}

ensure_runtime_shell() {
	gcp_ensure_runtime_shell "${SCRIPT_PATH}" "$@"
}

parse_args() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--name)
			INSTANCE_NAME="${2:-}"
			shift 2
			;;
		--host)
			FLAKE_HOST="${2:-}"
			shift 2
			;;
		--generic)
			INSTALL_MODE="generic"
			shift
			;;
		--project)
			GCP_PROJECT_ID="${2:-}"
			shift 2
			;;
		--zone)
			GCP_ZONE="${2:-}"
			shift 2
			;;
		--target-host)
			TARGET_HOST="${2:-}"
			shift 2
			;;
		--target-user | --ssh-user)
			TARGET_USER="${2:-}"
			shift 2
			;;
		--target-port | --ssh-port)
			TARGET_PORT="${2:-}"
			shift 2
			;;
		--ssh-key)
			BOOTSTRAP_SSH_KEY_PATH="${2:-}"
			shift 2
			;;
		--age-identity)
			AGE_DECRYPT_IDENTITY_PATH="${2:-}"
			shift 2
			;;
		--build-on)
			BUILD_ON="${2:-}"
			shift 2
			;;
		--post-install-timeout)
			POST_INSTALL_TIMEOUT="${2:-}"
			shift 2
			;;
		--bootstrap-swap-gb)
			BOOTSTRAP_SWAP_GB="${2:-}"
			shift 2
			;;
		--bootstrap-swap-min-mib)
			BOOTSTRAP_SWAP_MIN_MIB="${2:-}"
			shift 2
			;;
		--generic-nixpkgs-ref)
			GENERIC_NIXPKGS_REF="${2:-}"
			shift 2
			;;
		--generic-disk-device)
			GENERIC_DISK_DEVICE="${2:-}"
			shift 2
			;;
		--force)
			FORCE_NIXIFY="1"
			shift
			;;
		--print-build-logs)
			PRINT_BUILD_LOGS="1"
			shift
			;;
		--debug)
			DEBUG_INSTALL="1"
			shift
			;;
		--copy-host-keys)
			COPY_HOST_KEYS="1"
			shift
			;;
		--keep-tmp)
			KEEP_TMP="1"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			usage
			gcp_die "Unknown argument: $1"
			;;
		esac
	done
}

validate_args() {
	if [ -z "${INSTANCE_NAME}" ] && [ -n "${FLAKE_HOST}" ]; then
		INSTANCE_NAME="${FLAKE_HOST}"
	fi
	[ -n "${INSTANCE_NAME}" ] || gcp_die "--name is required"
	if [ -z "${FLAKE_HOST}" ] && [ "${INSTALL_MODE}" = "repo" ]; then
		FLAKE_HOST="${INSTANCE_NAME}"
	fi
	case "${INSTALL_MODE}" in
	repo | generic) ;;
	*) gcp_die "Unknown install mode: ${INSTALL_MODE}" ;;
	esac
	[ -n "${GCP_PROJECT_ID}" ] || gcp_die "No GCP project configured; pass --project or set GCP_DEFAULT_PROJECT_ID in pkgs/ext/gcp-vms/common.sh"

	BOOTSTRAP_SSH_KEY_PATH="$(gcp_expand_path "${BOOTSTRAP_SSH_KEY_PATH}")"
	AGE_DECRYPT_IDENTITY_PATH="$(gcp_expand_path "${AGE_DECRYPT_IDENTITY_PATH}")"

	[ -f "${BOOTSTRAP_SSH_KEY_PATH}" ] || gcp_die "SSH private key not found: ${BOOTSTRAP_SSH_KEY_PATH}"
	[ -f "${BOOTSTRAP_SSH_KEY_PATH}.pub" ] || gcp_die "SSH public key not found: ${BOOTSTRAP_SSH_KEY_PATH}.pub"
	[[ "${BOOTSTRAP_SWAP_GB}" =~ ^-?[0-9]+$ ]] || gcp_die "--bootstrap-swap-gb must be an integer: -1 auto, 0 disabled, positive GiB size"
	[ "${BOOTSTRAP_SWAP_GB}" -ge -1 ] || gcp_die "--bootstrap-swap-gb must be -1, 0, or a positive integer"
	[[ "${BOOTSTRAP_SWAP_MIN_MIB}" =~ ^[0-9]+$ ]] || gcp_die "--bootstrap-swap-min-mib must be a non-negative integer"
	if [ "${INSTALL_MODE}" = "repo" ]; then
		[ -f "${AGE_DECRYPT_IDENTITY_PATH}" ] || gcp_die "Age identity not found: ${AGE_DECRYPT_IDENTITY_PATH}"
	fi
}

# -----------------------------------------------------------------------------
# Target discovery and SSH probes
# -----------------------------------------------------------------------------

resolve_target_host() {
	if [ -n "${TARGET_HOST}" ]; then
		return 0
	fi

	if [ -z "${GCP_ZONE}" ]; then
		GCP_ZONE="$(gcp_discover_instance_zone "${GCP_PROJECT_ID}" "${INSTANCE_NAME}")"
	fi
	[ -n "${GCP_ZONE}" ] || gcp_die "Could not find instance ${INSTANCE_NAME} in ${GCP_PROJECT_ID}; pass --zone or --target-host"

	TARGET_HOST="$(gcp_instance_ip "${GCP_PROJECT_ID}" "${GCP_ZONE}" "${INSTANCE_NAME}")"
	[ -n "${TARGET_HOST}" ] || gcp_die "Unable to resolve external IP for ${INSTANCE_NAME}"
}

target_is_nixos() {
	local ssh_user="$1" ssh_key_path="$2" ssh_port="$3" known_hosts_file="$4"

	ssh \
		-i "${ssh_key_path}" \
		-o BatchMode=yes \
		-o ConnectTimeout=5 \
		-o StrictHostKeyChecking=accept-new \
		-o "UserKnownHostsFile=${known_hosts_file}" \
		-p "${ssh_port}" \
		"${ssh_user}@${TARGET_HOST}" \
		'test -e /etc/NIXOS && ! readlink -f /run/current-system 2>/dev/null | grep -q nixos-installer' >/dev/null 2>&1
}

shell_quote() {
	local value="$1"

	printf '%q' "${value}"
}

# -----------------------------------------------------------------------------
# Bootstrap kexec support
# -----------------------------------------------------------------------------

ensure_bootstrap_swap() {
	local ssh_target="$1" ssh_key_path="$2" ssh_port="$3" known_hosts_file="$4"
	local swap_gb_q="" min_mib_q=""

	[ "${BOOTSTRAP_SWAP_GB}" != "0" ] || return 0

	swap_gb_q="$(shell_quote "${BOOTSTRAP_SWAP_GB}")"
	min_mib_q="$(shell_quote "${BOOTSTRAP_SWAP_MIN_MIB}")"
	gcp_log "Ensuring bootstrap swap for kexec on ${ssh_target}"
	ssh \
		-i "${ssh_key_path}" \
		-o BatchMode=yes \
		-o ConnectTimeout=10 \
		-o StrictHostKeyChecking=accept-new \
		-o "UserKnownHostsFile=${known_hosts_file}" \
		-p "${ssh_port}" \
		"${ssh_target}" \
		"if [ \"\$(id -u)\" = 0 ]; then BOOTSTRAP_SWAP_GB=${swap_gb_q} BOOTSTRAP_SWAP_MIN_MIB=${min_mib_q} bash -s; else sudo -n env BOOTSTRAP_SWAP_GB=${swap_gb_q} BOOTSTRAP_SWAP_MIN_MIB=${min_mib_q} bash -s; fi" <<'EOF'
set -Eeuo pipefail

swap_path="/swapfile-nixos-anywhere"
mem_mib="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
swap_mib="$(awk '/SwapTotal/ { print int($2 / 1024) }' /proc/meminfo)"
swap_gb="${BOOTSTRAP_SWAP_GB}"

if [ "${swap_gb}" = "-1" ]; then
	if [ "${mem_mib}" -ge "${BOOTSTRAP_SWAP_MIN_MIB}" ]; then
		printf 'RAM is %s MiB; no bootstrap swap needed\n' "${mem_mib}" >&2
		exit 0
	fi
	needed_mib=$((BOOTSTRAP_SWAP_MIN_MIB - mem_mib - swap_mib))
	if [ "${needed_mib}" -le 0 ]; then
		swap_gb=2
	else
		swap_gb=$(((needed_mib + 1023) / 1024))
		if [ "${swap_gb}" -lt 2 ]; then
			swap_gb=2
		fi
	fi
fi

systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

if ! swapon --show=NAME --noheadings | grep -qx "${swap_path}"; then
	if [ ! -f "${swap_path}" ]; then
		if command -v fallocate >/dev/null 2>&1; then
			fallocate -l "${swap_gb}G" "${swap_path}" || dd if=/dev/zero of="${swap_path}" bs=1M count=$((swap_gb * 1024)) status=progress
		else
			dd if=/dev/zero of="${swap_path}" bs=1M count=$((swap_gb * 1024)) status=progress
		fi
		chmod 600 "${swap_path}"
		mkswap "${swap_path}" >/dev/null
	fi
	swapon "${swap_path}"
fi

swap_mib="$(awk '/SwapTotal/ { print int($2 / 1024) }' /proc/meminfo)"
printf 'Bootstrap swap ready: RAM=%s MiB swap=%s MiB file=%s GiB\n' "${mem_mib}" "${swap_mib}" "${swap_gb}" >&2
EOF
}

nix_string() {
	local value="$1"

	jq -Rn -r --arg value "${value}" '$value | @json'
}

# -----------------------------------------------------------------------------
# Generic NixOS flake generation
# -----------------------------------------------------------------------------

bootstrap_root_disk_device() {
	local ssh_target="$1" ssh_key_path="$2" ssh_port="$3" known_hosts_file="$4"
	local disk_device=""

	disk_device="$(
		ssh \
			-i "${ssh_key_path}" \
			-o BatchMode=yes \
			-o ConnectTimeout=10 \
			-o StrictHostKeyChecking=accept-new \
			-o "UserKnownHostsFile=${known_hosts_file}" \
			-p "${ssh_port}" \
			"${ssh_target}" \
			'bash -s' <<'EOF'
set -Eeuo pipefail

root_source="$(findmnt -n -o SOURCE /)"
root_device="$(readlink -f "${root_source}" 2>/dev/null || printf '%s\n' "${root_source}")"
disk_name="$(lsblk -no PKNAME "${root_device}" 2>/dev/null | head -n1 || true)"

if [ -z "${disk_name}" ]; then
	disk_name="$(lsblk -ndo NAME,TYPE | awk '$2 == "disk" { print $1; exit }')"
fi

[ -n "${disk_name}" ] || exit 1
case "${disk_name}" in
/dev/*) printf '%s\n' "${disk_name}" ;;
*) printf '/dev/%s\n' "${disk_name}" ;;
esac
EOF
	)" || gcp_die "Unable to resolve bootstrap root disk for ${ssh_target}; pass --generic-disk-device"

	[ -n "${disk_device}" ] || gcp_die "Unable to resolve bootstrap root disk for ${ssh_target}; pass --generic-disk-device"
	printf '%s\n' "${disk_device}"
}

write_generic_flake() {
	local flake_dir="$1" disk_device="$2" public_key="$3"
	local hostname_nix="" ssh_user_nix="" public_key_nix="" password_hash_nix=""
	local disk_device_nix="" nixpkgs_ref_nix="" system_nix="" generic_version_nix=""
	local password_seed="" password_salt="" password_hash=""

	hostname_nix="$(nix_string "${INSTANCE_NAME}")"
	ssh_user_nix="$(nix_string "${TARGET_USER}")"
	public_key_nix="$(nix_string "${public_key}")"
	password_seed="$(od -An -tx1 -N 32 /dev/urandom | tr -d ' \n')"
	password_salt="$(od -An -tx1 -N 8 /dev/urandom | tr -d ' \n')"
	password_hash="$(openssl passwd -6 -salt "${password_salt}" "${password_seed}")"
	password_hash_nix="$(nix_string "${password_hash}")"
	disk_device_nix="$(nix_string "${disk_device}")"
	nixpkgs_ref_nix="$(nix_string "${GENERIC_NIXPKGS_REF}")"
	system_nix="$(nix_string "${GENERIC_SYSTEM}")"
	generic_version_nix="$(nix_string "${GENERIC_NIXOS_VERSION}")"

	cat >"${flake_dir}/flake.nix" <<EOF
{
  inputs = {
    nixpkgs.url = ${nixpkgs_ref_nix};
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, disko, ... }: {
    nixosConfigurations.generic = nixpkgs.lib.nixosSystem {
      system = ${system_nix};
      modules = [
        disko.nixosModules.disko
        (nixpkgs + "/nixos/modules/virtualisation/google-compute-config.nix")
        ({ lib, pkgs, ... }: {
          networking.hostName = ${hostname_nix};
          boot.kernelParams = lib.mkAfter [
            "console=tty0"
            "console=ttyS0,115200n8"
          ];

          services.openssh.enable = true;
          services.openssh.settings = {
            PasswordAuthentication = false;
            KbdInteractiveAuthentication = false;
            UsePAM = false;
          };

          users.users.${ssh_user_nix} = {
            isNormalUser = true;
            extraGroups = [ "wheel" ];
            shell = pkgs.bashInteractive;
            hashedPassword = ${password_hash_nix};
            openssh.authorizedKeys.keys = [ ${public_key_nix} ];
          };
          security.sudo.wheelNeedsPassword = false;

          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          boot.loader.grub.enable = true;
          boot.loader.grub.device = lib.mkForce ${disk_device_nix};
          boot.loader.grub.devices = [ ${disk_device_nix} ];
          boot.loader.grub.efiSupport = true;
          boot.loader.grub.efiInstallAsRemovable = true;

          fileSystems."/".device = lib.mkForce "/dev/disk/by-label/nixos";
          fileSystems."/boot".device = lib.mkForce "/dev/disk/by-label/ESP";

          disko.devices.disk.main = {
            type = "disk";
            device = ${disk_device_nix};
            content = {
              type = "gpt";
              partitions = {
                boot = {
                  size = "1M";
                  type = "EF02";
                };
                ESP = {
                  size = "512M";
                  type = "EF00";
                  content = {
                    type = "filesystem";
                    format = "vfat";
                    extraArgs = [ "-n" "ESP" ];
                    mountpoint = "/boot";
                    mountOptions = [ "umask=0077" ];
                  };
                };
                root = {
                  size = "100%";
                  content = {
                    type = "filesystem";
                    format = "ext4";
                    extraArgs = [ "-L" "nixos" ];
                    mountpoint = "/";
                  };
                };
              };
            };
          };

          system.stateVersion = ${generic_version_nix};
        })
      ];
    };
  };
}
EOF

	git -C "${flake_dir}" init -q
	git -C "${flake_dir}" add flake.nix
	git -C "${flake_dir}" \
		-c user.name="gcp-vms" \
		-c user.email="gcp-vms@localhost" \
		commit -qm "generic nixos flake"
	nix --extra-experimental-features "nix-command flakes" flake lock "${flake_dir}" >/dev/null
	git -C "${flake_dir}" add flake.lock
	git -C "${flake_dir}" \
		-c user.name="gcp-vms" \
		-c user.email="gcp-vms@localhost" \
	commit -qm "lock generic nixos flake"
}

# -----------------------------------------------------------------------------
# Generic NixOS install
# -----------------------------------------------------------------------------

nixify_generic_host() {
	local detect_known_hosts="" install_known_hosts="" post_known_hosts=""
	local disk_device="" public_key="" flake_dir=""
	local ssh_target=""
	local -a nixos_anywhere_cmd=()

	resolve_target_host

	GCP_INSTALL_STAGE_DIR="$(gcp_make_tmp_dir "gcp-nixify-generic")"
	detect_known_hosts="${GCP_INSTALL_STAGE_DIR}/detect-known_hosts"
	install_known_hosts="${GCP_INSTALL_STAGE_DIR}/install-known_hosts"
	post_known_hosts="${GCP_INSTALL_STAGE_DIR}/post-known_hosts"
	flake_dir="${GCP_INSTALL_STAGE_DIR}/generic-flake"
	mkdir -p "${flake_dir}"
	trap 'if [ "${KEEP_TMP}" = "1" ]; then gcp_log "Keeping tmp dir ${GCP_INSTALL_STAGE_DIR:-}"; else gcp_cleanup_tmp_dir "${GCP_INSTALL_STAGE_DIR:-}"; fi' EXIT

	if target_is_nixos "${TARGET_USER}" "${BOOTSTRAP_SSH_KEY_PATH}" "${TARGET_PORT}" "${detect_known_hosts}"; then
		if [ "${FORCE_NIXIFY}" != "1" ]; then
			gcp_log "Instance ${INSTANCE_NAME} already appears to be NixOS; nothing to do. Use --force to reinstall."
			printf 'Already NixOS: %s\nMode: generic\nTarget: %s@%s\n' \
				"${INSTANCE_NAME}" \
				"${TARGET_USER}" \
				"${TARGET_HOST}"
			return 0
		fi
		gcp_log "Instance ${INSTANCE_NAME} already appears to be NixOS; --force given, reinstalling generic NixOS"
	fi

	ssh_target="${TARGET_USER}@${TARGET_HOST}"
	if [ -n "${GENERIC_DISK_DEVICE}" ]; then
		disk_device="${GENERIC_DISK_DEVICE}"
	else
		disk_device="$(bootstrap_root_disk_device \
			"${ssh_target}" \
			"${BOOTSTRAP_SSH_KEY_PATH}" \
			"${TARGET_PORT}" \
			"${install_known_hosts}")"
	fi
	public_key="$(<"${BOOTSTRAP_SSH_KEY_PATH}.pub")"
	write_generic_flake "${flake_dir}" "${disk_device}" "${public_key}"

	nixos_anywhere_cmd=(
		nixos-anywhere
		--flake "${flake_dir}#generic"
		--target-host "${ssh_target}"
		-i "${BOOTSTRAP_SSH_KEY_PATH}"
		-p "${TARGET_PORT}"
		--build-on "${BUILD_ON}"
		--ssh-option StrictHostKeyChecking=accept-new
		--ssh-option "UserKnownHostsFile=${install_known_hosts}"
	)
	if [ "${COPY_HOST_KEYS}" = "1" ]; then
		nixos_anywhere_cmd+=(--copy-host-keys)
	fi
	if [ "${PRINT_BUILD_LOGS}" = "1" ]; then
		nixos_anywhere_cmd+=(--print-build-logs)
	fi
	if [ "${DEBUG_INSTALL}" = "1" ]; then
		nixos_anywhere_cmd+=(--debug)
	fi

	gcp_log "Nixifying ${INSTANCE_NAME} with generated NixOS ${GENERIC_NIXOS_VERSION} via ${ssh_target}"
	gcp_log "Generic install target disk: ${disk_device}"
	ensure_bootstrap_swap \
		"${ssh_target}" \
		"${BOOTSTRAP_SSH_KEY_PATH}" \
		"${TARGET_PORT}" \
		"${install_known_hosts}"
	"${nixos_anywhere_cmd[@]}"

	gcp_log "Waiting for generic NixOS SSH on ${ssh_target}"
	if ! gcp_wait_for_ssh \
		"${ssh_target}" \
		"${BOOTSTRAP_SSH_KEY_PATH}" \
		"22" \
		"${post_known_hosts}" \
		"${POST_INSTALL_TIMEOUT}"; then
		gcp_die "Generic NixOS install completed, but SSH did not come up for ${ssh_target}"
	fi

	printf 'Nixified instance: %s\nMode: generic\nNixOS: %s\nTarget: %s\nDisk: %s\n' \
		"${INSTANCE_NAME}" \
		"${GENERIC_NIXOS_VERSION}" \
		"${ssh_target}" \
		"${disk_device}"
}

# -----------------------------------------------------------------------------
# Repo-defined NixOS install
# -----------------------------------------------------------------------------

nixify_repo_host() {
	local deploy_user="" deploy_target="" deploy_key="" bootstrap_key=""
	local age_identity_key="" proxy_jump=""
	local bootstrap_key_secret="" age_identity_secret="" deploy_key_secret=""
	local stage_root="" detect_known_hosts="" bootstrap_known_hosts="" deploy_known_hosts=""
	local deploy_key_runtime="" bootstrap_ssh_target="" deploy_ssh_target=""
	local existing_nixos="0"
	local -a nixos_anywhere_cmd=()

	gcp_preflight_flake_host "${FLAKE_HOST}"
	{
		read -r deploy_user
		read -r deploy_target
		read -r deploy_key
		read -r bootstrap_key
		read -r age_identity_key
		read -r proxy_jump
	} < <(gcp_takeover_context "${FLAKE_HOST}")

	[ -n "${deploy_key}" ] || gcp_die "No deploy key configured for ${FLAKE_HOST} in hosts/nixbot.nix"
	[ -n "${bootstrap_key}" ] || gcp_die "No bootstrap key configured for ${FLAKE_HOST} in hosts/nixbot.nix"
	[ -n "${age_identity_key}" ] || gcp_die "No ageIdentityKey configured for ${FLAKE_HOST} in hosts/nixbot.nix"

	deploy_key_secret="$(gcp_resolve_repo_path "${deploy_key}")"
	bootstrap_key_secret="$(gcp_resolve_repo_path "${bootstrap_key}")"
	age_identity_secret="$(gcp_resolve_repo_path "${age_identity_key}")"

	[ -f "${deploy_key_secret}" ] || gcp_die "Deploy key secret not found: ${deploy_key_secret}"
	[ -f "${bootstrap_key_secret}" ] || gcp_die "Bootstrap key secret not found: ${bootstrap_key_secret}"
	[ -f "${age_identity_secret}" ] || gcp_die "Age identity secret not found: ${age_identity_secret}"

	resolve_target_host

	if [ "${TARGET_HOST}" != "${deploy_target}" ]; then
		gcp_log "Configured steady-state target for ${FLAKE_HOST} is ${deploy_target}; nixifying via ${TARGET_HOST}"
	fi
	if [ -n "${proxy_jump}" ]; then
		gcp_log "Host ${FLAKE_HOST} has proxyJump=${proxy_jump}; post-install verification uses the direct bootstrap IP instead"
	fi
	if [ "${bootstrap_key_secret}" != "${deploy_key_secret}" ]; then
		gcp_log "bootstrapKey and deploy key differ for ${FLAKE_HOST}; staging bootstrapKey and verifying with deploy key"
	fi

	GCP_INSTALL_STAGE_DIR="$(gcp_make_tmp_dir "gcp-nixify-vm")"
	stage_root="${GCP_INSTALL_STAGE_DIR}/root"
	detect_known_hosts="${GCP_INSTALL_STAGE_DIR}/detect-known_hosts"
	bootstrap_known_hosts="${GCP_INSTALL_STAGE_DIR}/bootstrap-known_hosts"
	deploy_known_hosts="${GCP_INSTALL_STAGE_DIR}/deploy-known_hosts"
	deploy_key_runtime="${GCP_INSTALL_STAGE_DIR}/deploy-key"
	trap 'if [ "${KEEP_TMP}" = "1" ]; then gcp_log "Keeping tmp dir ${GCP_INSTALL_STAGE_DIR:-}"; else gcp_cleanup_tmp_dir "${GCP_INSTALL_STAGE_DIR:-}"; fi' EXIT

	gcp_decrypt_secret_to_path \
		"${deploy_key_secret}" \
		"${deploy_key_runtime}" \
		"${AGE_DECRYPT_IDENTITY_PATH}"

	if target_is_nixos "${deploy_user}" "${deploy_key_runtime}" "22" "${detect_known_hosts}"; then
		if [ "${FORCE_NIXIFY}" != "1" ]; then
			gcp_log "Instance ${INSTANCE_NAME} already appears to be NixOS; nothing to do. Use --force to reinstall."
			printf 'Already NixOS: %s\nHost: %s\nTarget: %s@%s\n' \
				"${INSTANCE_NAME}" \
				"${FLAKE_HOST}" \
				"${deploy_user}" \
				"${TARGET_HOST}"
			return 0
		fi
		existing_nixos="1"
		gcp_log "Instance ${INSTANCE_NAME} already appears to be NixOS; --force given, reinstalling through steady-state SSH"
	fi

	gcp_stage_takeover_files \
		"${bootstrap_key_secret}" \
		"${age_identity_secret}" \
		"${AGE_DECRYPT_IDENTITY_PATH}" \
		"${stage_root}"

	if [ "${existing_nixos}" = "1" ]; then
		TARGET_USER="${deploy_user}"
		TARGET_PORT="22"
		BOOTSTRAP_SSH_KEY_PATH="${deploy_key_runtime}"
	fi

	bootstrap_ssh_target="${TARGET_USER}@${TARGET_HOST}"
	nixos_anywhere_cmd=(
		nixos-anywhere
		--flake "${REPO_ROOT}#${FLAKE_HOST}"
		--target-host "${bootstrap_ssh_target}"
		-i "${BOOTSTRAP_SSH_KEY_PATH}"
		-p "${TARGET_PORT}"
		--build-on "${BUILD_ON}"
		--extra-files "${stage_root}"
		--ssh-option StrictHostKeyChecking=accept-new
		--ssh-option "UserKnownHostsFile=${bootstrap_known_hosts}"
	)
	if [ "${COPY_HOST_KEYS}" = "1" ]; then
		nixos_anywhere_cmd+=(--copy-host-keys)
	fi
	if [ "${PRINT_BUILD_LOGS}" = "1" ]; then
		nixos_anywhere_cmd+=(--print-build-logs)
	fi
	if [ "${DEBUG_INSTALL}" = "1" ]; then
		nixos_anywhere_cmd+=(--debug)
	fi

	gcp_log "Nixifying ${INSTANCE_NAME} as .#${FLAKE_HOST} via ${bootstrap_ssh_target}"
	ensure_bootstrap_swap \
		"${bootstrap_ssh_target}" \
		"${BOOTSTRAP_SSH_KEY_PATH}" \
		"${TARGET_PORT}" \
		"${bootstrap_known_hosts}"
	"${nixos_anywhere_cmd[@]}"

	deploy_ssh_target="${deploy_user}@${TARGET_HOST}"
	gcp_log "Waiting for steady-state SSH on ${deploy_ssh_target}"
	if ! gcp_wait_for_ssh \
		"${deploy_ssh_target}" \
		"${deploy_key_runtime}" \
		"22" \
		"${deploy_known_hosts}" \
		"${POST_INSTALL_TIMEOUT}"; then
		gcp_die "NixOS install completed, but steady-state SSH did not come up for ${deploy_ssh_target}"
	fi

	gcp_log "Repo takeover verified for ${FLAKE_HOST}"
	printf 'Nixified instance: %s\nInstalled host: %s\nBootstrap target: %s\nSteady-state SSH: %s\nNext deploy command: ./scripts/nixbot.sh deploy --hosts %s\n' \
		"${INSTANCE_NAME}" \
		"${FLAKE_HOST}" \
		"${bootstrap_ssh_target}" \
		"${deploy_ssh_target}" \
		"${FLAKE_HOST}"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------

nixify_host() {
	case "${INSTALL_MODE}" in
	repo) nixify_repo_host ;;
	generic) nixify_generic_host ;;
	esac
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
	init_vars
	ensure_runtime_shell "$@"
	parse_args "$@"
	validate_args
	nixify_host
}

main "$@"
