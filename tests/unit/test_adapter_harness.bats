#!/usr/bin/env bats
# Self-test for the generic adapter harness (multi-provider epic, #316 / MP.5).
#
# Proves the harness can validate ANY adapter via the shared contract: it drives
# (a) the Claude reference adapter and (b) a throwaway mock adapter end-to-end
# through the same helpers (build argv, fixture normalization, capabilities), and
# exercises the mock-CLI generator. This is the scaffolding [P3.1]+ provider PRs
# plug into.

load '../helpers/test_helper'
load '../helpers/adapter_harness'

FIXTURES="${BATS_TEST_DIRNAME}/../fixtures/adapters"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"

    PROMPT_FILE="$TEST_DIR/PROMPT.md"
    printf 'Test prompt content\n' > "$PROMPT_FILE"
    RESULT="$RALPH_DIR/.json_parse_result"

    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL CLAUDE_EFFORT AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Harness drives the Claude reference adapter (acceptance) ─────────────────

@test "harness: validates Claude adapter build argv" {
    harness_assert_argv agent_claude_build_command "$PROMPT_FILE" "" "" -- \
        "claude" "--output-format" "json" "-p" "Test prompt content"
}

@test "harness: normalizes the Claude CLI-object fixture to the internal struct" {
    harness_normalize agent_claude_normalize_response "$FIXTURES/claude_cli_object.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "sess-object-1"
    harness_assert_field "$RESULT" '.files_modified' "3"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
}

@test "harness: normalizes the Claude stream/array fixture (init session fallback)" {
    harness_normalize agent_claude_normalize_response "$FIXTURES/claude_stream_array.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "sess-array-1"
    harness_assert_field "$RESULT" '.summary' "Done with the work"
}

@test "harness: Claude capabilities record is well-formed" {
    harness_assert_capabilities_wellformed "$AGENT_CLAUDE_CAPABILITIES"
}

# ── Harness drives a throwaway mock adapter end-to-end ──────────────────────

# A minimal adapter implementing the contract against a different CLI shape.
mock_build_command() {
    local prompt_file=$1 loop_context=$2 session_id=$3
    CLAUDE_CMD_ARGS=("mock-cli" "run" "--prompt-file" "$prompt_file")
    [[ -n "$session_id" ]] && CLAUDE_CMD_ARGS+=("--session" "$session_id")
    [[ -n "$loop_context" ]] && CLAUDE_CMD_ARGS+=("--context" "$loop_context")
}
mock_normalize_response() {
    local output_file=$1 result_file=$2
    # Mock provider emits {"verdict":..., "sid":..., "changed":N}; map to Ralph's struct.
    jq -n \
        --arg sid "$(jq -r '.sid // ""' "$output_file")" \
        --arg sum "$(jq -r '.verdict // ""' "$output_file")" \
        --argjson files "$(jq -r '.changed // 0' "$output_file")" \
        '{status:"UNKNOWN", exit_signal:false, session_id:$sid, summary:$sum, files_modified:$files}' \
        > "$result_file"
}
MOCK_CAPS="supports_token_usage supports_session_resume"

@test "harness: drives a mock adapter end-to-end (build + normalize + capabilities)" {
    # (a) command-build
    harness_assert_argv mock_build_command "$PROMPT_FILE" "ctx" "s1" -- \
        "mock-cli" "run" "--prompt-file" "$PROMPT_FILE" "--session" "s1" "--context" "ctx"

    # (b) normalize a recorded mock provider output
    local fixture="$TEST_DIR/mock_out.json"
    echo '{"verdict":"done","sid":"mock-sess-9","changed":2}' > "$fixture"
    harness_normalize mock_normalize_response "$fixture" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "mock-sess-9"
    harness_assert_field "$RESULT" '.summary' "done"
    harness_assert_field "$RESULT" '.files_modified' "2"

    # (c) capabilities record well-formed
    harness_assert_capabilities_wellformed "$MOCK_CAPS"
}

# ── Mock-CLI generator ──────────────────────────────────────────────────────

@test "harness: mock CLI stub is executable and emits the canned fixture" {
    local cli="$TEST_DIR/mock_claude"
    harness_make_mock_cli "$cli" "$FIXTURES/claude_cli_object.json"
    [ -x "$cli" ]
    run "$cli" --any --args --ignored
    assert_success
    [[ "$output" == *"sess-object-1"* ]]
}

@test "harness: mock CLI takes >1s per call (e2e early-failure rule)" {
    local cli="$TEST_DIR/mock_claude"
    harness_make_mock_cli "$cli" "$FIXTURES/claude_cli_object.json"
    local start end
    start=$(date +%s)
    "$cli" >/dev/null
    end=$(date +%s)
    [ $((end - start)) -ge 1 ]
}

# ── Negative: malformed capability records are rejected ─────────────────────

@test "harness: rejects an empty capabilities record" {
    run harness_assert_capabilities_wellformed ""
    assert_failure
}

@test "harness: rejects a malformed capability token" {
    run harness_assert_capabilities_wellformed "supports_token_usage bogus_flag"
    assert_failure
    [[ "$output" == *"malformed capability token"* ]]
}
