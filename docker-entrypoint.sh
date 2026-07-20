#!/usr/bin/env sh
set -eu

config_path="${ALTHUNTARR_CONFIG:-/config/config.json}"
secrets_path="${ALTHUNTARR_SECRETS:-/config/secrets.json}"
interval="${ALTHUNTARR_INTERVAL:-900}"
run_once="${ALTHUNTARR_RUN_ONCE:-false}"
puid="${PUID:-99}"
pgid="${PGID:-100}"

validate_id() {
    case "$2" in
        ''|*[!0-9]*) printf 'ERROR: %s must be a numeric ID.\n' "$1" >&2; exit 2 ;;
    esac
}

if [ "$(id -u)" = "0" ]; then
    validate_id PUID "$puid"
    validate_id PGID "$pgid"
    mkdir -p /config /data/state /data/logs

    if [ ! -f "$config_path" ]; then
        cp /usr/share/althuntarr/config.example.json "$config_path"
        chmod 600 "$config_path"
        chown "$puid:$pgid" "$config_path"
        printf 'Created example configuration at %s. Edit it, then restart the container.\n' "$config_path" >&2
        exit 3
    fi

    chown -R "$puid:$pgid" /config /data
    chmod 700 /config /data/state /data/logs

    if [ "${1:-}" = "healthcheck" ]; then
        su-exec "$puid:$pgid" test -r "$config_path"
        su-exec "$puid:$pgid" test -w /data/state
        su-exec "$puid:$pgid" test -w /data/logs
        exit 0
    fi

    exec su-exec "$puid:$pgid" "$0" "$@"
fi

if [ ! -f "$config_path" ]; then
    printf 'ERROR: configuration not found: %s\n' "$config_path" >&2
    printf 'Run the container as root with PUID/PGID for first-run setup, or create config.json manually.\n' >&2
    exit 3
fi

if [ "${1:-}" = "healthcheck" ]; then
    test -r "$config_path" && test -w /data/state && test -w /data/logs
    exit $?
fi

set -- /usr/local/bin/altHuntarrrscript.sh --config "$config_path"
if [ -f "$secrets_path" ]; then set -- "$@" --secrets "$secrets_path"; fi
case "${ALTHUNTARR_DRY_RUN:-false}" in 1|true|TRUE|yes|YES) set -- "$@" --dry-run ;; esac
case "${ALTHUNTARR_SHOW_CANDIDATES:-false}" in 1|true|TRUE|yes|YES) set -- "$@" --show-candidates ;; esac
if [ -n "${ALTHUNTARR_APP:-}" ]; then set -- "$@" --app "$ALTHUNTARR_APP"; fi
if [ -n "${ALTHUNTARR_INSTANCE:-}" ]; then set -- "$@" --instance "$ALTHUNTARR_INSTANCE"; fi
if [ -n "${ALTHUNTARR_MODE:-}" ]; then set -- "$@" --mode "$ALTHUNTARR_MODE"; fi
if [ -n "${ALTHUNTARR_LOG_LEVEL:-}" ]; then set -- "$@" --log-level "$ALTHUNTARR_LOG_LEVEL"; fi

case "$run_once" in 1|true|TRUE|yes|YES) exec "$@" --once ;; esac
case "$interval" in
    ''|*[!0-9]*) printf 'ERROR: ALTHUNTARR_INTERVAL must be a positive integer.\n' >&2; exit 2 ;;
    0) printf 'ERROR: ALTHUNTARR_INTERVAL must be greater than zero.\n' >&2; exit 2 ;;
esac

exec "$@" --loop --interval "$interval"
