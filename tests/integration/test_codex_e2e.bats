#!/usr/bin/env bats
# End-to-end drive of the Codex adapter against a mock codex CLI
# (multi-provider epic, #317 / MP.6c).
#
# Exercises the full provider pipeline the loop performs, with AGENT_PROVIDER=codex:
#   build (registry dispatch) -> run the mock codex binary -> capture JSONL
#   -> detect + normalize (dispatch) -> exit detection via RALPH_STATUS.
# The mock CLI is produced by harness_make_mock_cli (sleeps >1s, emits canned
# output), so this proves the seam works against a real executable, not just
# in-process function calls.

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

    export AGENT_PROVIDER="codex"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

@test "codex e2e: build -> run mock codex CLI -> normalize -> exit detected" {
    # A mock codex binary that emits the canned JSONL stream (with RALPH_STATUS).
    local mock="$TEST_DIR/codex"
    harness_make_mock_cli "$mock" "$FIXTURES/codex_jsonl.json"
    export CODEX_CMD="$mock"

    # build via the registry dispatch (AGENT_PROVIDER=codex)
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "$mock" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "exec" ]

    # run the built argv exactly as the loop would, capturing output
    local out="$TEST_DIR/codex_out.jsonl"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    # detect + normalize through the dispatch (the analyzer step)
    [ "$(agent_detect_format "$out")" = "json" ]
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.exit_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.has_completion_signal' "$RESULT")" = "true" ]
    [ "$(jq -r '.session_id' "$RESULT")" = "codex-sess-1" ]
}

@test "codex e2e: full pipeline via analyze_response sets exit_signal" {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    local mock="$TEST_DIR/codex"
    harness_make_mock_cli "$mock" "$FIXTURES/codex_jsonl.json"
    export CODEX_CMD="$mock"

    agent_build_command "$PROMPT_FILE" "" ""
    local out="$TEST_DIR/codex_out.jsonl"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null

    local analysis="$RALPH_DIR/.response_analysis"
    analyze_response "$out" 1 "$analysis"

    [ "$(jq -r '.output_format' "$analysis")" = "json" ]
    [ "$(jq -r '.analysis.exit_signal' "$analysis")" = "true" ]
}

@test "codex e2e: resume forwards the prior session id to the mock CLI" {
    local mock="$TEST_DIR/codex"
    harness_make_mock_cli "$mock" "$FIXTURES/codex_jsonl.json"
    export CODEX_CMD="$mock"
    export CLAUDE_USE_CONTINUE="true"

    agent_build_command "$PROMPT_FILE" "" "prior-sess-7"
    # codex exec resume <id> --json <prompt>
    [ "${CLAUDE_CMD_ARGS[1]}" = "exec" ]
    [ "${CLAUDE_CMD_ARGS[2]}" = "resume" ]
    [ "${CLAUDE_CMD_ARGS[3]}" = "prior-sess-7" ]

    # The mock ignores args but the command must still run and normalize.
    local out="$TEST_DIR/codex_out.jsonl"
    "${CLAUDE_CMD_ARGS[@]}" > "$out" 2>/dev/null
    agent_normalize_response "$out" "$RESULT"
    [ "$(jq -r '.session_id' "$RESULT")" = "codex-sess-1" ]
}
