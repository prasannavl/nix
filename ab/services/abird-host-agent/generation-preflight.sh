set -eu

usage() {
	cat <<'EOF'
Usage: abird-host-agent-generation-preflight [--human|--json|--quiet] INCOMING ACTION [MODE]
EOF
}

output_mode="${ABIRD_HOST_AGENT_GENERATION_PREFLIGHT_OUTPUT:-human}"
output_mode_argument=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--human | --json | --quiet)
		if [ -n "$output_mode_argument" ]; then
			echo "generation preflight accepts only one output mode" >&2
			exit 2
		fi
		output_mode_argument="${1#--}"
		output_mode="$output_mode_argument"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		echo "unsupported generation preflight option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		break
		;;
	esac
done

case "$output_mode" in
human | json | quiet)
	;;
*)
	echo "unsupported generation preflight output mode: $output_mode" >&2
	exit 2
	;;
esac

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
	usage >&2
	exit 2
fi

incoming="$1"
action="$2"
mode="${3:-${ABIRD_HOST_AGENT_GENERATION_ADMISSION_MODE:-normal}}"

case "$mode" in
normal | rollback)
	;;
*)
	echo "unsupported generation admission mode: $mode" >&2
	exit 2
	;;
esac

case "$action" in
switch | test | boot | dry-activate)
	;;
*)
	exit 0
	;;
esac

current_system="${ABIRD_HOST_AGENT_CURRENT_SYSTEM:-/run/current-system}"
registry_name="etc/abird-host-agent/generation-admission-registry.json"
incoming_registry="$incoming/$registry_name"
current_registry="$current_system/$registry_name"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/abird-host-agent-generation-admission.XXXXXX")"
temporary_registry="$work_dir/rollback-registry.json"
absent_current_registry="$work_dir/absent-current-registry.json"
results_file="$work_dir/results.jsonl"
domains_file="$work_dir/domains.tsv"

cleanup() {
	rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Directories, special files and dangling links are retained evidence, not absence.
for registry in "$incoming_registry" "$current_registry"; do
	if { [ -e "$registry" ] || [ -L "$registry" ]; } && [ ! -f "$registry" ]; then
		echo "invalid projection admission registry file: $registry" >&2
		exit 1
	fi
done

if [ ! -e "$incoming_registry" ]; then
	if [ "$mode" != rollback ]; then
		echo "incoming generation is missing the projection admission registry" >&2
		exit 1
	fi
	printf '%s\n' '{"schema_version":1,"domains":[]}' >"$temporary_registry"
	incoming_registry="$temporary_registry"
fi

validate_registry() {
	registry="$1"
	label="$2"
	if ! @JQ@ -e '
      .schema_version == 1
      and (.domains | type == "array")
      and ((.domains | map(.name) | unique | length) == (.domains | length))
      and all(.domains[];
        (.name | type == "string") and (.name | length > 0)
		and (.schema_version | type == "number")
		and (.schema_version | floor == .)
		and .schema_version >= 1
        and (.adapter | type == "string") and (.adapter | length > 0)
        and (.program | type == "string") and (.program | startswith("/nix/store/"))
	        and (.authority_paths | type == "array")
        and ((.authority_paths | unique | length) == (.authority_paths | length))
		and all(.authority_paths[];
		  type == "string"
			  and length > 0
			  and (startswith("/") | not)
			  and (test("[[:cntrl:]]") | not)
			  and (split("/") | all(. != "" and . != "." and . != ".." and . != ".git"))))
    ' >/dev/null <"$registry"; then
		echo "$label generation has an invalid projection admission registry" >&2
		exit 1
	fi
}

validate_registry "$incoming_registry" incoming
if [ "$action" = boot ] && @JQ@ -e '.domains | length > 0' >/dev/null <"$incoming_registry"; then
	echo "boot activation cannot guarantee projection admission at the later reboot; use switch, test, or dry-activate" >&2
	exit 1
fi
# Framework absence is stricter than registry absence. An unregistered agent
# still owns its predecessor documents; an agent-free OS never had that contract.
agent_free_generation() {
	local generation="$1" evidence
	[ -d "$generation" ] || return 1
	for evidence in \
		"$generation/etc/abird-host-agent"* \
		"$generation/sw/bin/abird-host-agent" \
		"$generation/sw/bin/abird-host-agent-"* \
		"$generation/sw/bin/.abird-host-agent"* \
		"$generation/etc/systemd/system/abird-host-agent"*; do
		if [ -e "$evidence" ] || [ -L "$evidence" ]; then
			return 1
		fi
	done
}

# Native metadata checks distinguish absence from inaccessible/broken paths.
require_pristine_directory() {
	local directory="$1" allow_lock="${2:-false}"
	local -a arguments=()
	if [ "$allow_lock" = true ]; then
		arguments+=(--allow-state-lock)
	fi
	@HOST_AGENT@ --json _reconcile pristine-directory --path "$directory" "${arguments[@]}" >/dev/null
}

require_pristine_runtime() {
	local directory
	local -a state_directories=(@STATE_DIRECTORIES@) data_directories=(@DATA_DIRECTORIES@)
	for directory in "${state_directories[@]}"; do
		require_pristine_directory "$directory" true || return
	done
	for directory in "${data_directories[@]}"; do
		require_pristine_directory "$directory" || return
	done
}

if { [ -e "$current_system" ] || [ -L "$current_system" ]; } && [ ! -d "$current_system" ]; then
	echo "current generation is unavailable" >&2
	exit 1
fi
current_generation_exists=false
if [ -e "$current_system" ] || [ -L "$current_system" ]; then
	for current_generation_entry in \
		"$current_system"/* \
		"$current_system"/.[!.]* \
		"$current_system"/..?*; do
		if [ -e "$current_generation_entry" ] || [ -L "$current_generation_entry" ]; then
			current_generation_exists=true
			break
		fi
	done
fi
has_current=false
if [ -e "$current_registry" ]; then
	validate_registry "$current_registry" current
	has_current=true
elif [ "$mode" = rollback ]; then
	echo "rollback requires a current projection admission registry" >&2
	exit 1
fi

# Producer-owned declarations must be neutral even with an empty domain registry.
# This is compiled from Nix intent, not an operator override or inferred JSON.
require_agent_free_boundary() {
	if [ "$action" = boot ]; then
		echo "boot activation cannot guarantee agent-free admission at the later reboot; use switch, test, or dry-activate" >&2
		return 1
	fi
	if @HAS_DECLARED_STATE@; then
		echo "agent-free transition refuses declared holds or desired resource states" >&2
		return 1
	fi
	require_pristine_runtime
}

current_agent_free=false
incoming_agent_free=false
if [ "$has_current" = false ] && [ "$mode" = normal ]; then
	if agent_free_generation "$current_system" || [ "$current_generation_exists" = false ]; then
		require_pristine_directory @CONFIGURATION_DIRECTORY@
		if [ "$current_generation_exists" = true ]; then
			require_agent_free_boundary
		else
			require_pristine_runtime
		fi
		current_agent_free=true
	fi
fi
if [ "$mode" = rollback ] && [ ! -e "$incoming/$registry_name" ] &&
	agent_free_generation "$incoming"; then
	require_agent_free_boundary
	incoming_agent_free=true
fi

# Absence is explicit evidence, never a copy of the incoming authority. Existing
# agent-free generations must still pass each adapter's reverse admission.
printf '%s\n' '{"schema_version":1,"domains":[]}' >"$absent_current_registry"

if [ "$has_current" = true ]; then
	# shellcheck disable=SC2016 # jq variables must remain literal.
	if ! @JQ@ -e --arg mode "$mode" --slurpfile current "$current_registry" '
      ($current[0].domains | map(.name)) as $current_names
      | (.domains | map(.name)) as $incoming_names
      | if $mode == "rollback"
        then all($incoming_names[]; . as $name | $current_names | index($name) != null)
        else all($current_names[]; . as $name | $incoming_names | index($name) != null)
        end
    ' >/dev/null <"$incoming_registry"; then
		echo "projection admission domains are durable lifecycle tombstones and cannot be removed" >&2
		exit 1
	fi
	# A domain's admission semantics cannot silently change while the domain
	# remains registered. Program store paths may change as implementations are
	# rebuilt. Adapter, result schema, and authority paths stay fixed until a
	# predecessor-compatible migration protocol exists.
	# shellcheck disable=SC2016 # jq variables must remain literal.
	if ! @JQ@ -e --slurpfile current "$current_registry" '
      ($current[0].domains | map({key: .name, value: .}) | from_entries) as $before
      | all(.domains[];
          ($before[.name] // null) as $old
		  | $old == null
		    or ($old.adapter == .adapter
		        and $old.schema_version == .schema_version
		        and $old.authority_paths == .authority_paths))
	' >/dev/null <"$incoming_registry"; then
		echo "projection admission adapter, schema, or authority changed without a predecessor-compatible migration protocol" >&2
		exit 1
	fi
fi

: >"$results_file"

validate_adapter_result() {
	result="$1"
	expected_domain="$2"
	expected_adapter="$3"
	expected_schema="$4"
	expected_mode="$5"
	expected_transition="$6"
	expected_authority="$7"

	# shellcheck disable=SC2016 # jq variables must remain literal.
	printf '%s\n' "$result" | @JQ@ -cse \
		--arg domain "$expected_domain" \
		--arg adapter "$expected_adapter" \
		--argjson schema_version "$expected_schema" \
		--arg mode "$expected_mode" \
		--arg transition "$expected_transition" \
		--argjson authority "$expected_authority" '
		  if length == 1
		  and (.[0]
		  | .ok == true
		  and .operation == "projection_domain_admission"
		  and .result.schema_version == $schema_version
		  and .result.domain == $domain
		  and .result.adapter == $adapter
		  and .result.mode == $mode
		  and .result.transition == $transition
		  and .result.authority == $authority
		  and (.result.checks | type == "array")
		  and (.result.evidence | type == "array")
		  and (.result.deferred_resources.count | type == "number")
		  and (.result.deferred_resources.resources | type == "array")
		  and .result.deferred_resources.count
		      == (.result.deferred_resources.resources | length)
		  )
		  then .[0]
		  else error("invalid projection admission result")
		  end
		'
}

# Normal transitions execute the incoming adapter. A retired domain remains as
# a neutral, registered tombstone so future generations and rollbacks retain a
# validator for its authority history. Rollback additionally
# executes current-only adapters so a newly registered domain cannot vanish
# merely because the older generation predates the registry. A first
# registration on an existing agent requires complete authority and asks the incoming
# adapter to validate both the forward transition and its rollback before any
# host mutation. Domain-specific schema normalization stays in that adapter;
# the dispatcher neither compares opaque documents nor guesses compatibility.
# shellcheck disable=SC2016 # jq variables must remain literal.
@JQ@ -nr \
	--slurpfile incoming "$incoming_registry" \
	--slurpfile current "$([ "$has_current" = true ] && printf '%s' "$current_registry" || printf '%s' "$absent_current_registry")" \
	--arg mode "$mode" '
    ($incoming[0].domains | map({key: .name, value: .}) | from_entries) as $new
    | ($current[0].domains | map({key: .name, value: .}) | from_entries) as $old
    | ((($new | keys) + (if $mode == "rollback" then ($old | keys) else [] end)) | unique[])
      as $name
    | ($new[$name] // $old[$name]) as $domain
	| [$name, $domain.adapter, $domain.program,
	   ($domain.schema_version | tostring),
	   (if $new[$name] == null then "removed" else "present" end),
	   (if $old[$name] == null then "absent" else "present" end),
	   ($domain.authority_paths | tojson)]
	  | @tsv
  ' >"$domains_file"
while IFS="$(printf '\t')" read -r domain adapter program domain_schema transition current_domain authority_paths; do
	if [ ! -x "$program" ]; then
		echo "projection admission adapter $domain has no executable validator: $program" >&2
		exit 1
	fi
	authority_list="$work_dir/authority-list"
	authority_records="$work_dir/authority-records.jsonl"
	: >"$authority_records"
	@JQ@ -r '.[]' <<EOF_AUTHORITY_PATHS >"$authority_list"
$authority_paths
EOF_AUTHORITY_PATHS
	missing_authority=""
	missing_current_authority=""
	while IFS= read -r authority_path; do
		incoming_authority="$incoming/etc/abird-host-agent/$authority_path"
		current_authority="$current_system/etc/abird-host-agent/$authority_path"
		incoming_sha256=""
		current_sha256=""
		if [ -f "$incoming_authority" ]; then
			incoming_sha256="$(@SHA256SUM@ "$incoming_authority" | cut -d ' ' -f 1)"
		elif [ "$incoming_agent_free" != true ] || [ "$transition" != removed ]; then
			missing_authority="$authority_path"
			break
		fi
		if [ -f "$current_authority" ]; then
			current_sha256="$(@SHA256SUM@ "$current_authority" | cut -d ' ' -f 1)"
		elif [ "$current_domain" = present ] || [ "$current_agent_free" != true ]; then
			missing_current_authority="$authority_path"
			break
		fi
		# shellcheck disable=SC2016 # jq variables must remain literal.
		@JQ@ -cn \
			--arg path "$authority_path" \
			--arg incoming_sha256 "$incoming_sha256" \
			--arg current_sha256 "$current_sha256" \
			'{path: $path,
			  incoming_sha256: (if $incoming_sha256 == "" then null else $incoming_sha256 end),
			  current_sha256: (if $current_sha256 == "" then null else $current_sha256 end)}' \
			>>"$authority_records"
	done <"$authority_list"
	if [ -n "$missing_authority" ]; then
		echo "projection domain $domain is missing incoming authority: $missing_authority" >&2
		exit 1
	fi
	if [ -n "$missing_current_authority" ]; then
		echo "projection domain $domain is missing current authority: $missing_current_authority" >&2
		exit 1
	fi
	authority_evidence="$(@JQ@ -s . "$authority_records")"
	if [ "$mode" = normal ] && [ "$current_generation_exists" = true ] && [ "$current_domain" = absent ]; then
		# Prove that the newly registered adapter can also validate an automatic
		# rollback to the unregistered predecessor. The authority evidence is
		# expressed from that reverse transition's point of view.
		# shellcheck disable=SC2016 # jq variables must remain literal.
		reverse_authority_evidence="$(printf '%s\n' "$authority_evidence" | @JQ@ -c '
		  map({
		    path: .path,
		    incoming_sha256: .current_sha256,
		    current_sha256: .incoming_sha256
		  })
		')"
		if reverse_result="$("$program" "$domain" "$current_system" "$incoming" rollback removed "$reverse_authority_evidence" </dev/null)"; then
			:
		else
			status="$?"
			echo "projection admission adapter $domain rejected rollback to its unregistered predecessor" >&2
			exit "$status"
		fi
		if ! validate_adapter_result \
			"$reverse_result" \
			"$domain" \
			"$adapter" \
			"$domain_schema" \
			rollback \
			removed \
			"$reverse_authority_evidence" >/dev/null; then
			echo "projection admission adapter $domain returned an invalid predecessor rollback result" >&2
			exit 1
		fi
	fi
	if result="$("$program" "$domain" "$incoming" "$current_system" "$mode" "$transition" "$authority_evidence" </dev/null)"; then
		:
	else
		status="$?"
		echo "projection admission adapter $domain rejected the $mode transition" >&2
		exit "$status"
	fi
	if ! validated_result="$(validate_adapter_result \
		"$result" \
		"$domain" \
		"$adapter" \
		"$domain_schema" \
		"$mode" \
		"$transition" \
		"$authority_evidence")"; then
		echo "projection admission adapter $domain returned an invalid result" >&2
		exit 1
	fi
	printf '%s\n' "$validated_result" >>"$results_file"
done <"$domains_file"

# shellcheck disable=SC2016 # jq variables must remain literal.
result="$(@JQ@ -s \
	--arg host "@HOST@" \
	--arg mode "$mode" '
  [.[].result] as $domains
  | [$domains[].evidence[]] as $evidence
  | [$domains[].deferred_resources.resources[]] as $deferred
  | if (all($deferred[]; (.resource | type == "string") and (.resource | length > 0))
        and (($deferred | map(.resource) | unique | length) == ($deferred | length)))
    then {
      ok: true,
      operation: "host_agent_generation_preflight",
      result: {
        schema_version: 2,
        mode: $mode,
        host: $host,
        domains: $domains,
        checks: [$domains[].checks[]],
        evidence: $evidence,
        deferred_resources: {
          count: ($deferred | length),
          resources: $deferred
        }
      }
    }
    else error("projection admission domains returned duplicate or invalid deferred resources")
    end
' "$results_file")"

case "$output_mode" in
json)
	printf '%s\n' "$result"
	;;
human)
	# shellcheck disable=SC2016 # jq variables must remain literal.
	printf '%s\n' "$result" | @JQ@ -r '
      "Generation admission: admitted"
      + " (host=\(.result.host), mode=\(.result.mode),"
      + " domains=\(.result.domains | length),"
      + " deferred=\(.result.deferred_resources.count))"
    '
	;;
quiet)
	;;
esac
