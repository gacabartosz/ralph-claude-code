#!/usr/bin/env bats
# Codex adapter pilot tests (multi-provider epic, #317 / MP.6).
#
# Validates the first non-Claude adapter through the generic harness (#316):
# command-build argv, JSONL-fixture normalization, and the capability record —
# plus registry dispatch when AGENT_PROVIDER=codex. Proves the seam works
# end-to-end for a provider with a different CLI shape and output format.

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

    export CODEX_CMD="codex"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL CLAUDE_EFFORT AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── Registration ────────────────────────────────────────────────────────────

@test "codex: provider is registered and selectable" {
    agent_provider_is_registered "codex"
    [[ "$AGENT_REGISTERED_PROVIDERS" == *"codex"* ]]
}

# ── Command construction (via harness) ──────────────────────────────────────

@test "codex build: basic invocation (codex exec --json <prompt>)" {
    harness_assert_argv agent_codex_build_command "$PROMPT_FILE" "" "" -- \
        "codex" "exec" "--json" "Test prompt content"
}

@test "codex build: CODEX_CMD override is honored" {
    export CODEX_CMD="npx @openai/codex"
    harness_assert_argv agent_codex_build_command "$PROMPT_FILE" "" "" -- \
        "npx @openai/codex" "exec" "--json" "Test prompt content"
}

@test "codex build: CLAUDE_MODEL maps to -m" {
    export CLAUDE_MODEL="gpt-5-codex"
    harness_assert_argv agent_codex_build_command "$PROMPT_FILE" "" "" -- \
        "codex" "exec" "--json" "-m" "gpt-5-codex" "Test prompt content"
}

@test "codex build: resume subcommand when continuity on and session id present" {
    export CLAUDE_USE_CONTINUE="true"
    harness_assert_argv agent_codex_build_command "$PROMPT_FILE" "" "codex-sess-1" -- \
        "codex" "exec" "resume" "codex-sess-1" "--json" "Test prompt content"
}

@test "codex build: no resume when session id present but continuity off" {
    export CLAUDE_USE_CONTINUE="false"
    harness_assert_argv agent_codex_build_command "$PROMPT_FILE" "" "codex-sess-1" -- \
        "codex" "exec" "--json" "Test prompt content"
}

@test "codex build: loop context is prepended to the prompt" {
    agent_codex_build_command "$PROMPT_FILE" "Loop #5 context" ""
    # codex exec --json <ctx\n\nprompt>
    [ "${#CLAUDE_CMD_ARGS[@]}" -eq 4 ]
    [ "${CLAUDE_CMD_ARGS[3]}" = $'Loop #5 context\n\nTest prompt content' ]
}

@test "codex build: missing prompt file returns 1" {
    run agent_codex_build_command "$TEST_DIR/nope.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

@test "codex build: never emits the dangerous bypass flag" {
    export CLAUDE_MODEL="gpt-5-codex"
    export CLAUDE_USE_CONTINUE="true"
    agent_codex_build_command "$PROMPT_FILE" "ctx" "s1"
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [[ "$arg" != *"--dangerously-bypass"* ]]
    done
}

# ── Output normalization (via harness, recorded JSONL fixture) ──────────────

@test "codex normalize: JSONL fixture maps to the internal struct" {
    harness_normalize agent_codex_normalize_response "$FIXTURES/codex_jsonl.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "codex-sess-1"
    harness_assert_field "$RESULT" '.status' "COMPLETE"
    harness_assert_field "$RESULT" '.exit_signal' "true"
    harness_assert_field "$RESULT" '.has_completion_signal' "true"
    harness_assert_field "$RESULT" '.has_permission_denials' "false"
    harness_assert_field "$RESULT" '.error_count' "0"
}

@test "codex normalize: assistant text becomes the summary (RALPH_STATUS carrier)" {
    harness_normalize agent_codex_normalize_response "$FIXTURES/codex_jsonl.json" "$RESULT"
    [[ "$(jq -r '.summary' "$RESULT")" == *"Implemented the feature"* ]]
    [[ "$(jq -r '.summary' "$RESULT")" == *"RALPH_STATUS"* ]]
}

@test "codex normalize: error events raise error_count and is_stuck over threshold" {
    local f="$TEST_DIR/errs.jsonl"
    {
        echo '{"type":"session","session_id":"s"}'
        for i in 1 2 3 4 5 6; do echo '{"type":"error","message":"boom"}'; done
        echo '{"type":"assistant","text":"tried"}'
    } > "$f"
    harness_normalize agent_codex_normalize_response "$f" "$RESULT"
    harness_assert_field "$RESULT" '.error_count' "6"
    harness_assert_field "$RESULT" '.is_stuck' "true"
}

@test "codex detect_format: JSONL stream is json, plain text is text" {
    [ "$(agent_codex_detect_format "$FIXTURES/codex_jsonl.json")" = "json" ]
    printf 'just logs\nno json\n' > "$TEST_DIR/t.txt"
    [ "$(agent_codex_detect_format "$TEST_DIR/t.txt")" = "text" ]
}

# ── Capabilities ────────────────────────────────────────────────────────────

@test "codex capabilities: record is well-formed and reflects Codex's feature set" {
    harness_assert_capabilities_wellformed "$AGENT_CODEX_CAPABILITIES"
    agent_codex_has_capability "supports_token_usage"
    agent_codex_has_capability "supports_session_resume"
    # Codex maps permission to sandbox/approval and has no 5-hour API-limit signal.
    ! agent_codex_has_capability "supports_permission_denials"
    ! agent_codex_has_capability "supports_api_limit_detection"
}

# ── Registry dispatch (AGENT_PROVIDER=codex) ────────────────────────────────

@test "codex dispatch: registry routes build/normalize/capability to codex" {
    AGENT_PROVIDER="codex"
    agent_build_command "$PROMPT_FILE" "" ""
    [ "${CLAUDE_CMD_ARGS[0]}" = "codex" ]
    [ "${CLAUDE_CMD_ARGS[1]}" = "exec" ]

    agent_normalize_response "$FIXTURES/codex_jsonl.json" "$RESULT"
    harness_assert_field "$RESULT" '.session_id' "codex-sess-1"

    agent_has_capability "supports_session_resume"
    ! agent_has_capability "supports_permission_denials"
}
