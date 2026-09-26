model_reconciler_read_worker_status() {
	local worker_unit="$1" status key value

	if ! status="$(systemctl --user show \
		--property=ActiveState \
		--property=SubState \
		--property=Result \
		--property=Job \
		"$worker_unit" 2>/dev/null)"; then
		return 1
	fi

	MODEL_RECONCILER_WORKER_ACTIVE_STATE=""
	MODEL_RECONCILER_WORKER_SUB_STATE=""
	MODEL_RECONCILER_WORKER_RESULT=""
	MODEL_RECONCILER_WORKER_JOB=""
	MODEL_RECONCILER_WORKER_JOB_KNOWN=false
	while IFS='=' read -r key value; do
		case "$key" in
		ActiveState) MODEL_RECONCILER_WORKER_ACTIVE_STATE="$value" ;;
		SubState) MODEL_RECONCILER_WORKER_SUB_STATE="$value" ;;
		Result) MODEL_RECONCILER_WORKER_RESULT="$value" ;;
		Job)
			MODEL_RECONCILER_WORKER_JOB="$value"
			MODEL_RECONCILER_WORKER_JOB_KNOWN=true
			;;
		esac
	done <<<"$status"

	[ -n "$MODEL_RECONCILER_WORKER_ACTIVE_STATE" ] &&
		[ -n "$MODEL_RECONCILER_WORKER_SUB_STATE" ] &&
		[ -n "$MODEL_RECONCILER_WORKER_RESULT" ] &&
		[ "$MODEL_RECONCILER_WORKER_JOB_KNOWN" = true ]
}

model_reconciler_dispatch_worker() {
	local operation="$1" worker_unit="$2" poll_deadline

	systemctl --user reset-failed "$worker_unit" >/dev/null 2>&1 || true
	systemctl --user restart --no-block "$worker_unit"

	poll_deadline="$(($(date +%s) + 10))"
	while [ "$(date +%s)" -lt "$poll_deadline" ]; do
		if ! model_reconciler_read_worker_status "$worker_unit"; then
			echo "$operation: cannot inspect worker during dispatch" >&2
			return 1
		fi

		# restart is one queued stop/start transaction. The stopped invocation can
		# transiently report failed/signal while its replacement is still queued.
		# Judge terminal state only after systemd has completed that transaction.
		if [ -n "$MODEL_RECONCILER_WORKER_JOB" ]; then
			sleep 1
			continue
		fi

		case "$MODEL_RECONCILER_WORKER_ACTIVE_STATE:$MODEL_RECONCILER_WORKER_RESULT" in
		failed:*)
			printf '%s: worker failed during dispatch (state=%s sub=%s result=%s)\n' \
				"$operation" \
				"$MODEL_RECONCILER_WORKER_ACTIVE_STATE" \
				"$MODEL_RECONCILER_WORKER_SUB_STATE" \
				"$MODEL_RECONCILER_WORKER_RESULT" >&2
			return 1
			;;
		inactive:success)
			echo "$operation: worker completed during dispatch"
			return
			;;
		activating:* | active:* | deactivating:* | reloading:*)
			sleep 1
			continue
			;;
		esac

		printf '%s: worker entered unexpected state during dispatch (state=%s sub=%s result=%s)\n' \
			"$operation" \
			"$MODEL_RECONCILER_WORKER_ACTIVE_STATE" \
			"$MODEL_RECONCILER_WORKER_SUB_STATE" \
			"$MODEL_RECONCILER_WORKER_RESULT" >&2
		return 1
	done

	echo "$operation: worker accepted; continuing asynchronously"
}
