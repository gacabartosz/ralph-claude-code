#!/usr/bin/env bats
# Unit tests for the Claude adapter's output-normalization half
# (multi-provider epic, #313 / MP.2).
#
# These are regression fixtures: the adapter normalizer must produce the same
# normalized analysis struct (.json_parse_result) that lib/response_analyzer.sh
# produced inline before the seam was extracted. claude.sh is sourced directly
# for isolated unit testing. Mirrors tests/unit/test_json_parsing.bats patterns.

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"

    OUT="$TEST_DIR/out.json"
    RESULT="$RALPH_DIR/.json_parse_result"

    # Source the adapter under test in isolation.
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/claude.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

field() { jq -r "$1" "$RESULT"; }

# ── Flat format ─────────────────────────────────────────────────────────────

@test "normalize: flat format populates the normalized struct" {
    cat > "$OUT" <<'EOF'
{"status":"COMPLETE","exit_signal":true,"work_type":"IMPLEMENTATION","files_modified":3,"confidence":40}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.status')" = "COMPLETE" ]
    [ "$(field '.exit_signal')" = "true" ]
    [ "$(field '.is_test_only')" = "false" ]
    [ "$(field '.has_completion_signal')" = "true" ]
    [ "$(field '.files_modified')" = "3" ]
    [ "$(field '.confidence')" = "40" ]
}

@test "normalize: flat TEST_ONLY work type sets is_test_only" {
    cat > "$OUT" <<'EOF'
{"status":"IN_PROGRESS","exit_signal":false,"work_type":"TEST_ONLY","files_modified":0}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.is_test_only')" = "true" ]
    [ "$(field '.exit_signal')" = "false" ]
}

@test "normalize: error_count over threshold sets is_stuck" {
    cat > "$OUT" <<'EOF'
{"status":"IN_PROGRESS","exit_signal":false,"error_count":6}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.is_stuck')" = "true" ]
    [ "$(field '.error_count')" = "6" ]
}

# ── Claude CLI object format ────────────────────────────────────────────────

@test "normalize: CLI object format extracts session_id and maps metadata" {
    cat > "$OUT" <<'EOF'
{"result":"Work done","sessionId":"sess-abc","metadata":{"files_changed":5,"has_errors":false,"completion_status":"complete"}}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.session_id')" = "sess-abc" ]
    [ "$(field '.files_modified')" = "5" ]
    # completion_status=complete promotes status to COMPLETE -> exit_signal true
    [ "$(field '.status')" = "COMPLETE" ]
    [ "$(field '.exit_signal')" = "true" ]
    [ "$(field '.summary')" = "Work done" ]
    # has("result") boosts confidence by 20 (base 0)
    [ "$(field '.confidence')" = "20" ]
}

@test "normalize: CLI object honors explicit EXIT_SIGNAL:false in RALPH_STATUS over STATUS:COMPLETE" {
    cat > "$OUT" <<'EOF'
{"result":"phase done\n---RALPH_STATUS---\nSTATUS: COMPLETE\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---","sessionId":"s1","metadata":{}}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    # Explicit EXIT_SIGNAL:false must win (Issue #224 / conflict resolution)
    [ "$(field '.exit_signal')" = "false" ]
}

# ── Claude CLI array / stream format ────────────────────────────────────────

@test "normalize: array format extracts result and falls back to init session_id" {
    cat > "$OUT" <<'EOF'
[{"type":"system","subtype":"init","session_id":"init-sess"},{"type":"assistant"},{"type":"result","result":"All done","is_error":false}]
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.session_id')" = "init-sess" ]
    [ "$(field '.summary')" = "All done" ]
}

@test "normalize: array format prefers result object's own session id" {
    cat > "$OUT" <<'EOF'
[{"type":"system","subtype":"init","session_id":"init-sess"},{"type":"result","result":"done","sessionId":"result-sess"}]
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.session_id')" = "result-sess" ]
}

# ── Permission denials (Issue #101) ─────────────────────────────────────────

@test "normalize: permission_denials are counted and summarized" {
    cat > "$OUT" <<'EOF'
{"result":"blocked","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"npm install"}},{"tool_name":"AskUserQuestion"}]}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.has_permission_denials')" = "true" ]
    [ "$(field '.permission_denial_count')" = "2" ]
    [ "$(field '.denied_commands[0]')" = "Bash(npm install)" ]
    [ "$(field '.denied_commands[1]')" = "AskUserQuestion" ]
}

@test "normalize: no permission denials -> false/0/[]" {
    cat > "$OUT" <<'EOF'
{"result":"ok","metadata":{}}
EOF
    agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$(field '.has_permission_denials')" = "false" ]
    [ "$(field '.permission_denial_count')" = "0" ]
    [ "$(field '.denied_commands | length')" = "0" ]
}

# ── Format detection + fallbacks ────────────────────────────────────────────

@test "detect_format: valid JSON object -> json" {
    printf '{"status":"OK"}\n' > "$OUT"
    [ "$(agent_claude_detect_format "$OUT")" = "json" ]
}

@test "detect_format: plain text -> text" {
    printf 'just some log output\nnot json\n' > "$OUT"
    [ "$(agent_claude_detect_format "$OUT")" = "text" ]
}

@test "detect_format: empty file -> text" {
    : > "$OUT"
    [ "$(agent_claude_detect_format "$OUT")" = "text" ]
}

@test "normalize: invalid JSON returns failure (caller falls back to text)" {
    printf 'not json at all\n' > "$OUT"
    run agent_claude_normalize_response "$OUT" "$RESULT"
    [ "$status" -ne 0 ]
}

@test "detect_format: JSONL size guard falls back to text when result marker absent" {
    export RALPH_JSONL_SAFE_MAX_BYTES=100
    # >100 bytes, starts with '[' but no "type":"result" marker => truncated stream
    { printf '['; for i in $(seq 1 40); do printf '{"type":"assistant","i":%d},' "$i"; done; printf '{"type":"x"}]'; } > "$OUT"
    [ "$(_file_size_bytes "$OUT")" -gt 100 ]
    [ "$(agent_claude_detect_format "$OUT")" = "text" ]
}

@test "detect_format: large stream WITH result marker still parses as json" {
    export RALPH_JSONL_SAFE_MAX_BYTES=100
    { printf '['; for i in $(seq 1 40); do printf '{"type":"assistant","i":%d},' "$i"; done; printf '{"type":"result","result":"done"}]'; } > "$OUT"
    [ "$(_file_size_bytes "$OUT")" -gt 100 ]
    [ "$(agent_claude_detect_format "$OUT")" = "json" ]
}
