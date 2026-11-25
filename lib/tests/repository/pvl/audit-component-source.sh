#!/usr/bin/env bash
# Scan even unforced production branches for undeclared components, core
# implementation paths and repository inputs. Core is a declared public API;
# actual isolation from its source location is tested by the external consumers.
set -euo pipefail

source_dir=${1:?expected isolated component source}
if rg -n --glob '*.nix' --glob '!**/tests/**' \
	-e '(\.\./)+core/' \
	-e '(\.\./)+(runtime|services|repo|stack|system|lib|hosts|config|pkgs|overlays|data)([^[:alnum:]_.-]|$)' \
	-e '/(home|Users)/[^/[:space:]]+/(src|spaces)/' "$source_dir"; then
	echo "unexpected sibling, repository or checkout path in $source_dir" >&2
	exit 1
else
	# rg: 1 = no matches; do not accept scan errors as a passing audit.
	[[ $? == 1 ]]
fi
