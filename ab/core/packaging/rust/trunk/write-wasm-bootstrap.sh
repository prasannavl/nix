#!/usr/bin/env bash
set -Eeuo pipefail

# Trunk's default WASM startup is an inline module script, which strict CSP
# blocks. With inject_scripts=false, patch the generated wasm-bindgen loader so
# it starts itself, then rewrite index.html to load that hashed external module.
main() {
	local staging_dir="${TRUNK_STAGING_DIR:?TRUNK_STAGING_DIR is required}"
	local target_name="${TRUNK_WASM_BOOTSTRAP_TARGET:-}"
	local placeholder="${TRUNK_WASM_BOOTSTRAP_OUTPUT:-bootstrap.js}"
	local event_name="${TRUNK_WASM_BOOTSTRAP_EVENT:-TrunkApplicationStarted}"

	local wasm_pattern="*_bg.wasm"
	local expected="*_bg.wasm"
	if [ -n "$target_name" ]; then
		wasm_pattern="${target_name}-*_bg.wasm"
		expected="$wasm_pattern"
	fi

	local -a wasm_files=()
	mapfile -t wasm_files < <(
		find "$staging_dir" -maxdepth 1 -type f -name "$wasm_pattern" -printf '%f\n' | sort
	)

	if [ "${#wasm_files[@]}" -ne 1 ]; then
		printf 'expected exactly one %s in %s, found %s\n' "$expected" "$staging_dir" "${#wasm_files[@]}" >&2
		printf '%s\n' "${wasm_files[@]}" >&2
		return 1
	fi

	local wasm="${wasm_files[0]}"
	local js="${wasm%_bg.wasm}.js"
	local js_path="$staging_dir/$js"
	local js_tmp="$js_path.tmp"

	if [ ! -f "$js_path" ]; then
		printf 'missing wasm-bindgen loader: %s\n' "$js_path" >&2
		return 1
	fi

	cp "$js_path" "$js_tmp"
	cat >>"$js_tmp" <<EOF

const __trunkWasm = await __wbg_init({ module_or_path: "./$wasm" });

dispatchEvent(new CustomEvent("$event_name", { detail: { wasm: __trunkWasm } }));
EOF

	local hash
	hash="$(sha256sum "$js_tmp" | cut -c1-16)"

	local patched_js="${js%.js}-${hash}.js"
	mv "$js_tmp" "$staging_dir/$patched_js"
	rm "$js_path"

	local index="$staging_dir/index.html"
	if [ ! -f "$index" ]; then
		printf 'missing Trunk index output: %s\n' "$index" >&2
		return 1
	fi

	local needle="${placeholder//./\\.}"
	local replacement="${patched_js//&/\\&}"
	sed -i \
		-e "s#src=\"/$needle\"#src=\"/$replacement\"#g" \
		-e "s#src=\"\\./$needle\"#src=\"./$replacement\"#g" \
		-e "s#src=\"$needle\"#src=\"$replacement\"#g" \
		"$index"

	if ! grep -q "$patched_js" "$index"; then
		printf 'failed to update %s to reference %s\n' "$index" "$patched_js" >&2
		return 1
	fi
}

main "$@"
