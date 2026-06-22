#!/usr/bin/env bats
# Gemini adapter tests (multi-provider epic, #318 / MP.7a).
#
# Validates the Gemini adapter through the generic harness (#316): command-build
# argv (incl. the race-free pre-assigned session path), JSON normalization, the
# capability record, and registry dispatch when AGENT_PROVIDER=gemini.

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

    export GEMINI_CMD="gemini"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL GEMINI_APPROVAL_MODE AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Registration ────────────────────────────────────────────────────────────

@test "gemini: provider is registered and selectable" {
    agent_provider_is_registered "gemini"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"gemini"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "gemini build: basic invocation (gemini -o json -p <prompt>)" {
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "" -- \
        "gemini" "-o" "json" "-p" "Test prompt content"
}

@test "gemini build: text output format omits -o json" {
    export CLAUDE_OUTPUT_FORMAT="text"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "" -- \
        "gemini" "-p" "Test prompt content"
}

@test "gemini build: GEMINI_CMD override is honored" {
    export GEMINI_CMD="npx @google/gemini-cli"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "" -- \
        "npx @google/gemini-cli" "-o" "json" "-p" "Test prompt content"
}

@test "gemini build: CLAUDE_MODEL maps to -m" {
    export CLAUDE_MODEL="gemini-2.5-pro"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "" -- \
        "gemini" "-o" "json" "-m" "gemini-2.5-pro" "-p" "Test prompt content"
}

@test "gemini build: preassigned session + resume when continuity on" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "gem-sess-1" -- \
        "gemini" "-o" "json" "--session-id" "gem-sess-1" "-r" "-p" "Test prompt content"
}

@test "gemini build: no session flags when continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "gem-sess-1" -- \
        "gemini" "-o" "json" "-p" "Test prompt content"
}

@test "gemini build: approval mode forwarded when set" {
    export GEMINI_APPROVAL_MODE="auto_edit"
    harness_assert_argv agent_gemini_build_command "$PROMPT_FILE" "" "" -- \
        "gemini" "-o" "json" "--approval-mode" "auto_edit" "-p" "Test prompt content"
}

@test "gemini build: never forwards the dangerous yolo approval mode" {
    export GEMINI_APPROVAL_MODE="yolo"
    agent_gemini_build_command "$PROMPT_FILE" "" ""
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "yolo" ]
        [ "$arg" != "--approval-mode" ]
    done
}

@test "gemini build: loop context is prepended to the prompt" {
    agent_gemini_build_command "$PROMPT_FILE" "Loop #5 context" ""
    local last=$(( ${#CLAUDE_CMD_ARGS[@]} - 1 ))
    [ "${CLAUDE_CMD_ARGS[$last]}" = $'Loop #5 context\n\nTest prompt content' ]
    [ "${CLAUDE_CMD_ARGS[$(( last - 1 ))]}" = "-p" ]
}

@test "gemini build: missing prompt file returns 1" {
    run agent_gemini_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

# ── Output normalization (via harness, recorded JSON fixture) ───────────────

@test "gemini normalize: json fixture maps to the internal struct" {
    harness_normalize agent_gemini_normalize_response "$FIXTURES/gemini_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "gemini-sess-1"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.error_count' "0"
}

@test "gemini normalize: response becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_gemini_normalize_response "$FIXTURES/gemini_json.json" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Implemented the feature"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "gemini normalize: explicit error sets error_count" {
    local f="$TEST_DIR/err.json"
    echo '{"response":"failed","session_id":"s","error":"quota exceeded"}' > "$f"
    harness_normalize agent_gemini_normalize_response "$f" "$RESULT"
    harness_assert_field "$RESULT" '.error_count' "1"
}

@test "gemini detect_format: JSON object is json, plain text is text" {
    [ "$(agent_gemini_detect_format "$FIXTURES/gemini_json.json")" = "json" ]
    printf 'just logs\n' > "$TEST_DIR/t.txt"
    [ "$(agent_gemini_detect_format "$TEST_DIR/t.txt")" = "text" ]
}

# ── Capabilities ────────────────────────────────────────────────────────────

@test "gemini capabilities: record is well-formed and reflects Gemini's feature set" {
    harness_assert_capabilities_wellformed "$AGENT_GEMINI_CAPABILITIES"
    agent_gemini_has_capability "supports_token_usage"
    agent_gemini_has_capability "supports_session_resume"
    ! agent_gemini_has_capability "supports_permission_denials"
    ! agent_gemini_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=gemini) ───────────────────────────────

@test "gemini dispatch: registry routes build/normalize/capability to gemini" {
    AGENT_PROVIDER="gemini"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "gemini" ]

    agent_normalize_response "$FIXTURES/gemini_json.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "gemini-sess-1"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_api_limit_detection"
}
