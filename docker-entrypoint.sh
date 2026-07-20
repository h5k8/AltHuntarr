#!/usr/bin/env sh
set -eu

config_path="${ALTHUNTARR_CONFIG:-/config/config.json}"
secrets_path="${ALTHUNTARR_SECRETS:-/config/secrets.json}"
interval="${ALTHUNTARR_INTERVAL:-900}"
run_once="${ALTHUNTARR_RUN_ONCE:-false}"
puid="${PUID:-99}"
pgid="${PGID:-100}"
dry_run="${ALTHUNTARR_DRY_RUN:-false}"
sonarr_url="${ALTHUNTARR_SONARR_URL:-}"
radarr_url="${ALTHUNTARR_RADARR_URL:-}"

normalize_boolean() {
    case "$2" in
        1|true|TRUE|yes|YES) printf 'true' ;;
        0|false|FALSE|no|NO) printf 'false' ;;
        *)
            printf 'ERROR: %s must be true or false.\n' "$1" >&2
            exit 2
            ;;
    esac
}

validate_url_override() {
        if ! jq -en --arg url "$2" '
            (($url | contains("\"") or contains("\n") or contains("\r")) | not)
      and ($url | test("^https?://[^/?#@]+(:[0-9]+)?(/[^?#]*)?$"))
      and ($url | contains("/api/v3") | not)
    ' >/dev/null; then
        printf 'ERROR: %s must be an http(s) base URL without credentials, query, fragment, or /api/v3.\n' "$1" >&2
        exit 2
    fi
}

sync_environment_configuration() {
    local dry_run_json
    dry_run_json="$(normalize_boolean ALTHUNTARR_DRY_RUN "$dry_run")"

    [ -z "$sonarr_url" ] || validate_url_override ALTHUNTARR_SONARR_URL "$sonarr_url"
    [ -z "$radarr_url" ] || validate_url_override ALTHUNTARR_RADARR_URL "$radarr_url"
    sonarr_url="${sonarr_url%/}"
    radarr_url="${radarr_url%/}"

    for app in sonarr radarr; do
        case "$app" in
            sonarr) url="$sonarr_url" ;;
            radarr) url="$radarr_url" ;;
        esac
        [ -n "$url" ] || continue
        count="$(jq -r --arg app "$app" '[.instances[] | select(.type == $app)] | length' "$config_path")" || {
            printf 'ERROR: cannot read instances from %s.\n' "$config_path" >&2
            exit 2
        }
        if [ "$count" != "1" ]; then
            printf 'ERROR: ALTHUNTARR_%s_URL requires exactly one %s instance in config.json; found %s. Leave it blank for multiple instances.\n' "$(printf '%s' "$app" | tr '[:lower:]' '[:upper:]')" "$app" "$count" >&2
            exit 2
        fi
    done

    config_dir="$(dirname "$config_path")"
    temporary="$(mktemp "$config_dir/.config.json.XXXXXX")" || exit 2
        if ! jq --arg sonarr "$sonarr_url" --arg radarr "$radarr_url" --argjson dry_run "$dry_run_json" '
            .general.dry_run = $dry_run
            | .instances |= map(
                    if .type == "sonarr" and $sonarr != "" then .url = $sonarr
                    elif .type == "radarr" and $radarr != "" then .url = $radarr
                    else . end
                )
    ' "$config_path" >"$temporary"; then
        rm -f "$temporary"
        printf 'ERROR: cannot apply URL overrides to %s.\n' "$config_path" >&2
        exit 2
    fi
    chmod 600 "$temporary"
    if cmp -s "$temporary" "$config_path"; then
        rm -f "$temporary"
    else
        mv -f "$temporary" "$config_path"
    fi
}

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
        sync_environment_configuration
        chmod 600 "$config_path"
        chown "$puid:$pgid" "$config_path"
        printf 'Created configuration at %s; continuing with the configured environment values.\n' "$config_path" >&2
    fi

    if [ "${1:-}" != "healthcheck" ]; then
        sync_environment_configuration
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
