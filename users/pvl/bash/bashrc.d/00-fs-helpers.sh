__source_file_if_exists() {
	local file="${1?-file required}"
	if [[ -f "$file" ]]; then
		. "$file"
	fi
}

# mkdir -p and cd
mkcd() {
    local cmd_prefix="${cmd_prefix:-}"
    $cmd_prefix mkdir -p "$@" && cd "$@"
}

mkfile() {
    local cmd_prefix="${cmd_prefix:-}"
    local file_path="${1?-file path required}"
    local file_mode="${2:-}"
    local dir_path

    dir_path="$(dirname "$file_path")"
    $cmd_prefix mkdir -p "$dir_path"

    if [[ -p /dev/stdin ]]; then
        $cmd_prefix tee "$file_path" >/dev/null
    else
        $cmd_prefix touch "$file_path"
    fi

    if [[ -n $file_mode ]]; then
        $cmd_prefix chmod "$file_mode" "$file_path"
    fi
}

mkscript() {
    local cmd_prefix="${cmd_prefix:-}"
    local file_path="${1?-file path required}"

    mkfile "$file_path" "+x"
}

# swap file name with an auto tmp file
mvx() {
    local cmd_prefix="${cmd_prefix:-}"

    local from="${1?-source path required}"
    local to="${2?-target path required}"
    (
        set -Eeuo pipefail
        local suffix
        suffix="$(set +o pipefail && cat /dev/urandom | head -c12 | md5sum)"
        echo "mv: ${from} -> ${from}.${suffix}"
        $cmd_prefix mv "${from}" "${from}.${suffix}"
        echo "mv: ${to} -> ${from}"
        $cmd_prefix mv "${to}" "${from}"
        echo "mv ${from}.${suffix} -> ${to}"
        $cmd_prefix mv "${from}.${suffix}" "${to}"
    )
}

mkcd_sudo() {
    local cmd_prefix="sudo"
    mkcd "$@"
}

mkscript_sudo() {
    local cmd_prefix="sudo"
    mkscript "$@"
}

mkfile_sudo() {
    local cmd_prefix="sudo"
    mkfile "$@"
}

mvx_sudo() {
    local cmd_prefix="sudo"
    mvx "$@"
}

