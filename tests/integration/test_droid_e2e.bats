#!/usr/bin/env bats
# End-to-end drive of the Droid adapter against a mock droid CLI
# (multi-provider epic, #320 / MP.9b).
#
# Exercises the full provider pipeline with AGENT_PROVIDER=droid:
#   build (registry dispatch) -> run the mock droid binary -> capture JSON
#   -> detect + normalize (dispatch) -> exit detection via RALPH_STATUS.
# Uses harness_make_mock_cli (sleeps >1s, emits canned output) so the seam is
# proven against a real executable.

load '../helpers/test_helper'
load '../helpers/adapter_harness'

FIXTURES="${BATS_TEST_DIRNAME}/../fixtures/adapters"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR/logs"

    PROMPT_FILE="$TEST_DIR/PROMPT.md"
    printf 'Do the next task.\n' > "$PROMPT_FILE"
    RESULT="$RALPH_DIR/.json_parse_result"

    export AGENT_PROVIDER="droid"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL DROID_AUTO

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "droid e2e: build -> run mock droid CLI -> normalize -> exit detected" {
    local mock="$TEST_DIR/droid"
    harness_make_mock_cli "$mock" "$FIXTURES/droid_json.json"
    export DROID_CMD="$mock"

    # build via the registry dispatch (AGENT_PROVIDER=droid)
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "$mock" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "exec" ]

    # run the built argv exactly as the loop would, capturing output
    local out="$TEST_DIR/droid_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    # detect + normalize through the dispatch (the analyzer step)
    [ "$(agent_detect_format "$out")" = "json" ]
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.exit_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.has_completion_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.session_id' "$RESULT")" = "droid-sess-1" ]
}

@test "droid e2e: full pipeline via analyze_response sets exit_signal" {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    local mock="$TEST_DIR/droid"
    harness_make_mock_cli "$mock" "$FIXTURES/droid_json.json"
    export DROID_CMD="$mock"

    agent_build_command "$PROMPT_FILE" "" ""
    local out="$TEST_DIR/droid_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    local analysis="$RALPH_DIR/.response_analysis"
    analyze_response "$out" 1 "$analysis"

    [ "$(jq -r '.output_format' "$analysis")" = "json" ]
    [ "$(jq -r '.analysis.exit_signal' "$analysis")" = "true" ]
}

@test "droid e2e: resume forwards the session id (--session-id) to the mock CLI" {
    local mock="$TEST_DIR/droid"
    harness_make_mock_cli "$mock" "$FIXTURES/droid_json.json"
    export DROID_CMD="$mock"
    export CLAUDE_USE_CONTINUE="true"

    agent_build_command "$PROMPT_FILE" "" "prior-droid-7"
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" == *"--session-id prior-droid-7"* ]]

    local out="$TEST_DIR/droid_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.session_id' "$RESULT")" = "droid-sess-1" ]
}
