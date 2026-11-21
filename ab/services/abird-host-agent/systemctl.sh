#!/usr/bin/env bash
set -Eeuo pipefail

main() {
	local systemctl_program runuser_program id_program manager user uid

	systemctl_program="${ABIRD_HOST_AGENT_SYSTEMCTL_REAL:-systemctl}"
	runuser_program="${ABIRD_HOST_AGENT_RUNUSER_REAL:-runuser}"
	id_program="${ABIRD_HOST_AGENT_ID_REAL:-id}"

	# A named local user manager is safer to reach through its own runtime bus.
	# systemd's extra machine transport can disconnect while NixOS reexecutes
	# managers during activation, even though the user manager itself is healthy.
	if (($# >= 3)) && [[ $1 == --user && $2 == --machine && $3 == *@ ]]; then
		manager=$3
		user=${manager%@}
		if [[ -n $user ]]; then
			uid="$(${id_program} -u -- "$user")"
			shift 3
			exec "${runuser_program}" -u "$user" -- \
				env -u DBUS_SESSION_BUS_ADDRESS \
				XDG_RUNTIME_DIR="/run/user/${uid}" \
				"${systemctl_program}" --user "$@"
		fi
	fi

	exec "${systemctl_program}" "$@"
}

main "$@"
