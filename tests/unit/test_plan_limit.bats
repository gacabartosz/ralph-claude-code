#!/usr/bin/env bats
# Unit tests for lib/plan_limit.sh - plan-limit exhaustion detection + reset-time
# parsing (Issue #102).

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/plan_limit.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── extract_reset_time ───────────────────────────────────────────────────────

@test "extract_reset_time: 'reset at 9pm' -> 9pm" {
    [ "$(extract_reset_time 'Your limit will reset at 9pm')" = "9pm" ]
}

@test "extract_reset_time: 'resets 9pm' -> 9pm" {
    [ "$(extract_reset_time "out of extra usage · resets 9pm")" = "9pm" ]
}

@test "extract_reset_time: HH:MM with meridiem -> 11:30pm" {
    [ "$(extract_reset_time 'usage limit reached, resets at 11:30pm')" = "11:30pm" ]
}

@test "extract_reset_time: 24-hour clock -> 21:00" {
    [ "$(extract_reset_time 'limit will reset at 21:00')" = "21:00" ]
}

@test "extract_reset_time: space before meridiem is normalized -> 3am" {
    [ "$(extract_reset_time 'resets 3 am')" = "3am" ]
}

@test "extract_reset_time: uppercase is lowercased -> 9pm" {
    [ "$(extract_reset_time 'RESETS AT 9PM')" = "9pm" ]
}

@test "extract_reset_time: no time present -> empty" {
    [ -z "$(extract_reset_time 'Claude usage limit reached')" ]
}

# ── plan_limit_message_present ───────────────────────────────────────────────

@test "plan_limit_message_present: matches plan-exhaustion wording" {
    plan_limit_message_present "Claude usage limit reached"
    plan_limit_message_present "you've reached your usage limit"
    plan_limit_message_present "out of extra usage"
    plan_limit_message_present "your limit will reset at 9pm"
}

@test "plan_limit_message_present: ignores unrelated text" {
    ! plan_limit_message_present "everything is fine, tests passing"
}

# ── detect_plan_limit_reset (file + noise filter) ────────────────────────────

@test "detect_plan_limit_reset: finds message and echoes reset time" {
    printf 'working...\nClaude usage limit reached. Your limit will reset at 9pm\n' > out.txt
    run detect_plan_limit_reset out.txt
    [ "$status" -eq 0 ]
    [ "$output" = "9pm" ]
}

@test "detect_plan_limit_reset: message without a time still detected (empty reset)" {
    printf 'Claude usage limit reached\n' > out.txt
    run detect_plan_limit_reset out.txt
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "detect_plan_limit_reset: no plan-limit message -> non-zero" {
    printf 'all good here\n' > out.txt
    run detect_plan_limit_reset out.txt
    [ "$status" -ne 0 ]
}

@test "detect_plan_limit_reset: ignores echoed tool-result file content (no false positive)" {
    # A tool_result line echoing project text that mentions a usage limit must not trip detection
    printf '{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"x","content":"docs say: usage limit reached resets 9pm"}]}}\n' > out.txt
    run detect_plan_limit_reset out.txt
    [ "$status" -ne 0 ]
}

@test "detect_plan_limit_reset: missing file -> non-zero" {
    run detect_plan_limit_reset does-not-exist.txt
    [ "$status" -ne 0 ]
}

# ── format_plan_limit_message ────────────────────────────────────────────────

@test "format_plan_limit_message: includes the reset time when known" {
    local msg
    msg=$(format_plan_limit_message "9pm")
    [[ "$msg" == *"resume at 9pm"* ]]
    [[ "$msg" == *"plan usage limit reached"* ]]
}

@test "format_plan_limit_message: notes unknown reset time when empty" {
    local msg
    msg=$(format_plan_limit_message "")
    [[ "$msg" == *"reset time unknown"* ]]
}
