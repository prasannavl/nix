set -eu

incoming="$1"
action="$2"

case "$action" in
switch | test)
	;;
*)
	exit 0
	;;
esac

current_system="${ABIRD_HOST_AGENT_CURRENT_SYSTEM:-/run/current-system}"
current_contract="$current_system/etc/abird-host-agent/service-placement-contract.json"
incoming_contract="$incoming/etc/abird-host-agent/service-placement-contract.json"

# The first generation which introduces this contract has no trustworthy
# deployed predecessor to compare. Every later generation must retain it.
if [ ! -e "$current_contract" ]; then
	exit 0
fi
if [ ! -e "$incoming_contract" ]; then
	echo "incoming generation removed the stateful service-placement admission contract" >&2
	exit 1
fi

# shellcheck disable=SC2016 # jq variables must remain literal in this program.
violations="$(${JQ} -cn \
	--slurpfile current "$current_contract" \
	--slurpfile incoming "$incoming_contract" '
    def indexed_placements:
      .placements
      | to_entries
      | map(.key as $scope
          | .value
          | to_entries[]
          | {key: ($scope + ":" + .key),
             value: (.value + {scope: $scope, service: .key})})
      | from_entries;

    ($current[0]) as $current_document
    | ($incoming[0]) as $incoming_document
    | if $current_document.schema_version != 1
         or $incoming_document.schema_version != 1
      then [{reason: "unsupported service-placement admission schema"}]
      else
        ($current_document | indexed_placements) as $before
        | ($incoming_document | indexed_placements) as $after
        | [((($before | keys) + ($after | keys)) | unique[]) as $key
            | ($before[$key] // null) as $old
            | ($after[$key] // null) as $new
            | select(($old.role // null) != ($new.role // null))
            | select(($old.migration_kind // null) == "stateful"
                     or ($new.migration_kind // null) == "stateful")
            | select([
                $incoming_document.moves[]?
                | select(.scope == ($new.scope // $old.scope))
                | select(.services | index($new.service // $old.service))
                | select(
                    (.phase == "adopting-target"
                     and .decision == "complete"
                     and .from == ($old.role // null)
                     and .to == ($new.role // null))
                    or
                    (.phase == "adopting-source"
                     and .decision == "rollback"
                     and .to == ($old.role // null)
                     and .from == ($new.role // null)))
              ] | length != 1)
            | {
                service: $key,
                before: ($old.role // null),
                after: ($new.role // null),
                reason: "stateful placement change has no exact adoption transition"
              }]
      end
  ')"

if ! ${JQ} -e 'length == 0' >/dev/null <<EOF; then
$violations
EOF
	echo "stateful service placement admission failed before host mutation" >&2
	${JQ} -c '.[]' >&2 <<EOF
$violations
EOF
	exit 1
fi
