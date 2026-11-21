#!/usr/bin/env bash
set -Eeuo pipefail

main() {
	cat <<'EOF'
This image is a normal NixOS live installer, so generic/manual installs
are still possible, but the one-command fully-offline path only exists
for bundled targets listed by:

  offline-install --list

For a generic manual install:

  1. Partition, format, and mount the target at /mnt.
  2. Run nixos-generate-config --root /mnt.
  3. Edit /mnt/etc/nixos/configuration.nix.
  4. Run nixos-install.

That generic path may need network access unless the configuration only
references closures already present in this ISO.
EOF
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
