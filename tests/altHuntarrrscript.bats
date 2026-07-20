#!/usr/bin/env bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../altHuntarrrscript.sh"
    # shellcheck disable=SC1090
    source "$SCRIPT"
    STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$STATE_DIR"
    STATE_FILE="$STATE_DIR/processed.jsonl"
    COUNTER_FILE="$STATE_DIR/hourly-counters.json"
    : >"$STATE_FILE"
    printf '{}\n' >"$COUNTER_FILE"
    CURRENT_TYPE="sonarr"
    CURRENT_NAME="Test Sonarr"
    CURRENT_URL="http://sonarr.test:8989"
    CURRENT_INSTANCE_ID="test-instance"
    CURRENT_HOURLY_CAP=3
    STATE_TTL_HOURS=168
    SELECTION="sequential"
    DRY_RUN=0
    LOG_FILE=""
}

@test "normalizes allowed base URLs and rejects API paths" {
    run normalize_base_url "https://sonarr.example.test/"
    [ "$status" -eq 0 ]
    [ "$output" = "https://sonarr.example.test" ]

    run normalize_base_url "https://sonarr.example.test/api/v3"
    [ "$status" -ne 0 ]
}

@test "processed state is scoped to app instance and operation" {
    cat >"$STATE_FILE" <<'EOF'
{"expires_at":"2999-01-01T00:00:00Z","app":"sonarr","instance_id":"test-instance","operation":"missing","item_key":"episode:10"}
{"expires_at":"2999-01-01T00:00:00Z","app":"sonarr","instance_id":"test-instance","operation":"upgrade","item_key":"episode:20"}
EOF

    run state_processed_keys sonarr test-instance missing
    [ "$status" -eq 0 ]
    [ "$output" = '["episode:10"]' ]
}

@test "Sonarr filtering enforces monitoring, date, required IDs, and state" {
    printf '%s\n' '{"expires_at":"2999-01-01T00:00:00Z","app":"sonarr","instance_id":"test-instance","operation":"missing","item_key":"episode:1"}' >"$STATE_FILE"
    records='[
      {"id":1,"seriesId":10,"monitored":true,"series":{"monitored":true},"airDateUtc":"2020-01-01T00:00:00Z"},
      {"id":2,"seriesId":10,"monitored":false,"series":{"monitored":true},"airDateUtc":"2020-01-01T00:00:00Z"},
      {"id":3,"seriesId":10,"monitored":true,"series":{"monitored":false},"airDateUtc":"2020-01-01T00:00:00Z"},
      {"id":4,"seriesId":10,"monitored":true,"series":{"monitored":true},"airDateUtc":"2999-01-01T00:00:00Z"},
      {"id":5,"seriesId":10,"monitored":true,"series":{"monitored":true},"airDateUtc":"2020-01-01T00:00:00Z"}
    ]'

    run filter_candidates sonarr missing 1 1 digital "$records"
    [ "$status" -eq 0 ]
    [ "$(jq 'length' <<<"$output")" -eq 1 ]
    [ "$(jq -r '.[0].item_key' <<<"$output")" = "episode:5" ]
}

@test "sequential selection uses date then ID ordering" {
    items='[
      {"id":9,"item_key":"episode:9","airDateUtc":"2021-01-01T00:00:00Z"},
      {"id":2,"item_key":"episode:2","airDateUtc":"2020-01-01T00:00:00Z"},
      {"id":1,"item_key":"episode:1","airDateUtc":"2020-01-01T00:00:00Z"}
    ]'

    run select_candidates "$items" 2
    [ "$status" -eq 0 ]
    [ "$(jq -c '[.[].id]' <<<"$output")" = '[1,2]' ]
}

@test "counter records submitted commands inside the UTC hour" {
    counter_increment
    counter_increment

    run counter_used test-instance
    [ "$status" -eq 0 ]
    [ "$output" -eq 2 ]

    run counter_remaining 3
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
}

@test "dry-run hard guard prevents arr_request POST" {
    DRY_RUN=1
    run arr_post_command '{"name":"MoviesSearch","movieIds":[1]}'
    [ "$status" -eq 0 ]
    [ -z "$ARR_RESPONSE" ]
}
