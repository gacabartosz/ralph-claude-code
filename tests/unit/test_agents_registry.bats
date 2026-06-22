#!/usr/bin/env bats
# Unit tests for the agent provider registry + Claude reference adapter
# (multi-provider epic, #312 / MP.1).
#
# The Claude adapter is the reference implementation and MUST reproduce
# ralph_loop.sh's historical build_claude_command argv byte-for-byte. These are
# the golden-args tests for the command-construction seam: they assert exact
# CLAUDE_CMD_ARGS contents via positional access, mirroring test_cli_modern.bats.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    PROMPT_FILE="$TEST_DIR/PROMPT.md"
    printf 'Test prompt content\n' > "$PROMPT_FILE"

    # Known-good defaults so each test starts from a clean, explicit state.
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_ALLOWED_TOOLS=""
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL CLAUDE_EFFORT AGENT_PROVIDER

    # Source the seam under test. registry.sh sources claude.sh and defines
    # both agent_build_command (dispatch) and agent_claude_build_command.
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Helper: assert CLAUDE_CMD_ARGS matches the expected argv exactly (length +
# every element), giving a byte-for-byte golden comparison.
assert_args() {
    local -a expected=("$@")
    [ "${#CLAUDE_CMD_ARGS[@]}" -eq "${#expected[@]}" ] || {
        echo "length mismatch: got ${#CLAUDE_CMD_ARGS[@]} (${CLAUDE_CMD_ARGS[*]}), want ${#expected[@]} (${expected[*]})"
        return 1
    }
    local i
    for i in "${!expected[@]}"; do
        [ "${CLAUDE_CMD_ARGS[$i]}" = "${expected[$i]}" ] || {
            echo "element $i mismatch: got '${CLAUDE_CMD_ARGS[$i]}', want '${expected[$i]}'"
            return 1
        }
    done
}

# ── Registry wiring ──────────────────────────────────────────────────────────

@test "registry defaults AGENT_PROVIDER to claude" {
    [ "$AGENT_PROVIDER" = "claude" ]
}

@test "registry defines the dispatch and claude adapter functions" {
    declare -f agent_build_command >/dev/null
    declare -f agent_claude_build_command >/dev/null
}

@test "agent_build_command dispatches to the claude adapter" {
    agent_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--output-format" "json" "-p" "Test prompt content"
}

@test "agent_build_command fails for an unknown provider" {
    AGENT_PROVIDER="nope"
    run agent_build_command "$PROMPT_FILE" "" ""
    assert_failure
    [[ "$output" == *"Unknown AGENT_PROVIDER"* ]]
}

# ── Golden argv: Claude reference adapter ───────────────────────────────────

@test "claude adapter: basic invocation (json, no tools, no session)" {
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: text output format omits --output-format" {
    export CLAUDE_OUTPUT_FORMAT="text"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "-p" "Test prompt content"
}

@test "claude adapter: honors CLAUDE_CODE_CMD override" {
    export CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "npx @anthropic-ai/claude-code" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: CLAUDE_MODEL adds --model before output format" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--model" "claude-sonnet-4-6" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: CLAUDE_EFFORT adds --effort" {
    export CLAUDE_EFFORT="high"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--effort" "high" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: model and effort together, in order" {
    export CLAUDE_MODEL="claude-opus-4-8"
    export CLAUDE_EFFORT="low"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--model" "claude-opus-4-8" "--effort" "low" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: allowed tools split into separate argv elements, trimmed" {
    export CLAUDE_ALLOWED_TOOLS="Write, Read ,Bash(git add *)"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--output-format" "json" \
        "--allowedTools" "Write" "Read" "Bash(git add *)" \
        "-p" "Test prompt content"
}

@test "claude adapter: --resume only when CLAUDE_USE_CONTINUE=true and session id present" {
    export CLAUDE_USE_CONTINUE="true"
    agent_claude_build_command "$PROMPT_FILE" "" "sess-123"
    assert_args "claude" "--output-format" "json" "--resume" "sess-123" "-p" "Test prompt content"
}

@test "claude adapter: no --resume when continue=true but session id empty" {
    export CLAUDE_USE_CONTINUE="true"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    assert_args "claude" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: no --resume when session id present but continue=false" {
    export CLAUDE_USE_CONTINUE="false"
    agent_claude_build_command "$PROMPT_FILE" "" "sess-123"
    assert_args "claude" "--output-format" "json" "-p" "Test prompt content"
}

@test "claude adapter: loop context becomes --append-system-prompt" {
    agent_claude_build_command "$PROMPT_FILE" "Loop #5 context" ""
    assert_args "claude" "--output-format" "json" \
        "--append-system-prompt" "Loop #5 context" \
        "-p" "Test prompt content"
}

@test "claude adapter: full flag combination in canonical order" {
    export CLAUDE_MODEL="claude-sonnet-4-6"
    export CLAUDE_EFFORT="high"
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Bash(git commit *)"
    export CLAUDE_USE_CONTINUE="true"
    agent_claude_build_command "$PROMPT_FILE" "ctx" "sess-9"
    assert_args "claude" \
        "--model" "claude-sonnet-4-6" \
        "--effort" "high" \
        "--output-format" "json" \
        "--allowedTools" "Write" "Read" "Bash(git commit *)" \
        "--resume" "sess-9" \
        "--append-system-prompt" "ctx" \
        "-p" "Test prompt content"
}

@test "claude adapter: multiline prompt content is preserved as one argv element" {
    printf 'line one\nline two\nline three\n' > "$PROMPT_FILE"
    agent_claude_build_command "$PROMPT_FILE" "" ""
    [ "${#CLAUDE_CMD_ARGS[@]}" -eq 5 ]
    [ "${CLAUDE_CMD_ARGS[3]}" = "-p" ]
    [ "${CLAUDE_CMD_ARGS[4]}" = $'line one\nline two\nline three' ]
}

@test "claude adapter: missing prompt file returns 1 after resetting args" {
    run agent_claude_build_command "$TEST_DIR/does-not-exist.md" "" ""
    assert_failure
    [[ "$output" == *"not found"* ]]
}

# ── Security invariant ──────────────────────────────────────────────────────

@test "claude adapter: never emits --dangerously-skip-permissions" {
    export CLAUDE_MODEL="claude-opus-4-8"
    export CLAUDE_EFFORT="high"
    export CLAUDE_ALLOWED_TOOLS="Write,Read,Bash(git add *)"
    export CLAUDE_USE_CONTINUE="true"
    agent_claude_build_command "$PROMPT_FILE" "ctx" "sess-1"
    local arg
    for arg in "${CLAUDE_CMD_ARGS[@]}"; do
        [ "$arg" != "--dangerously-skip-permissions" ]
    done
}
