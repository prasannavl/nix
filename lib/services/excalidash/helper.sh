#!/bin/sh
set -eu

init_vars() {
	: "${EXCALIDASH_BACKEND_DATA_DIR:=/var/lib/abird/excalidash/backend}"
	: "${EXCALIDASH_BACKEND_IMAGE:=docker.io/zimengxiong/excalidash-backend:0.5.1}"
	: "${EXCALIDASH_DATABASE_PROVIDER:=sqlite}"
	: "${EXCALIDASH_DATABASE_URL:=file:/app/prisma/dev.db}"
	: "${EXCALIDASH_DATA_DIR:=/var/lib/abird/excalidash}"
	: "${EXCALIDASH_ENV_FILE:=$EXCALIDASH_DATA_DIR/backend.env}"
	: "${EXCALIDASH_HELPER_PATH:=$0}"
	: "${EXCALIDASH_MIGRATION_LOCK_FILE:=$EXCALIDASH_DATA_DIR/migration.lock}"
}

require_value() {
	name="$1"
	value="$2"

	if [ -z "$value" ]; then
		printf 'missing required value: %s\n' "$name" >&2
		exit 1
	fi
}

ensure_secret() {
	name="$1"
	bytes="$2"

	if grep -q "^${name}=" "$EXCALIDASH_ENV_FILE" 2>/dev/null; then
		if ! grep -q "^${name}=." "$EXCALIDASH_ENV_FILE"; then
			printf 'existing secret is empty: %s\n' "$name" >&2
			return 1
		fi
		return 0
	fi

	secret="$(openssl rand -base64 "$bytes")" || return "$?"
	if [ -z "$secret" ]; then
		printf 'generated secret is empty: %s\n' "$name" >&2
		return 1
	fi
	printf '%s=%s\n' "$name" "$secret" >>"$EXCALIDASH_ENV_FILE"
}

prepare_env() {
	require_value EXCALIDASH_DATA_DIR "$EXCALIDASH_DATA_DIR"
	require_value EXCALIDASH_ENV_FILE "$EXCALIDASH_ENV_FILE"

	umask 077
	mkdir -p "$EXCALIDASH_DATA_DIR"
	touch "$EXCALIDASH_ENV_FILE"
	chmod 0600 "$EXCALIDASH_ENV_FILE"
	ensure_secret JWT_SECRET 48
	ensure_secret CSRF_SECRET 32
}

remove_legacy_migration_lock() {
	legacy_lock_dir=/app/prisma/.migration-lock
	if [ -d "$legacy_lock_dir" ]; then
		if rmdir "$legacy_lock_dir" 2>/dev/null; then
			echo "Removed legacy ExcaliDash migration directory lock: $legacy_lock_dir"
		else
			echo "Refusing to remove non-empty ExcaliDash migration directory lock: $legacy_lock_dir" >&2
			exit 1
		fi
	fi
}

validate_database_provider() {
	database_provider="${DATABASE_PROVIDER:-sqlite}"
	case "$database_provider" in
	sqlite | postgresql)
		;;
	*)
		echo "ERROR: DATABASE_PROVIDER must be 'sqlite' or 'postgresql', got '$database_provider'" >&2
		exit 1
		;;
	esac
}

prepare_prisma_files() {
	mkdir -p /app/prisma
	cp /app/prisma_template/schema.prisma /app/prisma/schema.prisma

	echo "Copying $database_provider migrations..."
	rm -rf /app/prisma/migrations
	mkdir -p /app/prisma/migrations
	cp -R "/app/prisma_template/migrations/$database_provider/." /app/prisma/migrations/

	echo "Configuring Prisma for provider: $database_provider"
	sed -i '/datasource db {/,/}/ s/provider = env("[^"]*")/provider = "'"$database_provider"'"/' /app/prisma/schema.prisma
	sed -i '/datasource db {/,/}/ s/provider = "[^"]*"/provider = "'"$database_provider"'"/' /app/prisma/schema.prisma
}

fix_prisma_permissions() {
	echo "Fixing filesystem permissions..."
	chown -R nodejs:nodejs /app/prisma
	if [ -f /app/prisma/dev.db ]; then
		chmod 600 /app/prisma/dev.db
	fi
}

container_migrate() {
	remove_legacy_migration_lock
	validate_database_provider
	prepare_prisma_files
	fix_prisma_permissions
	echo "Running database migrations..."
	su-exec nodejs npx prisma migrate deploy --schema=/app/prisma/schema.prisma
}

require_migration_inputs() {
	require_value EXCALIDASH_BACKEND_DATA_DIR "$EXCALIDASH_BACKEND_DATA_DIR"
	require_value EXCALIDASH_BACKEND_IMAGE "$EXCALIDASH_BACKEND_IMAGE"
	require_value EXCALIDASH_DATABASE_PROVIDER "$EXCALIDASH_DATABASE_PROVIDER"
	require_value EXCALIDASH_DATABASE_URL "$EXCALIDASH_DATABASE_URL"
	require_value EXCALIDASH_ENV_FILE "$EXCALIDASH_ENV_FILE"
	require_value EXCALIDASH_HELPER_PATH "$EXCALIDASH_HELPER_PATH"
	require_value EXCALIDASH_MIGRATION_LOCK_FILE "$EXCALIDASH_MIGRATION_LOCK_FILE"

	if [ ! -r "$EXCALIDASH_ENV_FILE" ]; then
		printf 'ExcaliDash env file is missing; run prepare-env first: %s\n' "$EXCALIDASH_ENV_FILE" >&2
		exit 1
	fi
}

run_migration_container() {
	require_migration_inputs
	mkdir -p "$EXCALIDASH_DATA_DIR" "$EXCALIDASH_BACKEND_DATA_DIR"

	# run as root: migration chowns /app/prisma; 0.6.5 USER nodejs -> EPERM
	flock -x "$EXCALIDASH_MIGRATION_LOCK_FILE" \
		podman run --rm --pull=missing --network none \
		--user 0 \
		--env-file "$EXCALIDASH_ENV_FILE" \
		-e "DATABASE_PROVIDER=$EXCALIDASH_DATABASE_PROVIDER" \
		-e "DATABASE_URL=$EXCALIDASH_DATABASE_URL" \
		-v "$EXCALIDASH_BACKEND_DATA_DIR:/app/prisma" \
		-v "$EXCALIDASH_HELPER_PATH:/usr/local/bin/excalidash-helper.sh:ro" \
		--entrypoint /bin/sh \
		"$EXCALIDASH_BACKEND_IMAGE" \
		/usr/local/bin/excalidash-helper.sh \
		container-migrate
}

bootstrap() {
	prepare_env
	run_migration_container
}

usage() {
	cat <<'EOF'
Usage: excalidash-helper COMMAND

Commands:
  bootstrap     Prepare runtime secrets and run the one-shot migration phase.
  prepare-env   Create the backend env file and generate durable app secrets.
  migrate       Run database migrations in a short-lived backend container.
  container-migrate
                Internal command run inside the backend image.
EOF
}

main() {
	init_vars
	command="${1-bootstrap}"

	case "$command" in
	bootstrap)
		bootstrap
		;;
	prepare-env)
		prepare_env
		;;
	migrate)
		run_migration_container
		;;
	container-migrate)
		container_migrate
		;;
	help | --help | -h)
		usage
		;;
	*)
		usage >&2
		exit 2
		;;
	esac
}

if [ "${EXCALIDASH_HELPER_NO_MAIN:-0}" != "1" ]; then
	main "$@"
fi
