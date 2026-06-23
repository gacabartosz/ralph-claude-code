#!/usr/bin/env bash
# lib/plan_limit.sh - Plan-limit exhaustion detection + reset-time parsing (#102).
#
# Distinct from the 5-hour rolling rate limit (#183) and the "Extra Usage" quota
# (#100): this covers exhausting your subscription PLAN's usage, where Claude
# emits a message like "Claude usage limit reached. Your limit will reset at 9pm".
# The win for #102 is parsing the reset time so Ralph can print a clear
# "resume at <time>" message (and, in the loop, sleep/wait to it) instead of the
# error getting lost in the logs.
#
# Pure functions (bash 3.2 + grep/sed/tr, BSD + GNU portable). Wiring into
# execute_claude_code + the loop recovery path is the follow-up step.

# extract_reset_time <text> -> the reset time token (e.g. "9pm", "11:30pm",
# "21:00", "3am"), or empty if the text has no parseable "reset[s] [at] <time>".
extract_reset_time() {
    local text="$1"
    # Flatten newlines and lowercase first so the sed strip below needs no
    # case-insensitive flag (BSD sed has no `I` modifier).
    local t
    t=$(printf '%s' "$text" | tr '\n' ' ' | tr '[:upper:]' '[:lower:]')

    printf '%s' "$t" \
        | grep -oE 'resets?( at)?[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)?' \
        | head -1 \
        | sed -E 's/^resets?( at)?[[:space:]]+//' \
        | tr -d ' '
}

# plan_limit_message_present <text> -> 0 if the text contains a plan/usage-limit
# exhaustion message, else 1. Matches the plan-exhaustion wording specifically
# (not generic "rate limit"), so it can enrich the existing API-limit layers.
plan_limit_message_present() {
    local text="$1"
    printf '%s' "$text" | grep -qiE \
        "usage limit reached|reached your usage limit|plan limit reached|out of extra usage|limit will reset"
}

# detect_plan_limit_reset <output_file> -> 0 if a plan-limit message is present
# (echoing the parsed reset time, possibly empty), else 1. Applies the same
# tool-result noise filter as the other API-limit layers so echoed file content
# mentioning "usage limit" can't cause a false positive.
detect_plan_limit_reset() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 1

    local relevant
    relevant=$(tail -40 "$output_file" 2>/dev/null \
        | grep -vE '"type"[[:space:]]*:[[:space:]]*"user"' \
        | grep -v '"tool_result"' \
        | grep -v '"tool_use_id"')

    if plan_limit_message_present "$relevant"; then
        extract_reset_time "$relevant"
        return 0
    fi
    return 1
}

# format_plan_limit_message <reset_time> -> a clear user-facing message. When the
# reset time is known it tells the user when Ralph will resume; otherwise it says
# the reset time is unknown.
format_plan_limit_message() {
    local reset="$1"
    if [[ -n "$reset" ]]; then
        echo "🚫 Claude plan usage limit reached. Ralph will resume at ${reset}."
    else
        echo "🚫 Claude plan usage limit reached (reset time unknown)."
    fi
}
