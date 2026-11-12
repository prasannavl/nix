# shellcheck shell=bash
# `rm` for Pi agent shells (see index.ts). Recursive removal is checked
# against the expanded, resolved target before anything is removed:
# - refused: `/` and paths one or two levels below it; $HOME, its top-level
#   entries and its ancestors; the working directory and its ancestors; Git
#   repositories, worktrees and Git metadata, and directories containing a
#   repository up to four levels down.
# - scratch (/tmp, /dev/shm, the user runtime directory or anything strictly
#   inside a `tmp` directory): only the working-directory rule applies.
# All operands are checked first; one refusal removes nothing. Anything else,
# including non-recursive removal, is passed to coreutils rm unchanged.
#
# Limits, by design:
# - `rm -rf *` in a repository is allowed: every direct child of the working
#   directory is a legitimate target, so only the repository root and its
#   ancestors are refused.
# - An absolute `rm` path skips this script, and a symlink swapped between this
#   check and the final `exec` is not re-checked.

# Never recurse through the exported `rm` function.
unset -f rm 2>/dev/null || true

refuse() {
	printf 'rm-guard: refused %q -> %s: %s.\n' "$1" "$2" "$3" >&2
	printf 'rm-guard: nothing was removed. If this is intended, ask the user to run it.\n' >&2
	exit 1
}

recursive=0
operands=()
options_done=0
for arg in "$@"; do
	if [ "$options_done" = 1 ]; then
		operands+=("$arg")
		continue
	fi
	case $arg in
	--) options_done=1 ;;
	--recursive) recursive=1 ;;
	--*) ;;
	-?*)
		case $arg in
		*[rR]*) recursive=1 ;;
		esac
		;;
	*) operands+=("$arg") ;;
	esac
done

if [ "$recursive" = 1 ]; then
	cwd=$(pwd -P 2>/dev/null || pwd)
	home=
	if [ -n "${HOME:-}" ]; then
		home=$(realpath -m -- "$HOME")
	fi
	for op in "${operands[@]}"; do
		[ -n "$op" ] || continue
		case $op in
		*/ | . | .. | */. | */..) path=$(realpath -m -- "$op") ;;
		*)
			# Without a trailing slash a symlink operand removes only the link.
			[ ! -L "$op" ] || continue
			parent=$(realpath -m -- "$(dirname -- "$op")")
			name=$(basename -- "$op")
			if [ "$parent" = / ]; then
				path=/$name
			else
				path=$parent/$name
			fi
			;;
		esac

		[ "$path" != / ] || refuse "$op" "$path" "it is the root directory"
		case $cwd in
		"$path" | "$path"/*) refuse "$op" "$path" "it is the working directory or contains it" ;;
		esac

		scratch=0
		case $path in
		*/tmp/?* | /dev/shm/?*) scratch=1 ;;
		esac
		if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
			case $path in
			"$XDG_RUNTIME_DIR"/?*) scratch=1 ;;
			esac
		fi
		[ "$scratch" = 0 ] || continue

		slashes=${path//[!\/]/}
		[ "${#slashes}" -gt 2 ] || refuse "$op" "$path" "it is a top-level directory"
		if [ -n "$home" ] && [ "$home" != / ]; then
			case $home in
			"$path" | "$path"/*) refuse "$op" "$path" "it is \$HOME or contains it" ;;
			esac
			[ "${path%/*}" != "$home" ] || refuse "$op" "$path" "it is a top-level directory in \$HOME"
		fi
		case $path/ in
		*/.git/*) refuse "$op" "$path" "it is Git metadata" ;;
		esac
		[ ! -e "$path/.git" ] || refuse "$op" "$path" "it is a Git repository or worktree"
		if [ -d "$path" ]; then
			nested=$(find "$path" -mindepth 2 -maxdepth 4 -name .git -print -quit 2>/dev/null || true)
			[ -z "$nested" ] || refuse "$op" "$path" "it contains the Git repository or worktree ${nested%/.git}"
		fi
	done
fi

exec rm "$@"
