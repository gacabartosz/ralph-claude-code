#!/usr/bin/env bats
# Degradation-path tests for the capability gates wired into ralph_loop.sh
# (multi-provider epic, #315 / MP.4b).
#
# Strategy: extract the REAL gated functions (can_make_call, should_exit_gracefully)
# from ralph_loop.sh via sed so we test the production code, not a drifting copy.
# Each gate is exercised with a supporting provider (claude -> feature active) and
# a non-supporting provider (an unregistered name supports nothing -> feature
# no-ops with a one-time WARN). Claude declares the full capability set, so these
# gates are no-ops for the default provider (verified by the rest of the suite).

load '../helpers/test_helper'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Capability dispatch + one-time-warn helper under test.
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"

    # Capture WARN output to a file so one-time behavior is assertable.
    WARN_FILE="$TEST_DIR/warns"
    : > "$WARN_FILE"
    log_status() { echo "[$1] $2" >> "$WARN_FILE"; }

    export CALL_COUNT_FILE="$TEST_DIR/.call_count"
    export TOKEN_COUNT_FILE="$TEST_DIR/.token_count"
    export EXIT_SIGNALS_FILE="$TEST_DIR/.exit_signals"
    export RESPONSE_ANALYSIS_FILE="$TEST_DIR/.response_analysis"
    export MAX_CONSECUTIVE_TEST_LOOPS=3
    export MAX_CONSECUTIVE_DONE_SIGNALS=2
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Extract a top-level function from ralph_loop.sh into the current shell.
# Uses awk (not sed): a sed address containing a literal `{` (e.g.
# /^fn() {/) is mis-parsed by BSD sed on macOS. awk reads from the function
# header line through its first column-0 closing brace.
load_real_fn() {
    local fn="$1"
    local body
    body=$(awk -v fn="$fn" '
        $0 ~ "^"fn"\\(\\)" {f=1}
        f {print}
        f && /^}/ {exit}
    ' "$RALPH_SCRIPT")
    eval "$body"
    # Fail loudly if extraction did not actually define the function, so a
    # missing function surfaces as a real error instead of a 127 false-pass.
    declare -f "$fn" >/dev/null || { echo "load_real_fn: failed to extract $fn" >&2; return 1; }
}

# ── Gate 1: token limiting (supports_token_usage) ───────────────────────────

@test "token gate: claude enforces MAX_TOKENS_PER_HOUR (blocks over budget)" {
    load_real_fn can_make_call
    AGENT_PROVIDER="claude"; _AGENT_CAP_WARNED=""
    MAX_CALLS_PER_HOUR=100; MAX_TOKENS_PER_HOUR=1000
    echo 0 > "$CALL_COUNT_FILE"; echo 5000 > "$TOKEN_COUNT_FILE"
    run can_make_call
    [ "$status" -eq 1 ]   # over token budget -> blocked (exact code, not 127)
}

@test "token gate: unsupported provider no-ops the token limit and warns once" {
    load_real_fn can_make_call
    AGENT_PROVIDER="ghost"; _AGENT_CAP_WARNED=""
    MAX_CALLS_PER_HOUR=100; MAX_TOKENS_PER_HOUR=1000
    echo 0 > "$CALL_COUNT_FILE"; echo 5000 > "$TOKEN_COUNT_FILE"
    # Two calls; the limit must not block, and the WARN must appear at most once.
    can_make_call; local rc1=$?
    can_make_call; local rc2=$?
    [ "$rc1" -eq 0 ]
    [ "$rc2" -eq 0 ]
    [ "$(grep -c "supports_token_usage" "$WARN_FILE")" -eq 1 ]
}

@test "token gate: claude still blocks on the invocation (call) limit" {
    load_real_fn can_make_call
    AGENT_PROVIDER="claude"; _AGENT_CAP_WARNED=""
    MAX_CALLS_PER_HOUR=10; MAX_TOKENS_PER_HOUR=0
    echo 10 > "$CALL_COUNT_FILE"; echo 0 > "$TOKEN_COUNT_FILE"
    run can_make_call
    [ "$status" -eq 1 ]   # call limit is provider-agnostic, always enforced
}

# ── Gate 2: permission-denial circuit breaker (supports_permission_denials) ──

prime_signals() {
    echo '{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}' > "$EXIT_SIGNALS_FILE"
}

@test "permission gate: claude halts on permission denials" {
    load_real_fn should_exit_gracefully
    prime_signals
    echo '{"analysis":{"has_permission_denials":true,"permission_denial_count":2,"denied_commands":["Bash(npm install)","Read"]}}' > "$RESPONSE_ANALYSIS_FILE"
    AGENT_PROVIDER="claude"; _AGENT_CAP_WARNED=""
    run should_exit_gracefully
    [[ "$output" == *"permission_denied"* ]]
}

@test "permission gate: unsupported provider skips denial check and warns once" {
    load_real_fn should_exit_gracefully
    prime_signals
    echo '{"analysis":{"has_permission_denials":true,"permission_denial_count":2,"denied_commands":["Bash(npm install)"]}}' > "$RESPONSE_ANALYSIS_FILE"
    AGENT_PROVIDER="ghost"; _AGENT_CAP_WARNED=""; : > "$WARN_FILE"
    local out
    out=$(should_exit_gracefully || true)
    # Denial path is gated off -> must NOT report permission_denied.
    [[ "$out" != *"permission_denied"* ]]
    # The degradation WARN (written to WARN_FILE via the log_status stub) appears once.
    [ "$(grep -c "supports_permission_denials" "$WARN_FILE")" -eq 1 ]
}

# ── Gate 3 & 4: wiring assertions (API-limit + session live in non-extractable
# functions execute_claude_code / main; confirm the gate is present with the
# correct capability so it can't be silently dropped or mis-keyed). ──────────

@test "api-limit gate: detection layers are wrapped by supports_api_limit_detection" {
    # The capability gate must appear before the Layer 2 rate_limit_event check.
    local gate_line layer_line
    gate_line=$(grep -n 'agent_capability_enabled "supports_api_limit_detection"' "$RALPH_SCRIPT" | head -1 | cut -d: -f1)
    layer_line=$(grep -n 'Layer 2: Structural JSON detection' "$RALPH_SCRIPT" | head -1 | cut -d: -f1)
    [ -n "$gate_line" ]
    [ -n "$layer_line" ]
    [ "$gate_line" -lt "$layer_line" ]
}

@test "session gate: continuity is gated on supports_session_resume" {
    grep -q 'agent_capability_enabled "supports_session_resume"' "$RALPH_SCRIPT"
}
