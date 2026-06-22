#!/usr/bin/env bash
# lib/agents/opencode.sh - OpenCode CLI adapter (multi-provider epic, #319 / MP.8).
#
# Implements the same contract as the Claude/Codex/Gemini adapters:
#   agent_opencode_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_opencode_detect_format      output_file -> "json"|"text"
#   agent_opencode_normalize_response output_file [result_file] -> normalized struct
#   AGENT_OPENCODE_CAPABILITIES / agent_opencode_has_capability
#
# OpenCode CLI shape:
#   opencode run --format json [-m <provider/model>] [-s <session-id>] <prompt>
# `--format json` streams JSONL events (one JSON object per line). Sessions resume
# by id via `-s`. The assistant text carries Ralph's RALPH_STATUS block, which
# drives exit detection (provider-independent).

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_opencode_build_command - populate CLAUDE_CMD_ARGS for the OpenCode CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses CLAUDE_MODEL (-> -m), CLAUDE_USE_CONTINUE (-> -s <id> resume),
# CLAUDE_OUTPUT_FORMAT (json -> --format json), plus OPENCODE_CMD (binary).
# OpenCode run has no system-prompt flag, so loop_context is prepended.
# Security: NEVER emits --dangerously-skip-permissions, even though OpenCode
# offers it — Ralph relies on the permission flow, matching the Claude/Codex/
# Gemini dangerous-flag rule.
agent_opencode_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local opencode_cmd="${OPENCODE_CMD:-opencode}"

    CLAUDE_CMD_ARGS=("$opencode_cmd" "run")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Structured event output (mirror the json/text switch).
    if [[ "${CLAUDE_OUTPUT_FORMAT:-json}" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--format" "json")
    fi

    # Model override (shared knob; OpenCode expects provider/model form).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("-m" "$CLAUDE_MODEL")
    fi

    # Resume a specific session by id when continuity is on.
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("-s" "$session_id")
    fi

    # OpenCode has no system-prompt flag; prepend loop context to the prompt.
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    if [[ -n "$loop_context" ]]; then
        prompt_content="${loop_context}"$'\n\n'"${prompt_content}"
    fi
    CLAUDE_CMD_ARGS+=("$prompt_content")
}

# =============================================================================
# OUTPUT NORMALIZATION
# =============================================================================

# agent_opencode_detect_format - "json" if the output is a JSONL event stream
# (first non-empty line is a JSON object), else "text".
agent_opencode_detect_format() {
    local output_file=$1
    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        echo "text"
        return
    fi
    local first_char
    first_char=$(grep -m1 '[^[:space:]]' "$output_file" 2>/dev/null | head -c 1)
    if [[ "$first_char" != "{" ]]; then
        echo "text"
        return
    fi
    if jq -e -s '. as $a | ($a | length) > 0' "$output_file" >/dev/null 2>&1; then
        echo "json"
    else
        echo "text"
    fi
}

# agent_opencode_normalize_response - map an OpenCode JSONL event stream to
# Ralph's normalized analysis struct (same shape the other adapters produce).
# Args: output_file [result_file]
#
# Expected OpenCode JSONL events (verify against your installed opencode):
#   {"type":"session.updated","sessionID":"..."}
#   {"type":"message","role":"assistant","text":"<incl RALPH_STATUS>"}
#   {"type":"error","message":"..."}
#   {"type":"session.idle","tokens":{...}}
agent_opencode_normalize_response() {
    local output_file=$1
    local result_file="${2:-$RALPH_DIR/.json_parse_result}"

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Output file not found: $output_file" >&2
        return 1
    fi
    if ! jq -e -s 'length >= 0' "$output_file" >/dev/null 2>&1; then
        echo "ERROR: Invalid JSONL in output file" >&2
        return 1
    fi

    local session_id summary error_count
    session_id=$(jq -rs '[.[] | .sessionID // .session_id // empty] | .[0] // ""' "$output_file" 2>/dev/null)
    summary=$(jq -rs '[.[] | select(.type == "message" and .role == "assistant") | .text // empty] | join("\n")' "$output_file" 2>/dev/null)
    error_count=$(jq -rs '[.[] | select(.type == "error")] | length' "$output_file" 2>/dev/null)
    error_count=$((error_count + 0))

    # Exit signal / status from the RALPH_STATUS block in assistant text.
    local exit_signal="false" status="UNKNOWN"
    if printf '%s' "$summary" | grep -q -- "---RALPH_STATUS---"; then
        local es st
        es=$(printf '%s' "$summary" | grep "EXIT_SIGNAL:" | head -1 | cut -d: -f2 | xargs)
        [[ "$es" == "true" ]] && exit_signal="true"
        st=$(printf '%s' "$summary" | grep "STATUS:" | head -1 | cut -d: -f2 | xargs)
        [[ "$st" == "COMPLETE" ]] && status="COMPLETE"
    fi

    local has_completion_signal="false"
    [[ "$status" == "COMPLETE" || "$exit_signal" == "true" ]] && has_completion_signal="true"

    local is_stuck="false"
    [[ $error_count -gt 5 ]] && is_stuck="true"

    # OpenCode uses an auto-approve model (no denials array); files_modified left
    # to the ralph_loop git fallback.
    jq -n \
        --arg status "$status" \
        --argjson exit_signal "$exit_signal" \
        --argjson is_test_only false \
        --argjson is_stuck "$is_stuck" \
        --argjson has_completion_signal "$has_completion_signal" \
        --argjson files_modified 0 \
        --argjson error_count "$error_count" \
        --arg summary "$summary" \
        --argjson loop_number 0 \
        --arg session_id "$session_id" \
        --argjson confidence 0 \
        --argjson has_permission_denials false \
        --argjson permission_denial_count 0 \
        --argjson denied_commands '[]' \
        '{
            status: $status,
            exit_signal: $exit_signal,
            is_test_only: $is_test_only,
            is_stuck: $is_stuck,
            has_completion_signal: $has_completion_signal,
            files_modified: $files_modified,
            error_count: $error_count,
            summary: $summary,
            loop_number: $loop_number,
            session_id: $session_id,
            confidence: $confidence,
            has_permission_denials: $has_permission_denials,
            permission_denial_count: $permission_denial_count,
            denied_commands: $denied_commands,
            metadata: {
                loop_number: $loop_number,
                session_id: $session_id
            }
        }' > "$result_file"
    return 0
}

# =============================================================================
# CAPABILITIES
# =============================================================================
# OpenCode provides structured output and resume-by-id sessions, and reports
# token usage. It uses an auto-approve model (no denials array) and has no
# Claude-style 5-hour API-limit signal, so those two capabilities are absent —
# Ralph degrades them gracefully (#315).
AGENT_OPENCODE_CAPABILITIES="supports_token_usage supports_session_resume"

# agent_opencode_has_capability <capability> -> 0 if OpenCode supports it, else 1.
agent_opencode_has_capability() {
    local cap="$1" c
    for c in $AGENT_OPENCODE_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
