#!/usr/bin/env bats
# Droid (Factory Droid) adapter tests (multi-provider epic, #320 / MP.9a).
#
# Validates the Droid adapter through the generic harness (#316): command-build
# argv, JSON normalization, the capability record, and registry dispatch when
# AGENT_PROVIDER=droid.

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

    export DROID_CMD="droid"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL DROID_AUTO AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Registration ────────────────────────────────────────────────────────────

@test "droid: provider is registered and selectable" {
    agent_provider_is_registered "droid"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"droid"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "droid build: basic invocation (droid exec -o json <prompt>)" {
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "" -- \
        "droid" "exec" "-o" "json" "Test prompt content"
}

@test "droid build: default model omits -m (Droid defaults to claude-opus-4-8)" {
    agent_droid_build_command "$PROMPT_FILE" "" ""
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "-m" ]
    done
}

@test "droid build: DROID_CMD override is honored" {
    export DROID_CMD="npx droid"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "" -- \
        "npx droid" "exec" "-o" "json" "Test prompt content"
}

@test "droid build: CLAUDE_MODEL maps to -m" {
    export CLAUDE_MODEL="claude-opus-4-8"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "" -- \
        "droid" "exec" "-o" "json" "-m" "claude-opus-4-8" "Test prompt content"
}

@test "droid build: resume by --session-id when continuity on" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "d-1" -- \
        "droid" "exec" "-o" "json" "--session-id" "d-1" "Test prompt content"
}

@test "droid build: no --session-id when continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "d-1" -- \
        "droid" "exec" "-o" "json" "Test prompt content"
}

@test "droid build: DROID_AUTO forwards --auto level" {
    export DROID_AUTO="high"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "" -- \
        "droid" "exec" "-o" "json" "--auto" "high" "Test prompt content"
}

@test "droid build: text output format omits -o json" {
    export CLAUDE_OUTPUT_FORMAT="text"
    harness_assert_argv agent_droid_build_command "$PROMPT_FILE" "" "" -- \
        "droid" "exec" "Test prompt content"
}

@test "droid build: loop context is prepended to the prompt" {
    agent_droid_build_command "$PROMPT_FILE" "Loop #5 context" ""
    local last=$(( ${#CLAUDE_CMD_ARGS[@]} - 1 ))
    [ "${CLAUDE_CMD_ARGS[$last]}" = $'Loop #5 context\n\nTest prompt content' ]
}

@test "droid build: missing prompt file returns 1" {
    run agent_droid_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

# ── Output normalization (via harness, recorded JSON fixture) ───────────────

@test "droid normalize: json fixture maps to the internal struct" {
    harness_normalize agent_droid_normalize_response "$FIXTURES/droid_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "droid-sess-1"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.error_count' "0"
}

@test "droid normalize: result becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_droid_normalize_response "$FIXTURES/droid_json.json" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Implemented the change"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "droid normalize: explicit error sets error_count" {
    local f="$TEST_DIR/err.json"
    echo '{"result":"failed","session_id":"s","error":"model overloaded"}' > "$f"
    harness_normalize agent_droid_normalize_response "$f" "$RESULT"
    harness_assert_field "$RESULT" '.error_count' "1"
}

@test "droid detect_format: JSON object is json, plain text is text" {
    [ "$(agent_droid_detect_format "$FIXTURES/droid_json.json")" = "json" ]
    printf 'just logs\n' > "$TEST_DIR/t.txt"
    [ "$(agent_droid_detect_format "$TEST_DIR/t.txt")" = "text" ]
}

# ── Capabilities ────────────────────────────────────────────────────────────

@test "droid capabilities: record is well-formed and reflects Droid's feature set" {
    harness_assert_capabilities_wellformed "$AGENT_DROID_CAPABILITIES"
    agent_droid_has_capability "supports_token_usage"
    agent_droid_has_capability "supports_session_resume"
    ! agent_droid_has_capability "supports_permission_denials"
    ! agent_droid_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=droid) ────────────────────────────────

@test "droid dispatch: registry routes build/normalize/capability to droid" {
    AGENT_PROVIDER="droid"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "droid" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "exec" ]

    agent_normalize_response "$FIXTURES/droid_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "droid-sess-1"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_api_limit_detection"
}
