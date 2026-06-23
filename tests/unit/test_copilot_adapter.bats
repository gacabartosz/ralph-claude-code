#!/usr/bin/env bats
# Copilot adapter tests (multi-provider epic, #322 / MP.11a).
#
# Copilot is the DEGRADED, TEXT-ONLY provider. Validates the adapter through the
# generic harness (#316): command-build argv, TEXT normalization, the (minimal)
# capability record, and registry dispatch when AGENT_PROVIDER=copilot.

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

    export COPILOT_CMD="copilot"
    export CLAUDE_OUTPUT_FORMAT="json"   # ignored by Copilot (text-only)
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL COPILOT_ALLOWED_TOOLS COPILOT_DENIED_TOOLS AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Registration ────────────────────────────────────────────────────────────

@test "copilot: provider is registered and selectable" {
    agent_provider_is_registered "copilot"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"copilot"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "copilot build: basic invocation (copilot -s -p <prompt>)" {
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "" -- \
        "copilot" "-s" "-p" "Test prompt content"
}

@test "copilot build: text-only — json output format does not add a json flag" {
    export CLAUDE_OUTPUT_FORMAT="json"
    agent_copilot_build_command "$PROMPT_FILE" "" ""
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "-j" ]
        [ "$arg" != "--json" ]
        [ "$arg" != "-o" ]
    done
}

@test "copilot build: COPILOT_CMD override is honored" {
    export COPILOT_CMD="npx @github/copilot"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "" -- \
        "npx @github/copilot" "-s" "-p" "Test prompt content"
}

@test "copilot build: CLAUDE_MODEL maps to --model" {
    export CLAUDE_MODEL="gpt-5"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "" -- \
        "copilot" "-s" "--model" "gpt-5" "-p" "Test prompt content"
}

@test "copilot build: resume by --resume <id> when continuity on" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "c-1" -- \
        "copilot" "-s" "--resume" "c-1" "-p" "Test prompt content"
}

@test "copilot build: no --resume when continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "c-1" -- \
        "copilot" "-s" "-p" "Test prompt content"
}

@test "copilot build: COPILOT_ALLOWED_TOOLS becomes one --allow-tool per tool" {
    export COPILOT_ALLOWED_TOOLS="shell,write"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "" -- \
        "copilot" "-s" "--allow-tool" "shell" "--allow-tool" "write" \
        "-p" "Test prompt content"
}

@test "copilot build: COPILOT_DENIED_TOOLS becomes one --deny-tool per tool" {
    export COPILOT_DENIED_TOOLS="network"
    harness_assert_argv agent_copilot_build_command "$PROMPT_FILE" "" "" -- \
        "copilot" "-s" "--deny-tool" "network" "-p" "Test prompt content"
}

@test "copilot build: never emits --allow-all (security invariant)" {
    export COPILOT_ALLOWED_TOOLS="shell"
    export COPILOT_ALLOW_ALL="true"   # even if a user sets it, never emitted
    export CLAUDE_MODEL="gpt-5"
    export CLAUDE_USE_CONTINUE="true"
    agent_copilot_build_command "$PROMPT_FILE" "ctx" "c-1"
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "--allow-all" ]
    done
}

@test "copilot build: loop context is prepended to the -p prompt" {
    agent_copilot_build_command "$PROMPT_FILE" "Loop #5 context" ""
    local last=$(( ${#CLAUDE_CMD_ARGS[@]} - 1 ))
    [ "${CLAUDE_CMD_ARGS[$last]}" = $'Loop #5 context\n\nTest prompt content' ]
    [ "${CLAUDE_CMD_ARGS[$(( last - 1 ))]}" = "-p" ]
}

@test "copilot build: missing prompt file returns 1" {
    run agent_copilot_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

# ── Output normalization (TEXT mode) ────────────────────────────────────────

@test "copilot detect_format: always text (no structured output)" {
    [ "$(agent_copilot_detect_format "$FIXTURES/copilot_text.txt")" = "text" ]
    # even on a JSON-looking file, Copilot reports text
    echo '{"result":"x"}' > "$TEST_DIR/looks.json"
    [ "$(agent_copilot_detect_format "$TEST_DIR/looks.json")" = "text" ]
}

@test "copilot normalize: text fixture maps RALPH_STATUS to the internal struct" {
    harness_normalize agent_copilot_normalize_response "$FIXTURES/copilot_text.txt" "$RESULT"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.session_id' ""
}

@test "copilot normalize: result text becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_copilot_normalize_response "$FIXTURES/copilot_text.txt" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Implemented the change"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "copilot normalize: plain text without RALPH_STATUS does not signal exit" {
    printf 'just some logs, still working\n' > "$TEST_DIR/plain.txt"
    harness_normalize agent_copilot_normalize_response "$TEST_DIR/plain.txt" "$RESULT"
    harness_assert_field "$RESULT" '.exit_signal' "false"
    harness_assert_field "$RESULT" '.has_completion_signal' "false"
}

# ── Capabilities (most degraded adapter) ────────────────────────────────────

@test "copilot capabilities: record is well-formed; only session resume supported" {
    harness_assert_capabilities_wellformed "$AGENT_COPILOT_CAPABILITIES"
    agent_copilot_has_capability "supports_session_resume"
    ! agent_copilot_has_capability "supports_token_usage"
    ! agent_copilot_has_capability "supports_permission_denials"
    ! agent_copilot_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=copilot) ──────────────────────────────

@test "copilot dispatch: registry routes build/detect/normalize/capability to copilot" {
    AGENT_PROVIDER="copilot"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "copilot" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "-s" ]

    [ "$(agent_detect_format "$FIXTURES/copilot_text.txt")" = "text" ]

    agent_normalize_response "$FIXTURES/copilot_text.txt" "$RESULT"
    harness_assert_field "$RESULT" '.exit_signal' "true"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_token_usage"
}
