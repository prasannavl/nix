set -eu

domain="$1"
incoming="$2"
current_system="$3"
mode="$4"
transition="${5:-present}"
authority_evidence="${6:-[]}"

if [ "$domain" != serviceMoves ]; then
	echo "stateful service-placement admission cannot validate projection domain $domain" >&2
	exit 2
fi

case "$mode" in
normal | rollback)
	;;
*)
	echo "unsupported generation admission mode: $mode" >&2
	exit 2
	;;
esac

case "$transition" in
present | removed)
	;;
*)
	echo "unsupported projection domain transition: $transition" >&2
	exit 2
	;;
esac

if ! @JQ@ -e '
  type == "array"
  and (map(.path) | sort) == [
    "desired-resource-states.json",
    "resources.json",
    "service-placement-contract.json"
  ]
  and all(.[];
    (.incoming_sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and ((.current_sha256 == null)
         or (.current_sha256 | type == "string" and test("^[0-9a-f]{64}$"))))
' >/dev/null <<EOF_AUTHORITY; then
$authority_evidence
EOF_AUTHORITY
	echo "stateful service-placement admission received invalid authority evidence" >&2
	exit 1
fi

authority_dir="etc/abird-host-agent"
placement_name="service-placement-contract.json"
desired_name="desired-resource-states.json"
resources_name="resources.json"
incoming_placement="$incoming/$authority_dir/$placement_name"
incoming_desired="$incoming/$authority_dir/$desired_name"
incoming_resources="$incoming/$authority_dir/$resources_name"
current_placement="$current_system/$authority_dir/$placement_name"
current_desired="$current_system/$authority_dir/$desired_name"
current_resources="$current_system/$authority_dir/$resources_name"
current_placement_input="$current_placement"

missing_incoming=""
for authority in "$incoming_placement" "$incoming_desired" "$incoming_resources"; do
	if [ ! -e "$authority" ]; then
		missing_incoming="${missing_incoming}${missing_incoming:+, }${authority##*/}"
	fi
done
if [ -n "$missing_incoming" ]; then
	echo "projection domain $domain is missing incoming authority: $missing_incoming" >&2
	exit 1
fi

current_authority_shape=""
for authority in "$current_placement" "$current_desired" "$current_resources"; do
	if [ -e "$authority" ]; then
		current_authority_shape="${current_authority_shape}1"
	else
		current_authority_shape="${current_authority_shape}0"
	fi
done
case "$current_authority_shape" in
111)
	has_complete_current=true
	;;
000)
	has_complete_current=false
	current_placement_input=/dev/null
	;;
*)
	echo "projection domain $domain has invalid partial current authority" >&2
	exit 1
	;;
esac
if [ "$mode" = rollback ] && [ "$has_complete_current" != true ]; then
	echo "projection domain $domain rollback requires complete current authority" >&2
	exit 1
fi

# shellcheck disable=SC2016 # jq variables must remain literal in this program.
placement_violations="$(@JQ@ -cn \
	--arg mode "$mode" \
	--argjson has_current "$has_complete_current" \
	--slurpfile incoming "$incoming_placement" \
	--slurpfile current "$current_placement_input" '
    def indexed_placements:
      .placements
      | to_entries
      | map(.key as $scope
          | .value
          | to_entries[]
          | {key: ($scope + ":" + .key),
             value: (.value + {scope: $scope, service: .key})})
      | from_entries;

    def valid_document:
      (keys == ["moves", "placements", "predecessors", "schema_version"])
      and .schema_version == 3
      and (.placements | type == "object")
      and (.moves | type == "object")
      and .predecessors == {
        "1": {scope_aliases: {}},
        "2": {scope_aliases: {}}
      };

    def move_for_service($move; $scope; $service):
      select($move.scope == $scope)
      | $move.items[]
      | select(.service == $service)
      | $move + {
          service: .service,
          from: .from,
          to: .to,
          basis_sha256: .basis_sha256
        };

    def valid_lock($move):
      (($move.basis_sha256 // "") | test("^[0-9a-f]{64}$"))
      and (($move.semantic_sha256 // "") | test("^[0-9a-f]{64}$"));

    def forward_adoptions($document; $old; $new):
      [$document.moves[]? as $move
       | move_for_service($move; ($new.scope // $old.scope); ($new.service // $old.service))
       | select(valid_lock(.))
       | select(
           (.phase == "adopting-target"
            and .decision == "complete"
            and .from == ($old.role // null)
            and .to == ($new.role // null))
           or
           (.phase == "adopting-source"
            and .decision == "rollback"
            and .to == ($old.role // null)
            and .from == ($new.role // null)))];

    def rollback_predecessors($current_document; $incoming_document; $old; $new):
      [$current_document.moves[]? as $current_move
       | move_for_service($current_move; ($new.scope // $old.scope); ($new.service // $old.service)) as $adoption
       | select(valid_lock($adoption))
       | select($adoption.phase == "adopting-target"
                and $adoption.decision == "complete"
                and $adoption.from == ($new.role // null)
                and $adoption.to == ($old.role // null))
       | $incoming_document.moves[]? as $incoming_move
       | move_for_service($incoming_move; ($new.scope // $old.scope); ($new.service // $old.service)) as $predecessor
       | select(valid_lock($predecessor))
       | select($predecessor.phase == "target-active"
                and ($predecessor.decision // null) == null
                and $predecessor.from == $adoption.from
                and $predecessor.to == $adoption.to
                and $predecessor.projection_sha256 == $adoption.projection_sha256
                and $predecessor.basis_sha256 == $adoption.basis_sha256
                and $predecessor.semantic_sha256 == $adoption.semantic_sha256)];

    ($incoming[0]) as $incoming_document
    | if ($incoming_document | valid_document | not)
      then [{reason: "invalid or unsupported incoming service-placement admission contract"}]
      elif $has_current | not
      then []
      else
        ($current[0]) as $current_document
        | if ($current_document | valid_document | not)
          then [{reason: "invalid or unsupported current service-placement admission contract"}]
          else
            ($current_document | indexed_placements) as $before
            | ($incoming_document | indexed_placements) as $after
            | [((($before | keys) + ($after | keys)) | unique[]) as $key
                | ($before[$key] // null) as $old
                | ($after[$key] // null) as $new
                | if (($old.migration_kind // null) == "stateful"
                      and ($new.migration_kind // null) != "stateful")
                  then {
                    service: $key,
                    before: ($old.migration_kind // null),
                    after: ($new.migration_kind // null),
                    reason: "established stateful placement classification changed or disappeared"
                  }
                  elif ($old != null
                        and $new != null
                        and ($old.role // null) != ($new.role // null)
                        and (($old.migration_kind // null) == "stateful"
                             or ($new.migration_kind // null) == "stateful")
                        and (if $mode == "rollback"
                             then (rollback_predecessors($current_document; $incoming_document; $old; $new) | length != 1)
                             else (forward_adoptions($incoming_document; $old; $new) | length != 1)
                             end))
                  then {
                    service: $key,
                    before: ($old.role // null),
                    after: ($new.role // null),
                    reason: (if $mode == "rollback"
                             then "stateful placement rollback has no exact deployed predecessor"
                             else "stateful placement change has no exact adoption transition"
                             end)
                  }
                  else empty
                  end]
          end
      end
  ')"

if ! @JQ@ -e 'length == 0' >/dev/null <<EOF_VIOLATIONS; then
$placement_violations
EOF_VIOLATIONS
	echo "stateful service placement admission failed before host mutation" >&2
	@JQ@ -c '.[]' >&2 <<EOF_VIOLATIONS
$placement_violations
EOF_VIOLATIONS
	exit 1
fi

if [ "$mode" = rollback ]; then
	set -- --require-complete-authority
else
	set --
fi
resource_admission="$(@HOST_AGENT@ \
	--json \
	--resource-manifest "$incoming_resources" \
	_reconcile desired-resource-states \
	--manifest "$incoming_desired" \
	--preflight-only \
	"$@")"

# shellcheck disable=SC2016 # jq variables must remain literal in this program.
if ! @JQ@ -e --slurpfile desired "$incoming_desired" '
  .ok == true
  and .operation == "desired_resource_states_preflight"
  and (.result.count | type == "number")
  and (.result.deferred_held | type == "number")
  and (.result.resources | type == "array")
  and .result.count == (.result.resources | length)
  and .result.count == ($desired[0].resources | length)
  and .result.deferred_held
      == ([.result.resources[] | select(.outcome == "deferred_held")] | length)
  and ((.result.resources | map(.resource) | sort)
       == ($desired[0].resources | map(.id) | sort))
  and all(.result.resources[];
    (.resource | type == "string")
    and (.outcome == "converge"
         or (.outcome == "deferred_held"
             and (.reason | type == "string")
             and (.detail | type == "string"))))
' >/dev/null <<EOF_ADMISSION; then
$resource_admission
EOF_ADMISSION
	echo "host-agent desired-resource preflight returned an invalid result" >&2
	exit 1
fi

# shellcheck disable=SC2016 # jq variables must remain literal in this program.
@JQ@ -cn \
	--arg domain "$domain" \
	--arg host "@HOST@" \
	--arg mode "$mode" \
	--arg transition "$transition" \
	--argjson authority_evidence "$authority_evidence" \
	--slurpfile desired "$incoming_desired" \
	--argjson admission "$resource_admission" '
  ($desired[0].resources
   | map({key: .id, value: .})
   | from_entries) as $desired_by_id
  | [$admission.result.resources[]
     | select(.outcome == "deferred_held")
     | . as $result
     | $desired_by_id[$result.resource] as $desired_resource
     | {
         kind: "resource-deferred",
         domain: "desired-resource-state",
         host: $host,
         transaction_id: ($desired_resource.transaction_id // $desired_resource.projection_id),
         projection_id: $desired_resource.projection_id,
         resource: $result.resource,
         status: "deferred-held",
         state: $desired_resource.state,
         generation: $desired_resource.generation,
         reason: $result.reason,
         detail: $result.detail
       }] as $deferred
  | {
      ok: true,
      operation: "projection_domain_admission",
      result: {
        schema_version: 1,
        domain: $domain,
        adapter: "stateful-service-placement",
        mode: $mode,
        transition: $transition,
        host: $host,
        authority: $authority_evidence,
        checks: [
          {domain: "service-placement", status: "admitted"},
          {
            domain: "desired-resource-state",
            status: "admitted",
            deferred_count: ($deferred | length)
          }
        ],
        evidence: $deferred,
        deferred_resources: {
          count: ($deferred | length),
          resources: $deferred
        }
      }
    }
'
