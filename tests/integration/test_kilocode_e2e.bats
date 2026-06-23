#!/usr/bin/env bats
# End-to-end drive of the Kilocode adapter against a mock kilocode CLI
# (multi-provider epic, #321 / MP.10b).
#
# Exercises the full provider pipeline with AGENT_PROVIDER=kilocode:
#   build (registry dispatch) -> run the mock kilocode binary -> capture JSON
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

    export AGENT_PROVIDER="kilocode"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "kilocode e2e: build -> run mock kilocode CLI -> normalize -> exit detected" {
    local mock="$TEST_DIR/kilocode"
    harness_make_mock_cli "$mock" "$FIXTURES/kilocode_json.json"
    export KILOCODE_CMD="$mock"

    # build via the registry dispatch (AGENT_PROVIDER=kilocode)
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "$mock" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "--auto" ]

    # run the built argv exactly as the loop would, capturing output
    local out="$TEST_DIR/kilocode_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    # detect + normalize through the dispatch (the analyzer step)
    [ "$(agent_detect_format "$out")" = "json" ]
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.exit_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.has_completion_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.session_id' "$RESULT")" = "kilocode-sess-1" ]
}

@test "kilocode e2e: full pipeline via analyze_response sets exit_signal" {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    local mock="$TEST_DIR/kilocode"
    harness_make_mock_cli "$mock" "$FIXTURES/kilocode_json.json"
    export KILOCODE_CMD="$mock"

    agent_build_command "$PROMPT_FILE" "" ""
    local out="$TEST_DIR/kilocode_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    local analysis="$RALPH_DIR/.response_analysis"
    analyze_response "$out" 1 "$analysis"

    [ "$(jq -r '.output_format' "$analysis")" = "json" ]
    [ "$(jq -r '.analysis.exit_signal' "$analysis")" = "true" ]
}

@test "kilocode e2e: continue-last forwards -c to the mock CLI" {
    local mock="$TEST_DIR/kilocode"
    harness_make_mock_cli "$mock" "$FIXTURES/kilocode_json.json"
    export KILOCODE_CMD="$mock"
    export CLAUDE_USE_CONTINUE="true"

    agent_build_command "$PROMPT_FILE" "" "prior-kilocode-7"
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" == *"-c"* ]]

    local out="$TEST_DIR/kilocode_out.json"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.session_id' "$RESULT")" = "kilocode-sess-1" ]
}
