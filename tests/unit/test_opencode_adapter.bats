#!/usr/bin/env bats
# OpenCode adapter tests (multi-provider epic, #319 / MP.8a).
#
# Validates the OpenCode adapter through the generic harness (#316): command-build
# argv, JSONL normalization, the capability record, and registry dispatch when
# AGENT_PROVIDER=opencode. Includes the cross-adapter security invariant: the
# adapter never emits --dangerously-skip-permissions.

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

    export OPENCODE_CMD="opencode"
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

@test "opencode: provider is registered and selectable" {
    agent_provider_is_registered "opencode"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"opencode"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "opencode build: basic invocation (opencode run --format json <prompt>)" {
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "" -- \
        "opencode" "run" "--format" "json" "Test prompt content"
}

@test "opencode build: OPENCODE_CMD override is honored" {
    export OPENCODE_CMD="npx opencode-ai"
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "" -- \
        "npx opencode-ai" "run" "--format" "json" "Test prompt content"
}

@test "opencode build: CLAUDE_MODEL maps to -m (provider/model)" {
    export CLAUDE_MODEL="anthropic/claude-sonnet-4-6"
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "" -- \
        "opencode" "run" "--format" "json" "-m" "anthropic/claude-sonnet-4-6" "Test prompt content"
}

@test "opencode build: resume by -s session id when continuity on" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "oc-1" -- \
        "opencode" "run" "--format" "json" "-s" "oc-1" "Test prompt content"
}

@test "opencode build: no -s when continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "oc-1" -- \
        "opencode" "run" "--format" "json" "Test prompt content"
}

@test "opencode build: text output format omits --format json" {
    export CLAUDE_OUTPUT_FORMAT="text"
    harness_assert_argv agent_opencode_build_command "$PROMPT_FILE" "" "" -- \
        "opencode" "run" "Test prompt content"
}

@test "opencode build: loop context is prepended to the prompt" {
    agent_opencode_build_command "$PROMPT_FILE" "Loop #5 context" ""
    local last=$(( ${#CLAUDE_CMD_ARGS[@]} - 1 ))
    [ "${CLAUDE_CMD_ARGS[$last]}" = $'Loop #5 context\n\nTest prompt content' ]
}

@test "opencode build: missing prompt file returns 1" {
    run agent_opencode_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

@test "opencode build: never emits --dangerously-skip-permissions (security invariant)" {
    export CLAUDE_MODEL="anthropic/claude"
    export CLAUDE_USE_CONTINUE="true"
    agent_opencode_build_command "$PROMPT_FILE" "ctx" "oc-1"
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "--dangerously-skip-permissions" ]
    done
}

# ── Output normalization (via harness, recorded JSONL fixture) ──────────────

@test "opencode normalize: JSONL fixture maps to the internal struct" {
    harness_normalize agent_opencode_normalize_response "$FIXTURES/opencode_jsonl.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "oc-sess-1"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.error_count' "0"
}

@test "opencode normalize: assistant text becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_opencode_normalize_response "$FIXTURES/opencode_jsonl.json" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Refactored the module"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "opencode normalize: error events raise error_count and is_stuck over threshold" {
    local f="$TEST_DIR/errs.jsonl"
    {
        echo '{"type":"session.updated","sessionID":"s"}'
        for i in 1 2 3 4 5 6; do echo '{"type":"error","message":"boom"}'; done
        echo '{"type":"message","role":"assistant","text":"tried"}'
    } > "$f"
    harness_normalize agent_opencode_normalize_response "$f" "$RESULT"
    harness_assert_field "$RESULT" '.error_count' "6"
    harness_assert_field "$RESULT" '.is_stuck' "true"
}

@test "opencode detect_format: JSONL stream is json, plain text is text" {
    [ "$(agent_opencode_detect_format "$FIXTURES/opencode_jsonl.json")" = "json" ]
    printf 'just logs\n' > "$TEST_DIR/t.txt"
    [ "$(agent_opencode_detect_format "$TEST_DIR/t.txt")" = "text" ]
}

# ── Capabilities ────────────────────────────────────────────────────────────

@test "opencode capabilities: record is well-formed and reflects OpenCode's feature set" {
    harness_assert_capabilities_wellformed "$AGENT_OPENCODE_CAPABILITIES"
    agent_opencode_has_capability "supports_token_usage"
    agent_opencode_has_capability "supports_session_resume"
    ! agent_opencode_has_capability "supports_permission_denials"
    ! agent_opencode_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=opencode) ─────────────────────────────

@test "opencode dispatch: registry routes build/normalize/capability to opencode" {
    AGENT_PROVIDER="opencode"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "opencode" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "run" ]

    agent_normalize_response "$FIXTURES/opencode_jsonl.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "oc-sess-1"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_api_limit_detection"
}
