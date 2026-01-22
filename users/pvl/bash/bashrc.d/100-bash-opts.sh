# bash env and opts

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
shopt -s globstar

shopt -s autocd
#shopt -s cdspell
shopt -s direxpand
#shopt -s dirspell

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS.
shopt -s checkwinsize

### history items

# append to the history file, don't overwrite it
shopt -s histappend
# cmdhist: save all lines of a multiple-line command in the same history entry
shopt -s cmdhist

# don't put duplicate lines in the history.
# ignoredups + ignorespace (shorthand: ignoreboth)
# erasedups: remove dups from the history file as well
export HISTCONTROL="ignoreboth:erasedups"

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
export HISTSIZE=1000000
export HISTFILESIZE=1000000

### other options like bind

# Enable history expansion with the SPACE key.
bind Space:magic-space
