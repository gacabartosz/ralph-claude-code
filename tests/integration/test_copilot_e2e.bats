#!/usr/bin/env bats
# End-to-end drive of the Copilot adapter against a mock copilot CLI
# (multi-provider epic, #322 / MP.11b).
#
# Copilot is the TEXT-ONLY / degraded provider. Exercises the full pipeline with
# AGENT_PROVIDER=copilot:
#   build (registry dispatch) -> run the mock copilot binary -> capture TEXT
#   -> detect (always "text") -> analyze_response exit via RALPH_STATUS (#224).
# Also proves the degraded capability gates warn-and-no-op. Uses
# harness_make_mock_cli (sleeps >1s, emits canned output) so the seam is proven
# against a real executable.

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

    export AGENT_PROVIDER="copilot"
    export CLAUDE_OUTPUT_FORMAT="json"   # ignored by Copilot (text-only)
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL COPILOT_ALLOWED_TOOLS COPILOT_DENIED_TOOLS

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "copilot e2e: build -> run mock copilot CLI -> detect text -> exit detected" {
    local mock="$TEST_DIR/copilot"
    harness_make_mock_cli "$mock" "$FIXTURES/copilot_text.txt"
    export COPILOT_CMD="$mock"

    # build via the registry dispatch (AGENT_PROVIDER=copilot)
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "$mock" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "-s" ]

    # run the built argv exactly as the loop would, capturing output
    local out="$TEST_DIR/copilot_out.txt"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    # Copilot always reports text; normalize maps the RALPH_STATUS block
    [ "$(agent_detect_format "$out")" = "text" ]
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.exit_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.has_completion_signal' "$RESULT")" = "true" ]
}

@test "copilot e2e: full pipeline via analyze_response (text path) sets exit_signal" {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    local mock="$TEST_DIR/copilot"
    harness_make_mock_cli "$mock" "$FIXTURES/copilot_text.txt"
    export COPILOT_CMD="$mock"

    agent_build_command "$PROMPT_FILE" "" ""
    local out="$TEST_DIR/copilot_out.txt"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    local analysis="$RALPH_DIR/.response_analysis"
    analyze_response "$out" 1 "$analysis"

    # Copilot has no JSON output -> the analyzer takes the text path
    [ "$(jq -r '.output_format' "$analysis")" = "text" ]
    [ "$(jq -r '.analysis.exit_signal' "$analysis")" = "true" ]
}

@test "copilot e2e: resume forwards --resume id; degraded gates warn-and-noop" {
    local mock="$TEST_DIR/copilot"
    harness_make_mock_cli "$mock" "$FIXTURES/copilot_text.txt"
    export COPILOT_CMD="$mock"
    export CLAUDE_USE_CONTINUE="true"

    agent_build_command "$PROMPT_FILE" "" "prior-copilot-7"
    local joined="${CLAUDE_CMD_ARGS[*]}"
    [[ "$joined" == *"--resume prior-copilot-7"* ]]

    # Session resume IS supported; token usage / api-limit are NOT (degrade).
    agent_has_capability "supports_session_resume"
    run agent_capability_enabled "supports_token_usage" "token limiting"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not support supports_token_usage"* ]]
    run agent_capability_enabled "supports_api_limit_detection" "API-limit detection"
    [ "$status" -eq 1 ]
}
