#!/usr/bin/env bash
set -Eeuo pipefail

# Opt-in: ./tests/cache-relay-smoke.sh (non-root Linux, user namespaces, ip,
# OpenSSH client/server, Nix, OpenSSL, Python 3). No downloads or host store.
smoke() {
	set -Eeuo pipefail
	umask 077
	[[ $PWD =~ ^/[a-zA-Z0-9._/-]+$ && ${#PWD} -lt 90 ]] || { echo 'set TMPDIR to a short, URI-safe directory' >&2; return 1; }
	ip link set lo up
	export NIX_CONF_DIR="$PWD" NIX_USER_CONF_FILES=/dev/null NIX_REMOTE="local?root=$PWD/src"
	export NIX_CONFIG=$'experimental-features = nix-command\nsubstituters =\nbuild-users-group =\ndownload-attempts = 1\nrequire-sigs = true\ntrusted-public-keys ='
	local i path sock ssh_pid url http=http://localhost:18080 https=https://localhost:18443 dst="local?root=$PWD/dst"
	# Input-addressed: unlike `store add-file`, this output MUST pass signature checks.
	path=$(nix build --impure --no-link --print-out-paths --expr 'derivation {
	  name="relay-smoke"; system=builtins.currentSystem; builder="builtin:buildenv";
	  derivations=""; manifest=builtins.toFile "manifest.nix" "relay-smoke"; }')
	nix-store --generate-binary-cache-key relay-1 signing.key signing.pub
	nix copy --to "file://$PWD/cache?secret-key=$PWD/signing.key" "$path"

	export NIX_SSL_CERT_FILE="$PWD/cert.pem"
	openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=localhost \
		-addext subjectAltName=DNS:localhost -keyout tls.key -out cert.pem
	python3 - <<'PY' &
import http.server, os, ssl, threading
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain('cert.pem', 'tls.key')
os.chdir('cache')
for port in (18080, 18443):
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', port), http.server.SimpleHTTPRequestHandler)
    if port == 18443:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
open('../cache.ready', 'x').close()
threading.Event().wait()
PY
	ssh-keygen -q -t ed25519 -N '' -f host
	ssh-keygen -q -t ed25519 -N '' -f client
	printf '[127.0.0.1]:18222 %s\n' "$(<host.pub)" >known
	"$(command -v sshd)" -D -e -f /dev/null -p 18222 -h "$PWD/host" -o ListenAddress=127.0.0.1 \
		-o "AuthorizedKeysFile=$PWD/client.pub" -o 'AuthenticationMethods=publickey' -o UsePAM=no \
		-o StrictModes=no -o "PidFile=$PWD/sshd.pid" -o 'PermitOpen=localhost:18080 localhost:18443' &
	sock="$PWD/s"
	ssh -F /dev/null -NT -S none -o ExitOnForwardFailure=yes -D "$sock" \
		-p 18222 -o ConnectionAttempts=5 -o BatchMode=yes -i client -o IdentitiesOnly=yes \
		-o UserKnownHostsFile=./known -o GlobalKnownHostsFile=/dev/null -o StrictHostKeyChecking=yes 127.0.0.1 &
	ssh_pid=$!
	for ((i = 0; i < 100; i++)); do [[ -S $sock && -f cache.ready ]] && break; kill -0 "$ssh_pid"; sleep 0.05; done
	[[ -S $sock && -f cache.ready ]]
	export http_proxy="socks5h://localhost${sock}" https_proxy="socks5h://localhost${sock}" no_proxy='' NO_PROXY=''
	nix path-info --store "$http" "$path"
	if nix copy --from "$https" --to "$dst" "$path" 2>untrusted.log; then echo 'untrusted signature accepted' >&2; return 1; fi
	grep -F 'signature by a trusted key' untrusted.log
	nix copy --option trusted-public-keys "$(<signing.pub)" --from "$https" --to "$dst" "$path"
	nix store verify --option trusted-public-keys "$(<signing.pub)" --recursive --store "$dst" "$path"
	kill "$ssh_pid"; wait "$ssh_pid" || :
	for url in "$http" "$https"; do
		if XDG_CACHE_HOME="$PWD/cold" nix path-info --store "$url" "$path" 2>stopped.log; then echo 'tunnel bypassed' >&2; return 1; fi
		grep -F "over proxy $sock" stopped.log
	done
	echo 'PASS: signed cache via private SOCKS; untrusted key and stopped relay rejected'
}

main() {
	# Namespace init exiting kills all descendants even on failure. TemporaryDirectory
	# owns the fresh 0700 directory; no recursive deletion of shell-computed paths.
	((EUID != 0)) || { echo 'run as a non-root user' >&2; return 1; }
	python3 -c '
import os, subprocess, sys, tempfile
with tempfile.TemporaryDirectory(prefix="relay-") as work:
    sys.exit(subprocess.call(sys.argv[1:], cwd=work, env=dict(PATH=os.environ["PATH"], HOME=work, TMPDIR=work)))
' timeout -k 3 60 unshare --map-current-user --keep-caps --net --pid --mount-proc --fork --kill-child \
		bash -c "$(declare -f smoke); smoke"
}

main "$@"
