#!/usr/bin/env bats

ROOT="$BATS_TEST_DIRNAME/.."
IMAGE="althuntarr-entrypoint-test"

setup_file() {
    docker build -t "$IMAGE" "$ROOT" >/dev/null
}

setup() {
    TEST_ROOT="$ROOT/.test-tmp/entrypoint-$BATS_TEST_NUMBER-$$"
    CONFIG_DIR="$TEST_ROOT/config"
    DATA_DIR="$TEST_ROOT/data"
    mkdir -p "$CONFIG_DIR" "$DATA_DIR"
}

teardown() {
    rm -rf "$TEST_ROOT"
}

config_value() {
    docker run --rm --entrypoint cat -v "$CONFIG_DIR:/config:ro" "$IMAGE" /config/config.json | jq -r "$1"
}

@test "startup applies URL overrides and remains ready" {
    jq '.instances |= map(.enabled = false)' "$ROOT/examples/config.example.json" >"$CONFIG_DIR/config.json"
    chmod 600 "$CONFIG_DIR/config.json"

    run docker run --rm \
        -e ALTHUNTARR_RUN_ONCE=true \
        -e ALTHUNTARR_SONARR_URL=http://192.168.1.10:8989/ \
        -e ALTHUNTARR_RADARR_URL=http://192.168.1.10:7878 \
        -v "$CONFIG_DIR:/config" \
        -v "$DATA_DIR:/data" \
        "$IMAGE"

    [ "$status" -eq 3 ]
    [[ "$output" == *"no_instances_selected"* ]]
    [ "$(config_value '.instances[] | select(.type == "sonarr") | .url')" = "http://192.168.1.10:8989" ]
    [ "$(config_value '.instances[] | select(.type == "radarr") | .url')" = "http://192.168.1.10:7878" ]
}

@test "first start creates configuration from environment values" {
    run docker run --rm \
        -e ALTHUNTARR_DRY_RUN=false \
        -e ALTHUNTARR_SONARR_URL=http://192.168.1.10:8989 \
        -e ALTHUNTARR_RADARR_URL=http://192.168.1.10:7878 \
        -v "$CONFIG_DIR:/config" \
        -v "$DATA_DIR:/data" \
        "$IMAGE" healthcheck

    [ "$status" -eq 0 ]
    [[ "$output" == *"Created configuration at /config/config.json; continuing"* ]]
    [ "$(config_value '.general.dry_run')" = "false" ]
    [ "$(config_value '.instances[] | select(.type == "sonarr") | .url')" = "http://192.168.1.10:8989" ]
    [ "$(config_value '.instances[] | select(.type == "radarr") | .url')" = "http://192.168.1.10:7878" ]
}

@test "URL override rejects multiple instances of one type" {
    jq '.instances += [.instances[] | select(.type == "sonarr") | .name = "Sonarr-Second"]' \
        "$ROOT/examples/config.example.json" >"$CONFIG_DIR/config.json"
    chmod 600 "$CONFIG_DIR/config.json"

    run docker run --rm \
        -e ALTHUNTARR_SONARR_URL=http://192.168.1.10:8989 \
        -v "$CONFIG_DIR:/config" \
        -v "$DATA_DIR:/data" \
        "$IMAGE" --once

    [ "$status" -eq 2 ]
    [[ "$output" == *"requires exactly one sonarr instance"* ]]
}