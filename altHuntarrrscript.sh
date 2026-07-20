#!/usr/bin/env bash
# altHuntarrrscript - safe one-shot Sonarr/Radarr v3 search orchestrator.
# Requires Bash 4.3+, curl, jq, flock, GNU date, mktemp, shuf, sha256sum.

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="0.1.0"
readonly API_PREFIX="/api/v3"
readonly EXIT_ARGS=2 EXIT_CONFIG=3 EXIT_DEPS=4 EXIT_LOCK=5
readonly EXIT_UNREACHABLE=6 EXIT_PARTIAL=7 EXIT_STATE=8 EXIT_DRY_FOUND=9 EXIT_SECURITY=10

CONFIG_PATH=""
SECRETS_PATH=""
APP_FILTER="all"
INSTANCE_FILTER=""
MODE_FILTER="both"
LOOP_MODE=0
INTERVAL_SECONDS=900
CLI_DRY_RUN=0
HEALTH_CHECK=0
SHOW_CANDIDATES=0
RESET_STATE=""
JSON_SUMMARY=0
CLI_LOG_LEVEL=""
STATE_DIR=""
LOG_DIR=""
STATE_FILE=""
COUNTER_FILE=""
LOCK_FILE=""
LOG_FILE=""
RUNS_FILE=""
LOCK_FD=""
RUN_RESULTS_FILE=""
RUN_ID=""
RUN_STARTED=""
RUN_EXIT=0
DRY_RUN=0
VERIFY_TLS=1
REQUEST_TIMEOUT=120
CONNECT_TIMEOUT=10
RETRY_COUNT=2
RETRY_DELAY=3
SELECTION="random"
STATE_TTL_HOURS=168
PAGE_SIZE=100
LOG_LEVEL="info"
CURRENT_NAME=""
CURRENT_TYPE=""
CURRENT_URL=""
CURRENT_API_KEY=""
CURRENT_INSTANCE_ID=""
CURRENT_QUEUE_LIMIT=-1
CURRENT_HOURLY_CAP=-1
CURRENT_INSTANCE_JSON=""
ARR_RESPONSE=""
ARR_HTTP=0
ARR_ERROR=""
ANY_REACHABLE=0
ANY_FAILURE=0
DRY_FOUND=0

usage() {
    cat <<'EOF'
Usage: altHuntarrrscript.sh --config PATH [options]

Options:
  --config PATH             Configuration file (required)
  --secrets PATH            Optional secrets JSON file
  --app sonarr|radarr|all   Limit application type
  --instance NAME           Limit to a configured instance name
  --mode missing|upgrade|both
  --once                    Run one cycle and exit (default)
  --loop                    Repeat cycles
  --interval SECONDS        Loop delay; valid with --loop
  --dry-run                 Fetch/select but never POST a command
  --health-check            Validate configuration and connectivity only
  --reset-state [expired|all]
  --show-candidates         Print selected candidates
  --log-level LEVEL         error|warn|info|debug
  --json-summary            Print the final run summary as JSON
  --version
  --help
EOF
}

log_level_value() { case "$1" in error) echo 0 ;; warn) echo 1 ;; info) echo 2 ;; debug) echo 3 ;; *) return 1 ;; esac }
utc_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
utc_epoch() { date -u +%s; }
utc_hour() { date -u +%Y-%m-%dT%H; }

log() {
    local level="$1"
    shift
    local required current line upper_level
    required="$(log_level_value "$level")" || return 0
    current="$(log_level_value "$LOG_LEVEL")" || current=2
    ((required <= current)) || return 0
    upper_level="$(printf '%s' "$level" | tr '[:lower:]' '[:upper:]')"
    line="$(utc_iso) ${upper_level} run=${RUN_ID:-bootstrap} $*"
    printf '%s\n' "$line" >&2
    [[ -z "$LOG_FILE" ]] || printf '%s\n' "$line" >>"$LOG_FILE"
}

die() {
    local code="$1"
    shift
    log error "message=$(printf '%q' "$*")"
    exit "$code"
}

parse_args() {
    while (($#)); do
        case "$1" in
        --config | --secrets | --app | --instance | --mode | --interval | --log-level)
            [[ $# -ge 2 ]] || die "$EXIT_ARGS" "$1 requires a value"
            case "$1" in
            --config) CONFIG_PATH="$2" ;; --secrets) SECRETS_PATH="$2" ;;
            --app) APP_FILTER="$2" ;; --instance) INSTANCE_FILTER="$2" ;;
            --mode) MODE_FILTER="$2" ;; --interval) INTERVAL_SECONDS="$2" ;;
            --log-level) CLI_LOG_LEVEL="$2" ;;
            esac
            shift 2
            ;;
        --once)
            LOOP_MODE=0
            shift
            ;;
        --loop)
            LOOP_MODE=1
            shift
            ;;
        --dry-run)
            CLI_DRY_RUN=1
            shift
            ;;
        --health-check)
            HEALTH_CHECK=1
            shift
            ;;
        --show-candidates)
            SHOW_CANDIDATES=1
            shift
            ;;
        --json-summary)
            JSON_SUMMARY=1
            shift
            ;;
        --reset-state)
            RESET_STATE="expired"
            if [[ ${2-} == "expired" || ${2-} == "all" ]]; then
                RESET_STATE="$2"
                shift
            fi
            shift
            ;;
        --version)
            printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
            exit 0
            ;;
        --help | -h)
            usage
            exit 0
            ;;
        *) die "$EXIT_ARGS" "Unknown argument: $1" ;;
        esac
    done
    [[ -n "$CONFIG_PATH" ]] || die "$EXIT_ARGS" "--config is required"
    [[ "$APP_FILTER" =~ ^(all|sonarr|radarr)$ ]] || die "$EXIT_ARGS" "Invalid --app value"
    [[ "$MODE_FILTER" =~ ^(both|missing|upgrade)$ ]] || die "$EXIT_ARGS" "Invalid --mode value"
    [[ "$INTERVAL_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "$EXIT_ARGS" "--interval must be positive"
    [[ -z "$CLI_LOG_LEVEL" ]] || log_level_value "$CLI_LOG_LEVEL" >/dev/null || die "$EXIT_ARGS" "Invalid log level"
}

validate_dependencies() {
    local command missing=()
    for command in curl jq flock date mktemp awk sed sort head wc shuf sha256sum; do
        command -v "$command" >/dev/null 2>&1 || missing+=("$command")
    done
    if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3))); then missing+=("Bash>=4.3"); fi
    ((${#missing[@]} == 0)) || {
        printf 'Missing dependencies: %s\n' "${missing[*]}" >&2
        exit "$EXIT_DEPS"
    }
}

permissions_mode() { stat -c '%a' "$1"; }
assert_secret_permissions() {
    local path="$1" mode
    [[ -f "$path" ]] || die "$EXIT_CONFIG" "File does not exist: $path"
    mode="$(permissions_mode "$path")" || die "$EXIT_SECURITY" "Could not inspect permissions: $path"
    (((8#$mode & 0077) == 0)) || die "$EXIT_SECURITY" "File must not be accessible by group or others: $path (mode $mode)"
}

normalize_base_url() {
    local url="$1"
    [[ "$url" != *'"'* && "$url" != *$'\n'* && "$url" != *$'\r'* ]] || return 1
    [[ "$url" =~ ^https?://[^/?#@]+(:[0-9]+)?(/[^?#]*)?$ ]] || return 1
    [[ "$url" != *"/api/v3" && "$url" != *"/api/v3/" ]] || return 1
    printf '%s' "${url%/}"
}

validate_config_schema() {
    local errors
    errors="$(jq -r '
      def integer: type == "number" and floor == .;
      def nonnegative: integer and . >= 0;
      def cap: integer and . >= -1;
      def bool: type == "boolean";
      def operation: type == "object" and (.enabled | bool) and (.batch_size | nonnegative);
      def instance:
        type == "object" and (.name | type == "string" and length > 0)
        and (.type == "sonarr" or .type == "radarr") and (.enabled | bool)
        and (.url | type == "string" and test("^https?://") and (contains("/api/v3") | not))
        and ((.api_key_env? // .api_key_file? // .secret_ref? // .api_key?) | type == "string" and length > 0)
        and (.missing | operation) and (.upgrade | operation)
        and (.monitored_only | bool) and (.skip_future | bool)
        and (.hourly_search_cap | cap) and (.max_download_queue_size | cap)
        and ((.queue_error_policy? // "skip") | . == "skip" or . == "continue")
        and (if .type == "sonarr" then ((.missing.mode? // "episodes") == "episodes") and ((.upgrade.mode? // "episodes") == "episodes") else true end)
        and (if .type == "radarr" then ((.future_release_date? // "digital") | . == "digital" or . == "physical" or . == "cinema") else true end);
      if type != "object" then "top-level configuration must be an object"
      elif .version != 1 then "unsupported or missing version (expected 1)"
      elif (.general | type) != "object" then "general must be an object"
      elif (.general.state_dir | type) != "string" or (.general.state_dir | length) == 0 then "general.state_dir is required"
      elif (.general.log_dir | type) != "string" or (.general.log_dir | length) == 0 then "general.log_dir is required"
      elif ((.general.selection // "random") | . != "random" and . != "sequential") then "general.selection must be random or sequential"
      elif ((.general.candidate_strategy // "full") | . != "full") then "only candidate_strategy=full is supported"
      elif ((.general.state_ttl_hours // 168) | nonnegative | not) then "general.state_ttl_hours must be a nonnegative integer"
      elif ((.general.request_timeout_seconds // 120) | nonnegative | not) then "general.request_timeout_seconds must be a nonnegative integer"
      elif ((.general.connect_timeout_seconds // 10) | nonnegative | not) then "general.connect_timeout_seconds must be a nonnegative integer"
      elif ((.general.retry_count // 2) | nonnegative | not) then "general.retry_count must be a nonnegative integer"
      elif ((.general.retry_delay_seconds // 3) | nonnegative | not) then "general.retry_delay_seconds must be a nonnegative integer"
      elif ((.general.page_size // 100) | nonnegative | not) then "general.page_size must be a nonnegative integer"
      elif ((.general.verify_tls // true) | bool | not) then "general.verify_tls must be boolean"
      elif ((.general.dry_run // false) | bool | not) then "general.dry_run must be boolean"
      elif ((.general.log_level // "info") | . != "error" and . != "warn" and . != "info" and . != "debug") then "general.log_level is invalid"
      elif (.instances | type) != "array" or length == 0 then "instances must be a non-empty array"
      elif (all(.instances[]; instance) | not) then "one or more instances are invalid"
      elif ([.instances[].name] | length != (unique | length)) then "instance names must be unique"
      else empty end
    ' "$CONFIG_PATH")" || die "$EXIT_CONFIG" "Configuration is not valid JSON"
    [[ -z "$errors" ]] || die "$EXIT_CONFIG" "$errors"
}

prepare_directories() {
    STATE_DIR="$(jq -r '.general.state_dir' "$CONFIG_PATH")"
    LOG_DIR="$(jq -r '.general.log_dir' "$CONFIG_PATH")"
    mkdir -p -- "$STATE_DIR" "$LOG_DIR" || die "$EXIT_STATE" "Cannot create state/log directories"
    chmod 700 -- "$STATE_DIR" "$LOG_DIR" || die "$EXIT_SECURITY" "Cannot secure state/log directories"
    [[ -w "$STATE_DIR" && -w "$LOG_DIR" ]] || die "$EXIT_STATE" "State/log directories are not writable"
    STATE_FILE="$STATE_DIR/processed.jsonl"
    COUNTER_FILE="$STATE_DIR/hourly-counters.json"
    LOCK_FILE="$STATE_DIR/altHuntarr.lock"
    LOG_FILE="$LOG_DIR/altHuntarr.log"
    RUNS_FILE="$LOG_DIR/runs.jsonl"
    [[ -f "$STATE_FILE" ]] || : >"$STATE_FILE" || die "$EXIT_STATE" "Cannot initialize state file"
    [[ -f "$COUNTER_FILE" ]] || printf '{}\n' >"$COUNTER_FILE"
    [[ -f "$LOG_FILE" ]] || : >"$LOG_FILE" || die "$EXIT_STATE" "Cannot initialize log file"
    [[ -f "$RUNS_FILE" ]] || : >"$RUNS_FILE" || die "$EXIT_STATE" "Cannot initialize run log"
    chmod 600 -- "$STATE_FILE" "$COUNTER_FILE" "$LOG_FILE" "$RUNS_FILE" || die "$EXIT_SECURITY" "Cannot secure runtime files"
}

resolve_api_key() {
    local instance="$1" suppress_warning="${2:-0}" env_name key_file secret_ref direct key
    env_name="$(jq -r '.api_key_env // empty' <<<"$instance")"
    key_file="$(jq -r '.api_key_file // empty' <<<"$instance")"
    secret_ref="$(jq -r '.secret_ref // empty' <<<"$instance")"
    direct="$(jq -r '.api_key // empty' <<<"$instance")"
    key=""
    if [[ -n "$env_name" ]]; then
        [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$EXIT_CONFIG" "Invalid API-key environment variable name"
        key="${!env_name-}"
    elif [[ -n "$key_file" ]]; then
        assert_secret_permissions "$key_file"
        key="$(head -n 1 -- "$key_file")"
    elif [[ -n "$secret_ref" ]]; then
        [[ -n "$SECRETS_PATH" ]] || die "$EXIT_CONFIG" "secret_ref requires --secrets"
        key="$(jq -r --arg ref "$secret_ref" '.[$ref] // empty' "$SECRETS_PATH")"
    else
        key="$direct"
        ((suppress_warning)) || printf '%s\n' "$(utc_iso) WARN run=${RUN_ID:-bootstrap} event=direct_api_key message=\"Prefer api_key_env, api_key_file, or secret_ref\"" >&2
    fi
    [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || die "$EXIT_CONFIG" "API key could not be securely resolved"
    printf '%s' "$key"
}

validate_enabled_api_keys() {
    local instance
    while IFS= read -r instance; do
        [[ "$(jq -r '.enabled' <<<"$instance")" == "true" ]] || continue
        resolve_api_key "$instance" 1 >/dev/null
    done < <(jq -c '.instances[]' "$CONFIG_PATH")
}

load_config() {
    [[ -f "$CONFIG_PATH" ]] || die "$EXIT_CONFIG" "Configuration does not exist: $CONFIG_PATH"
    assert_secret_permissions "$CONFIG_PATH"
    validate_config_schema
    if [[ -n "$SECRETS_PATH" ]]; then
        assert_secret_permissions "$SECRETS_PATH"
        jq -e 'type == "object"' "$SECRETS_PATH" >/dev/null || die "$EXIT_CONFIG" "Secrets file must be a JSON object"
    fi
    prepare_directories
    SELECTION="$(jq -r '.general.selection // "random"' "$CONFIG_PATH")"
    STATE_TTL_HOURS="$(jq -r '.general.state_ttl_hours // 168' "$CONFIG_PATH")"
    REQUEST_TIMEOUT="$(jq -r '.general.request_timeout_seconds // 120' "$CONFIG_PATH")"
    CONNECT_TIMEOUT="$(jq -r '.general.connect_timeout_seconds // 10' "$CONFIG_PATH")"
    RETRY_COUNT="$(jq -r '.general.retry_count // 2' "$CONFIG_PATH")"
    RETRY_DELAY="$(jq -r '.general.retry_delay_seconds // 3' "$CONFIG_PATH")"
    PAGE_SIZE="$(jq -r '.general.page_size // 100' "$CONFIG_PATH")"
    VERIFY_TLS="$(jq -r '.general.verify_tls // true | if . then 1 else 0 end' "$CONFIG_PATH")"
    DRY_RUN="$(jq -r '.general.dry_run // false | if . then 1 else 0 end' "$CONFIG_PATH")"
    LOG_LEVEL="$(jq -r '.general.log_level // "info"' "$CONFIG_PATH")"
    [[ -z "$CLI_LOG_LEVEL" ]] || LOG_LEVEL="$CLI_LOG_LEVEL"
    ((CLI_DRY_RUN == 0 && SHOW_CANDIDATES == 0)) || DRY_RUN=1
    if [[ ! "$REQUEST_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || ((REQUEST_TIMEOUT > 3600)); then die "$EXIT_CONFIG" "Invalid request timeout"; fi
    if [[ ! "$CONNECT_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || ((CONNECT_TIMEOUT > 300)); then die "$EXIT_CONFIG" "Invalid connect timeout"; fi
    if [[ ! "$RETRY_COUNT" =~ ^[0-9]+$ ]] || ((RETRY_COUNT > 10)); then die "$EXIT_CONFIG" "Invalid retry count"; fi
    if [[ ! "$RETRY_DELAY" =~ ^[0-9]+$ ]] || ((RETRY_DELAY > 60)); then die "$EXIT_CONFIG" "Invalid retry delay"; fi
    if [[ ! "$PAGE_SIZE" =~ ^[1-9][0-9]*$ ]] || ((PAGE_SIZE > 1000)); then die "$EXIT_CONFIG" "Invalid page size"; fi
    log_level_value "$LOG_LEVEL" >/dev/null || die "$EXIT_CONFIG" "Invalid general.log_level"
    validate_enabled_api_keys
}

acquire_lock() {
    exec {LOCK_FD}>"$LOCK_FILE"
    flock -n "$LOCK_FD" || {
        log warn "event=lock_held"
        exit "$EXIT_LOCK"
    }
}
release_lock() {
    [[ -z "$LOCK_FD" ]] || flock -u "$LOCK_FD" || true
    LOCK_FD=""
}
safe_temp() { mktemp "$STATE_DIR/.altHuntarr.XXXXXX"; }

atomic_json_replace() {
    local temporary="$1" destination="$2"
    jq -e . "$temporary" >/dev/null 2>&1 || {
        rm -f -- "$temporary"
        die "$EXIT_STATE" "Refusing invalid JSON write: $destination"
    }
    command -v sync >/dev/null 2>&1 && sync -f "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$destination" || die "$EXIT_STATE" "Atomic rename failed: $destination"
    chmod 600 "$destination"
}

state_compact() {
    local temporary now
    now="$(utc_iso)"
    temporary="$(safe_temp)"
    if [[ -s "$STATE_FILE" ]]; then
        jq -c --arg now "$now" 'select((.expires_at | type == "string") and .expires_at > $now)' "$STATE_FILE" >"$temporary" || die "$EXIT_STATE" "State file contains invalid JSONL"
    else
        : >"$temporary"
    fi
    if [[ -s "$temporary" ]] && ! jq -s -e 'all(.[]; type == "object")' "$temporary" >/dev/null; then
        rm -f -- "$temporary"
        die "$EXIT_STATE" "State contains invalid records"
    fi
    command -v sync >/dev/null 2>&1 && sync -f "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$STATE_FILE" || die "$EXIT_STATE" "Cannot compact state"
    chmod 600 "$STATE_FILE"
}

state_processed_keys() { jq -s -c --arg app "$1" --arg instance "$2" --arg operation "$3" '[.[] | select(.app == $app and .instance_id == $instance and .operation == $operation) | .item_key]' "$STATE_FILE"; }
state_record_items() {
    local operation="$1" item_type="$2" command_id="$3" items="$4" now expires temporary additions
    now="$(utc_iso)"
    expires="$(date -u -d "+${STATE_TTL_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    additions="$(jq -c --arg timestamp "$now" --arg expires "$expires" --arg app "$CURRENT_TYPE" --arg instance "$CURRENT_NAME" --arg instance_id "$CURRENT_INSTANCE_ID" --arg operation "$operation" --arg item_type "$item_type" --argjson command_id "$command_id" --arg run_id "$RUN_ID" 'map({timestamp:$timestamp, expires_at:$expires, app:$app, instance:$instance, instance_id:$instance_id, operation:$operation, item_type:$item_type, item_key:.item_key, title:(.title // .series.title // "unknown"), command_id:$command_id, command_status:"submitted", run_id:$run_id})' <<<"$items")" || die "$EXIT_STATE" "Cannot build state records"
    temporary="$(safe_temp)"
    if [[ -s "$STATE_FILE" ]]; then
        jq -c --arg now "$now" 'select((.expires_at | type == "string") and .expires_at > $now)' "$STATE_FILE" >"$temporary" || die "$EXIT_STATE" "Cannot update state"
        jq -cn --argjson additions "$additions" '$additions[]' >>"$temporary" || die "$EXIT_STATE" "Cannot append state"
    else
        jq -cn --argjson additions "$additions" '$additions[]' >"$temporary" || die "$EXIT_STATE" "Cannot initialize state"
    fi
    command -v sync >/dev/null 2>&1 && sync -f "$temporary" 2>/dev/null || true
    mv -f -- "$temporary" "$STATE_FILE" || die "$EXIT_STATE" "Cannot write state"
    chmod 600 "$STATE_FILE"
}

counter_compact() {
    local temporary hour
    hour="$(utc_hour)"
    temporary="$(safe_temp)"
    jq -c --arg hour "$hour" 'with_entries(select(.value.hour_utc == $hour and (.value.submitted_commands | type == "number")))' "$COUNTER_FILE" >"$temporary" || die "$EXIT_STATE" "Counter file contains invalid JSON"
    atomic_json_replace "$temporary" "$COUNTER_FILE"
}
counter_used() { jq -r --arg instance "$1" --arg hour "$(utc_hour)" '(.[$instance] // {}) | if .hour_utc == $hour then (.submitted_commands // 0) else 0 end' "$COUNTER_FILE"; }
counter_remaining() {
    local cap="$1" used
    ((cap == -1)) && {
        echo 2147483647
        return
    }
    used="$(counter_used "$CURRENT_INSTANCE_ID")" || die "$EXIT_STATE" "Cannot read counter"
    ((cap > used)) && echo "$((cap - used))" || echo 0
}
counter_increment() {
    local temporary hour
    hour="$(utc_hour)"
    temporary="$(safe_temp)"
    jq -c --arg instance "$CURRENT_INSTANCE_ID" --arg hour "$hour" '.[$instance] = {hour_utc:$hour, submitted_commands:((.[$instance].submitted_commands // 0) + 1)}' "$COUNTER_FILE" >"$temporary" || die "$EXIT_STATE" "Cannot update counter"
    atomic_json_replace "$temporary" "$COUNTER_FILE"
}

# API credentials are written only to a mode-0600 curl configuration file, never to a URL or normal process argument.
arr_request() {
    local method="$1" endpoint="$2" body="${3-}" cfg response headers body_file status attempt=0 curl_exit=0 retry_after delay
    ARR_RESPONSE=""
    ARR_HTTP=0
    ARR_ERROR=""
    [[ "$endpoint" == /* && "$endpoint" != *$'\n'* && "$endpoint" != *$'\r'* ]] || {
        ARR_ERROR="invalid endpoint"
        return 1
    }
    cfg="$(safe_temp)"
    response="$(safe_temp)"
    headers="$(safe_temp)"
    body_file=""
    {
        printf 'silent\nshow-error\nrequest = "%s"\n' "$method"
        printf 'header = "Accept: application/json"\nheader = "X-Api-Key: %s"\n' "$CURRENT_API_KEY"
        printf 'connect-timeout = %s\nmax-time = %s\n' "$CONNECT_TIMEOUT" "$REQUEST_TIMEOUT"
        ((VERIFY_TLS == 1)) || printf 'insecure\n'
        if [[ "$method" == "POST" ]]; then
            body_file="$(safe_temp)"
            printf '%s' "$body" >"$body_file"
            printf 'header = "Content-Type: application/json"\ndata = "@%s"\n' "$body_file"
        fi
        printf 'url = "%s%s%s"\n' "$CURRENT_URL" "$API_PREFIX" "$endpoint"
    } >"$cfg"
    chmod 600 "$cfg" "$response" "$headers" ${body_file:+"$body_file"}
    while :; do
        : >"$response"
        : >"$headers"
        curl_exit=0
        status="$(curl --config "$cfg" --output "$response" --dump-header "$headers" --write-out '%{http_code}' 2>/dev/null)" || curl_exit=$?
        ARR_HTTP="${status:-0}"
        if ((curl_exit == 0)) && [[ "$ARR_HTTP" =~ ^2[0-9][0-9]$ ]] && jq -e . "$response" >/dev/null 2>&1; then
            ARR_RESPONSE="$(cat "$response")"
            rm -f -- "$cfg" "$response" "$headers" ${body_file:+"$body_file"}
            return 0
        fi
        if [[ "$method" == "GET" ]] && ((attempt < RETRY_COUNT)) && [[ "$ARR_HTTP" == 0 || "$ARR_HTTP" == 429 || "$ARR_HTTP" =~ ^5[0-9][0-9]$ ]]; then
            attempt=$((attempt + 1))
            retry_after="$(awk 'BEGIN{IGNORECASE=1} tolower($1)=="retry-after:" {gsub("\\r","",$2); if($2~/^[0-9]+$/) print $2; exit}' "$headers")"
            if [[ -n "$retry_after" ]]; then delay="$retry_after"; else delay=$((RETRY_DELAY * attempt + RANDOM % 2)); fi
            ((delay > 60)) && delay=60
            log warn "instance=$(printf '%q' "$CURRENT_NAME") event=http_retry endpoint=$(printf '%q' "$endpoint") status=$ARR_HTTP attempt=$attempt"
            sleep "$delay"
            continue
        fi
        ARR_ERROR="HTTP ${ARR_HTTP:-0} for $method $endpoint"
        rm -f -- "$cfg" "$response" "$headers" ${body_file:+"$body_file"}
        return 1
    done
}
arr_post_command() {
    local payload="$1"
    if ((DRY_RUN)); then
        log info "instance=$(printf '%q' "$CURRENT_NAME") event=dry_run_post_blocked"
        return 0
    fi
    arr_request POST "/command" "$payload" || return 1
    jq -e '.id | numbers' <<<"$ARR_RESPONSE" >/dev/null || {
        ARR_ERROR="command response has no numeric id"
        return 1
    }
}
check_connection() {
    local reported
    arr_request GET "/system/status" || return 1
    reported="$(jq -r '(.appName // .applicationName // "") | ascii_downcase' <<<"$ARR_RESPONSE")"
    [[ -z "$reported" || "$reported" == *"$CURRENT_TYPE"* ]] || {
        ARR_ERROR="configured service type does not match system status"
        return 1
    }
}
get_queue_size() {
    arr_request GET "/queue?page=1&pageSize=1" || return 1
    jq -er 'if (.totalRecords | type) == "number" then .totalRecords elif (.records | type) == "array" then (.records | length) else error("missing queue count") end' <<<"$ARR_RESPONSE"
}

fetch_paginated_wanted() {
    local endpoint="$1" page=1 total=-1 records='[]' page_records count current sort_key
    if [[ "$CURRENT_TYPE" == "sonarr" ]]; then sort_key="airDateUtc"; else case "$(jq -r '.future_release_date // "digital"' <<<"$CURRENT_INSTANCE_JSON")" in physical) sort_key="physicalRelease" ;; cinema) sort_key="inCinemas" ;; *) sort_key="digitalRelease" ;; esac fi
    while :; do
        arr_request GET "${endpoint}?page=${page}&pageSize=${PAGE_SIZE}&sortKey=${sort_key}&sortDirection=ascending" || return 1
        page_records="$(jq -c 'if (.records | type) == "array" then .records elif type == "array" then . else error("missing records") end' <<<"$ARR_RESPONSE")" || return 1
        count="$(jq -r length <<<"$page_records")"
        current="$(jq -r '.totalRecords // empty' <<<"$ARR_RESPONSE")"
        [[ -z "$current" ]] || total="$current"
        records="$(jq -c --argjson a "$records" --argjson b "$page_records" '$a + $b' <<<null)" || return 1
        ((count == 0)) && break
        ((total >= 0 && page * PAGE_SIZE >= total)) && break
        page=$((page + 1))
        ((page <= 100000)) || {
            log error "instance=$(printf '%q' "$CURRENT_NAME") event=pagination_limit"
            return 1
        }
    done
    printf '%s\n' "$records"
}
radarr_fetch_missing() {
    local records
    if records="$(fetch_paginated_wanted "/wanted/missing")"; then
        printf '%s\n' "$records"
        return 0
    fi
    if [[ "$ARR_HTTP" == 404 ]]; then
        log warn "instance=$(printf '%q' "$CURRENT_NAME") event=radarr_missing_fallback"
        arr_request GET "/movie" || return 1
        jq -c 'if type == "array" then . else error("movie endpoint did not return an array") end' <<<"$ARR_RESPONSE"
        return 0
    fi
    return 1
}

filter_candidates() {
    local app="$1" operation="$2" monitored="$3" skip_future="$4" release_mode="$5" items="$6" now processed
    now="$(utc_epoch)"
    processed="$(state_processed_keys "$app" "$CURRENT_INSTANCE_ID" "$operation")" || return 1
    jq -c --arg app "$app" --arg operation "$operation" --argjson only_monitored "$monitored" --argjson skip_future "$skip_future" --arg release_mode "$release_mode" --argjson now "$now" --argjson processed "$processed" '
            def valid_time($value):
                if $value == null or $value == "" then false
                else (try ((((if ($value | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then $value + "T00:00:00Z" else $value end) | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) <= $now)) catch false)
                end;
      def movie_date: if $release_mode == "physical" then (.physicalRelease // .digitalRelease // .inCinemas) elif $release_mode == "cinema" then (.inCinemas // .digitalRelease // .physicalRelease) else (.digitalRelease // .physicalRelease // .inCinemas) end;
      def item_key: if $app == "sonarr" then "episode:" + (.id | tostring) else "movie:" + (.id | tostring) end;
      map(select(if $app == "sonarr" then ((.id | type) == "number" and (.seriesId | type) == "number") else ((.id | type) == "number") end))
      | map(select(($only_monitored | not) or (.monitored == true))) | map(select(if $app == "sonarr" then ((.series.monitored? // true) == true) else true end))
      | map(select(if $app == "radarr" and $operation == "missing" then (.hasFile == false or .hasFile == null) else true end))
      | map(select(($skip_future | not) or (if $app == "sonarr" then valid_time(.airDateUtc) else valid_time(movie_date) end))) | map(. + {item_key:item_key}) | map(select(($processed | index(.item_key)) | not))
    ' <<<"$items"
}
select_candidates() {
    local items="$1" limit="$2" field
    ((limit > 0)) || {
        echo '[]'
        return
    }
    if [[ "$SELECTION" == sequential ]]; then
        if [[ "$CURRENT_TYPE" == sonarr ]]; then field='(.airDateUtc // "9999-12-31T23:59:59Z")'; else field='(.digitalRelease // .physicalRelease // .inCinemas // "9999-12-31T23:59:59Z")'; fi
        jq -c --argjson limit "$limit" "sort_by(${field}, .id) | .[:\$limit]" <<<"$items"
    else jq -c '.[]' <<<"$items" | shuf -n "$limit" | jq -s -c '.'; fi
}
show_selected_candidates() {
    local operation="$1" selected="$2"
    jq -r --arg app "$CURRENT_TYPE" --arg instance "$CURRENT_NAME" --arg operation "$operation" '.[] | "candidate app=\($app) instance=\($instance) operation=\($operation) item_key=\(.item_key) title=\(.title // .series.title // "unknown")"' <<<"$selected" >&2
}

submit_radarr() {
    local operation="$1" selected="$2" submitted=0 failed=0 one id payload command_id
    while IFS= read -r one; do
        [[ -n "$one" ]] || continue
        (($(counter_remaining "$CURRENT_HOURLY_CAP") > 0)) || break
        id="$(jq -r '.id' <<<"$one")"
        payload="$(jq -cn --argjson id "$id" '{name:"MoviesSearch", movieIds:[$id]}')"
        if arr_post_command "$payload"; then
            command_id="$(jq -r '.id' <<<"$ARR_RESPONSE")"
            state_record_items "$operation" "movie" "$command_id" "[$one]"
            counter_increment
            submitted=$((submitted + 1))
            log info "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=search_submitted command_id=$command_id items=1"
        else
            failed=$((failed + 1))
            log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=command_failed status=$ARR_HTTP"
        fi
    done < <(jq -c '.[]' <<<"$selected")
    printf '%s %s\n' "$submitted" "$failed"
}
submit_sonarr_episodes() {
    local operation="$1" selected="$2" submitted=0 failed=0 group ids items payload command_id
    while IFS= read -r group; do
        [[ -n "$group" ]] || continue
        (($(counter_remaining "$CURRENT_HOURLY_CAP") > 0)) || break
        ids="$(jq -c '[.items[].id]' <<<"$group")"
        items="$(jq -c '.items' <<<"$group")"
        payload="$(jq -cn --argjson ids "$ids" '{name:"EpisodeSearch", episodeIds:$ids}')"
        if arr_post_command "$payload"; then
            command_id="$(jq -r '.id' <<<"$ARR_RESPONSE")"
            state_record_items "$operation" "episode" "$command_id" "$items"
            counter_increment
            submitted=$((submitted + 1))
            log info "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=search_submitted command_id=$command_id items=$(jq 'length' <<<"$items")"
        else
            failed=$((failed + 1))
            log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=command_failed status=$ARR_HTTP"
        fi
    done < <(jq -c 'sort_by(.seriesId) | group_by(.seriesId)[] | {items:.}' <<<"$selected")
    printf '%s %s\n' "$submitted" "$failed"
}

run_operation() {
    local operation="$1" enabled batch remaining effective monitored skip_future release_mode records eligible selected fetched eligible_count selected_count result submitted failed
    enabled="$(jq -r --arg op "$operation" '.[$op].enabled' <<<"$CURRENT_INSTANCE_JSON")"
    batch="$(jq -r --arg op "$operation" '.[$op].batch_size' <<<"$CURRENT_INSTANCE_JSON")"
    [[ "$enabled" == true && "$batch" != 0 && ("$MODE_FILTER" == both || "$MODE_FILTER" == "$operation") ]] || {
        echo '0 0 0 0 0'
        return
    }
    remaining="$(counter_remaining "$CURRENT_HOURLY_CAP")"
    ((remaining > 0)) || {
        log info "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=hourly_cap_reached"
        echo '0 0 0 0 0'
        return
    }
    effective=$batch
    ((effective > remaining)) && effective=$remaining
    monitored="$(jq -r '.monitored_only | if . then 1 else 0 end' <<<"$CURRENT_INSTANCE_JSON")"
    skip_future="$(jq -r '.skip_future | if . then 1 else 0 end' <<<"$CURRENT_INSTANCE_JSON")"
    release_mode="$(jq -r '.future_release_date // "digital"' <<<"$CURRENT_INSTANCE_JSON")"
    if [[ "$CURRENT_TYPE" == sonarr ]]; then
        records="$(fetch_paginated_wanted "/wanted/$([[ "$operation" == missing ]] && printf missing || printf cutoff)")" || {
            log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=fetch_failed status=$ARR_HTTP"
            return 1
        }
    elif [[ "$operation" == missing ]]; then
        records="$(radarr_fetch_missing)" || {
            log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=fetch_failed status=$ARR_HTTP"
            return 1
        }
    else records="$(fetch_paginated_wanted "/wanted/cutoff")" || {
        log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=fetch_failed status=$ARR_HTTP"
        return 1
    }; fi
    fetched="$(jq length <<<"$records")"
    eligible="$(filter_candidates "$CURRENT_TYPE" "$operation" "$monitored" "$skip_future" "$release_mode" "$records")" || {
        log warn "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=filter_failed"
        return 1
    }
    eligible_count="$(jq length <<<"$eligible")"
    selected="$(select_candidates "$eligible" "$effective")" || return 1
    selected_count="$(jq length <<<"$selected")"
    log info "instance=$(printf '%q' "$CURRENT_NAME") operation=$operation event=candidates fetched=$fetched eligible=$eligible_count selected=$selected_count"
    ((selected_count > 0)) || {
        printf '%s %s 0 0 0\n' "$fetched" "$eligible_count"
        return
    }
    ((SHOW_CANDIDATES)) && show_selected_candidates "$operation" "$selected"
    if ((DRY_RUN)); then
        printf '%s %s %s 0 0\n' "$fetched" "$eligible_count" "$selected_count"
        return
    fi
    if [[ "$CURRENT_TYPE" == radarr ]]; then result="$(submit_radarr "$operation" "$selected")"; else result="$(submit_sonarr_episodes "$operation" "$selected")"; fi
    read -r submitted failed <<<"$result"
    printf '%s %s %s %s %s\n' "$fetched" "$eligible_count" "$selected_count" "$submitted" "$failed"
}

metrics_json() { awk '{printf "{\\\"fetched\\\":%s,\\\"eligible\\\":%s,\\\"selected\\\":%s,\\\"submitted\\\":%s,\\\"failed\\\":%s}", $1,$2,$3,$4,$5}' <<<"$1"; }
record_instance_result() { jq -cn --arg app "$CURRENT_TYPE" --arg instance "$CURRENT_NAME" --arg id "$CURRENT_INSTANCE_ID" --arg status "$1" --argjson queue "$2" --argjson missing "$3" --argjson upgrade "$4" '{app:$app,instance:$instance,instance_id:$id,status:$status,queue_size:$queue,missing:$missing,upgrade:$upgrade}' >>"$RUN_RESULTS_FILE"; }

run_instance() {
    local instance="$1" queue remaining missing upgrade status=ok missing_failed=0 upgrade_failed=0 missing_json upgrade_json
    CURRENT_INSTANCE_JSON="$instance"
    CURRENT_NAME="$(jq -r .name <<<"$instance")"
    CURRENT_TYPE="$(jq -r .type <<<"$instance")"
    CURRENT_URL="$(normalize_base_url "$(jq -r .url <<<"$instance")")" || {
        log error "instance=$(printf '%q' "$CURRENT_NAME") event=invalid_url"
        ANY_FAILURE=1
        return
    }
    CURRENT_API_KEY="$(resolve_api_key "$instance")"
    CURRENT_INSTANCE_ID="$(printf '%s' "$CURRENT_TYPE|$CURRENT_URL|$CURRENT_NAME" | sha256sum | awk '{print substr($1,1,12)}')"
    CURRENT_QUEUE_LIMIT="$(jq -r .max_download_queue_size <<<"$instance")"
    CURRENT_HOURLY_CAP="$(jq -r .hourly_search_cap <<<"$instance")"
    if ! check_connection; then
        log error "instance=$(printf '%q' "$CURRENT_NAME") event=connection_failed status=$ARR_HTTP error=$(printf '%q' "$ARR_ERROR")"
        ANY_FAILURE=1
        record_instance_result connection_failed -1 '{}' '{}'
        return
    fi
    ANY_REACHABLE=1
    if ((HEALTH_CHECK)); then
        log info "instance=$(printf '%q' "$CURRENT_NAME") event=health_ok"
        record_instance_result healthy -1 '{}' '{}'
        return
    fi
    if ! queue="$(get_queue_size)"; then
        if [[ "$(jq -r '.queue_error_policy // "skip"' <<<"$instance")" == skip ]]; then
            log warn "instance=$(printf '%q' "$CURRENT_NAME") event=queue_error_skip status=$ARR_HTTP"
            record_instance_result queue_error_skip -1 '{}' '{}'
            return
        fi
        queue=-1
        log warn "instance=$(printf '%q' "$CURRENT_NAME") event=queue_error_continue status=$ARR_HTTP"
    fi
    if ((CURRENT_QUEUE_LIMIT >= 0 && queue >= CURRENT_QUEUE_LIMIT)); then
        log info "instance=$(printf '%q' "$CURRENT_NAME") event=queue_gate queue_size=$queue threshold=$CURRENT_QUEUE_LIMIT"
        record_instance_result queue_gated "$queue" '{}' '{}'
        return
    fi
    remaining="$(counter_remaining "$CURRENT_HOURLY_CAP")"
    if ((remaining == 0)); then
        log info "instance=$(printf '%q' "$CURRENT_NAME") event=hourly_cap_reached"
        record_instance_result hourly_capped "$queue" '{}' '{}'
        return
    fi
    if ! missing="$(run_operation missing)"; then
        missing_failed=1
        status=partial_failure
        ANY_FAILURE=1
    fi
    if ! upgrade="$(run_operation upgrade)"; then
        upgrade_failed=1
        status=partial_failure
        ANY_FAILURE=1
    fi
    if ((missing_failed)); then missing_json='{"error":"operation failed"}'; else
        missing_json="$(metrics_json "$missing")"
        ((DRY_RUN && $(awk '{print $3}' <<<"$missing") > 0)) && DRY_FOUND=1
    fi
    if ((upgrade_failed)); then upgrade_json='{"error":"operation failed"}'; else
        upgrade_json="$(metrics_json "$upgrade")"
        ((DRY_RUN && $(awk '{print $3}' <<<"$upgrade") > 0)) && DRY_FOUND=1
    fi
    record_instance_result "$status" "$queue" "$missing_json" "$upgrade_json"
}

instance_selected() {
    local instance="$1" type name enabled
    type="$(jq -r .type <<<"$instance")"
    name="$(jq -r .name <<<"$instance")"
    enabled="$(jq -r .enabled <<<"$instance")"
    [[ "$enabled" == true && ("$APP_FILTER" == all || "$APP_FILTER" == "$type") && (-z "$INSTANCE_FILTER" || "$INSTANCE_FILTER" == "$name") ]]
}
reset_state() {
    local backup
    if [[ "$RESET_STATE" == all ]]; then
        backup="$STATE_DIR/processed.$(date -u +%Y%m%dT%H%M%SZ).jsonl.bak"
        cp -- "$STATE_FILE" "$backup" || die "$EXIT_STATE" "Cannot back up state"
        : >"$STATE_FILE"
        printf '{}\n' >"$COUNTER_FILE"
        chmod 600 "$STATE_FILE" "$COUNTER_FILE"
        log warn "event=state_reset mode=all backup=$(printf '%q' "$backup")"
    else
        state_compact
        counter_compact
        log info "event=state_reset mode=expired"
    fi
}

finish_run_summary() {
    local ended results summary
    ended="$(utc_iso)"
    results="$(jq -s -c '.' "$RUN_RESULTS_FILE")"
    summary="$(jq -cn --arg started "$RUN_STARTED" --arg ended "$ended" --arg run_id "$RUN_ID" --arg version "$SCRIPT_VERSION" --argjson dry_run "$DRY_RUN" --argjson exit_code "$RUN_EXIT" --argjson instances "$results" '{run_id:$run_id,started_at:$started,ended_at:$ended,script_version:$version,dry_run:($dry_run == 1),exit_code:$exit_code,instances:$instances}')"
    printf '%s\n' "$summary" >>"$RUNS_FILE"
    chmod 600 "$RUNS_FILE"
    if ((JSON_SUMMARY)); then printf '%s\n' "$summary"; else log info "event=run_complete exit_code=$RUN_EXIT instances=$(jq length <<<"$results") dry_run=$DRY_RUN"; fi
    rm -f -- "$RUN_RESULTS_FILE"
    RUN_RESULTS_FILE=""
}
run_cycle() {
    local instance found=0
    RUN_STARTED="$(utc_iso)"
    RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    RUN_RESULTS_FILE="$(safe_temp)"
    : >"$RUN_RESULTS_FILE"
    state_compact
    counter_compact
    if [[ -n "$RESET_STATE" ]]; then
        reset_state
        RUN_EXIT=0
        finish_run_summary
        return
    fi
    while IFS= read -r instance; do
        [[ -n "$instance" ]] || continue
        if instance_selected "$instance"; then
            found=1
            run_instance "$instance"
        fi
    done < <(jq -c '.instances[]' "$CONFIG_PATH")
    if ((found == 0)); then
        log warn "event=no_instances_selected"
        RUN_EXIT="$EXIT_CONFIG"
    elif ((ANY_REACHABLE == 0)); then RUN_EXIT="$EXIT_UNREACHABLE"; elif ((ANY_FAILURE)); then RUN_EXIT="$EXIT_PARTIAL"; elif ((DRY_RUN && DRY_FOUND)); then RUN_EXIT="$EXIT_DRY_FOUND"; else RUN_EXIT=0; fi
    finish_run_summary
    return "$RUN_EXIT"
}

cleanup() {
    release_lock
    [[ -z "$RUN_RESULTS_FILE" ]] || rm -f -- "$RUN_RESULTS_FILE"
}
on_signal() {
    log warn "event=signal_received"
    exit 130
}
main() {
    parse_args "$@"
    validate_dependencies
    load_config
    acquire_lock
    trap cleanup EXIT
    trap on_signal INT TERM HUP
    if ((LOOP_MODE)); then while :; do
        ANY_REACHABLE=0
        ANY_FAILURE=0
        DRY_FOUND=0
        run_cycle || true
        sleep "$INTERVAL_SECONDS"
    done; else run_cycle; fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
