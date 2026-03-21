# Bash Colors
# 
# Text Format           Foreground (text) color         Background color
# 0: normal text        30: Black                       40: Black
# 1: bold	            31: Red	                        41: Red
# 4: Underlined text    32: Green                       42: Green
#                       33: Yellow                      43: Yellow
#                       34: Blue                        44: Blue
#                       35: Purple                      45: Purple
#                       36: Cyan                        46: Cyan
#                       37: White                       47: White
# 
# ESC sequence: \033 or \e
# Color sequence: \[ESC[fg;format;bgm\] or \[$(tput setaf/ab color0-7)\] 
# tput => terminfo, ncurses

setup_ps1() {
    # reset
    local r b
    r="\[$(tput sgr0)\]"
    b="\[$(tput bold)\]"

    local fgray="\[\033[38;5;7m\]"
    local fgreen="\[\033[38;5;2m\]"
    local fblue="\[\033[38;5;33m\]"
    local fred="\[\033[38;5;196m\]"
    local fpink="\[\033[38;5;13m\]"
    local error ps1_main_line ps1_exit_line

    # shellcheck disable=SC2016
    error="${b}${fred}"'$(e="$?"; [ "$e" = "0" ] || printf "[exit: %s]\n\n" "$e")'

    ps1_main_line="${error}${r}${fgray}[\t|${b}${fgreen}\u${r}${fgreen}@\h\
${r}${fgray}:${r}${fblue}\w${r}${fgray}]"

    ps1_exit_line="${r}\\n\$ "

    if command -v git >/dev/null 2>&1; then
        ps1_main_line="${ps1_main_line} ${fpink}\$(__parse_git_branch_info)"
    fi

    export PS1="${ps1_main_line}${ps1_exit_line}"
}

# get current branch in git repo
__parse_git_branch_info() {
	local branch
	local status

	branch=$(git branch 2> /dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/\1/')
	if [ ! "${branch}" == "" ]
	then
		status="$(__parse_git_branch_status)"
		echo "(${branch}${status})"
	else
		echo ""
	fi
}

# get current status of git repo
__parse_git_branch_status() {
	local status dirty untracked ahead newfile renamed deleted bits
	status="$(git status 2>&1)"

	dirty=1
	untracked=1
	ahead=1
	newfile=1
	renamed=1
	deleted=1
	bits=''

	grep -q "modified:" <<<"${status}" && dirty=0
	grep -q "Untracked files" <<<"${status}" && untracked=0
	grep -q "Your branch is ahead of" <<<"${status}" && ahead=0
	grep -q "new file:" <<<"${status}" && newfile=0
	grep -q "renamed:" <<<"${status}" && renamed=0
	grep -q "deleted:" <<<"${status}" && deleted=0

	if [ "${ahead}" == "0" ]; then
		bits="${bits}>>"
	fi
	if [ "${newfile}" == "0" ]; then
		bits="${bits}+"
	fi
	if [ "${deleted}" == "0" ]; then
		bits="${bits}-"
	fi
	if [ "${renamed}" == "0" ]; then
		bits="${bits}^"
	fi
	if [ "${untracked}" == "0" ]; then
		bits="${bits}##"
	fi
	if [ "${dirty}" == "0" ]; then
		bits="${bits}*"
	fi
	if [ ! "${bits}" == "" ]; then
		echo "[${bits}]"
	else
		echo ""
	fi
}

setup_ps1
