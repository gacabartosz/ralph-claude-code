#!/usr/bin/env bats
# Kilocode adapter tests (multi-provider epic, #321 / MP.10a).
#
# Validates the Kilocode adapter through the generic harness (#316): command-build
# argv, JSON normalization, the capability record, and registry dispatch when
# AGENT_PROVIDER=kilocode.

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

    export KILOCODE_CMD="kilocode"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Registration ────────────────────────────────────────────────────────────

@test "kilocode: provider is registered and selectable" {
    agent_provider_is_registered "kilocode"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"kilocode"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "kilocode build: basic invocation (kilocode --auto -j <prompt>)" {
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "" -- \
        "kilocode" "--auto" "-j" "Test prompt content"
}

@test "kilocode build: KILOCODE_CMD override is honored" {
    export KILOCODE_CMD="npx kilocode"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "" -- \
        "npx kilocode" "--auto" "-j" "Test prompt content"
}

@test "kilocode build: CLAUDE_MODEL maps to -mo" {
    export CLAUDE_MODEL="anthropic/claude-opus-4-8"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "" -- \
        "kilocode" "--auto" "-j" "-mo" "anthropic/claude-opus-4-8" "Test prompt content"
}

@test "kilocode build: continue-last adds -c when continuity on + prior session" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "k-1" -- \
        "kilocode" "--auto" "-j" "-c" "Test prompt content"
}

@test "kilocode build: no -c when continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "k-1" -- \
        "kilocode" "--auto" "-j" "Test prompt content"
}

@test "kilocode build: no -c when continuity on but no prior session" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "" -- \
        "kilocode" "--auto" "-j" "Test prompt content"
}

@test "kilocode build: text output format omits -j but keeps --auto" {
    export CLAUDE_OUTPUT_FORMAT="text"
    harness_assert_argv agent_kilocode_build_command "$PROMPT_FILE" "" "" -- \
        "kilocode" "--auto" "Test prompt content"
}

@test "kilocode build: never emits --yolo (security invariant)" {
    export CLAUDE_MODEL="anthropic/claude-opus-4-8"
    export CLAUDE_USE_CONTINUE="true"
    agent_kilocode_build_command "$PROMPT_FILE" "ctx" "k-1"
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "--yolo" ]
    done
}

@test "kilocode build: loop context is prepended to the prompt" {
    agent_kilocode_build_command "$PROMPT_FILE" "Loop #5 context" ""
    local last=$(( ${#CLAUDE_CMD_ARGS[@]} - 1 ))
    [ "${CLAUDE_CMD_ARGS[$last]}" = $'Loop #5 context\n\nTest prompt content' ]
}

@test "kilocode build: missing prompt file returns 1" {
    run agent_kilocode_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

# ── Output normalization (via harness, recorded JSON fixture) ───────────────

@test "kilocode normalize: json fixture maps to the internal struct" {
    harness_normalize agent_kilocode_normalize_response "$FIXTURES/kilocode_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "kilocode-sess-1"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.error_count' "0"
}

@test "kilocode normalize: result becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_kilocode_normalize_response "$FIXTURES/kilocode_json.json" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Implemented the change"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "kilocode normalize: explicit error sets error_count" {
    local f="$TEST_DIR/err.json"
    echo '{"result":"failed","session_id":"s","error":"model overloaded"}' > "$f"
    harness_normalize agent_kilocode_normalize_response "$f" "$RESULT"
    harness_assert_field "$RESULT" '.error_count' "1"
}

@test "kilocode detect_format: JSON object is json, plain text is text" {
    [ "$(agent_kilocode_detect_format "$FIXTURES/kilocode_json.json")" = "json" ]
    printf 'just logs\n' > "$TEST_DIR/t.txt"
    [ "$(agent_kilocode_detect_format "$TEST_DIR/t.txt")" = "text" ]
}

# ── Capabilities ────────────────────────────────────────────────────────────

@test "kilocode capabilities: record is well-formed and reflects Kilocode's feature set" {
    harness_assert_capabilities_wellformed "$AGENT_KILOCODE_CAPABILITIES"
    agent_kilocode_has_capability "supports_token_usage"
    agent_kilocode_has_capability "supports_session_resume"
    ! agent_kilocode_has_capability "supports_permission_denials"
    ! agent_kilocode_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=kilocode) ─────────────────────────────

@test "kilocode dispatch: registry routes build/normalize/capability to kilocode" {
    AGENT_PROVIDER="kilocode"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "kilocode" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "--auto" ]

    agent_normalize_response "$FIXTURES/kilocode_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "kilocode-sess-1"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_api_limit_detection"
}
