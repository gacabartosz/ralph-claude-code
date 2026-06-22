#!/usr/bin/env bash
# lib/agents/gemini.sh - Gemini CLI adapter (multi-provider epic, #318 / MP.7).
#
# Second non-Claude adapter; Gemini is closest to Claude's shape (structured
# output + race-free pre-assigned sessions). Implements the same contract as the
# Claude/Codex adapters:
#   agent_gemini_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_gemini_detect_format      output_file -> "json"|"text"
#   agent_gemini_normalize_response output_file [result_file] -> normalized struct
#   AGENT_GEMINI_CAPABILITIES / agent_gemini_has_capability
#
# Gemini CLI shape:
#   gemini -o json [-m <model>] [--approval-mode <mode>] [--session-id <id> -r] -p <prompt>
# `-o json` emits a single JSON object. Sessions are race-free: Ralph supplies the
# id via --session-id (pre-assign), and -r resumes it. The assistant text carries
# Ralph's RALPH_STATUS block, which drives exit detection (provider-independent).

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_gemini_build_command - populate CLAUDE_CMD_ARGS for the Gemini CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses CLAUDE_MODEL (-> -m), CLAUDE_USE_CONTINUE (-> --session-id <id> -r),
# CLAUDE_OUTPUT_FORMAT (json -> -o json), plus GEMINI_CMD (binary) and
# GEMINI_APPROVAL_MODE (default|auto_edit|plan). Gemini exec has no system-prompt
# flag, so loop_context is prepended to the prompt.
# Security: never emits --approval-mode yolo (auto-approves everything), even if
# GEMINI_APPROVAL_MODE=yolo is set — mirrors the Claude/Codex dangerous-flag rule.
agent_gemini_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local gemini_cmd="${GEMINI_CMD:-gemini}"

    CLAUDE_CMD_ARGS=("$gemini_cmd")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Structured output (mirror the Claude json/text switch).
    if [[ "${CLAUDE_OUTPUT_FORMAT:-json}" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("-o" "json")
    fi

    # Model override (shared knob).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("-m" "$CLAUDE_MODEL")
    fi

    # Approval mode (optional). Never forward the dangerous "yolo" mode.
    if [[ -n "${GEMINI_APPROVAL_MODE:-}" && "${GEMINI_APPROVAL_MODE}" != "yolo" ]]; then
        CLAUDE_CMD_ARGS+=("--approval-mode" "$GEMINI_APPROVAL_MODE")
    fi

    # Session: pre-assign Ralph's id (race-free) and resume it when continuity is on.
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--session-id" "$session_id" "-r")
    fi

    # Gemini has no system-prompt flag; prepend loop context to the prompt.
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    if [[ -n "$loop_context" ]]; then
        prompt_content="${loop_context}"$'\n\n'"${prompt_content}"
    fi
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# =============================================================================
# OUTPUT NORMALIZATION
# =============================================================================

# agent_gemini_detect_format - "json" if the output is a JSON object, else "text".
agent_gemini_detect_format() {
    local output_file=$1
    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        echo "text"
        return
    fi
    local first_char
    first_char=$(head -c 1 "$output_file" 2>/dev/null | tr -d '[:space:]')
    if [[ "$first_char" != "{" ]]; then
        echo "text"
        return
    fi
    if jq empty "$output_file" 2>/dev/null; then
        echo "json"
    else
        echo "text"
    fi
}

# agent_gemini_normalize_response - map Gemini `-o json` output to Ralph's
# normalized analysis struct (same shape the Claude/Codex adapters produce).
# Args: output_file [result_file]
#
# Expected Gemini JSON object (verify against your installed gemini):
#   {"response":"<assistant text incl RALPH_STATUS>",
#    "session_id":"...", "stats":{"tokens":{...}}, "error":null}
agent_gemini_normalize_response() {
    local output_file=$1
    local result_file="${2:-$RALPH_DIR/.json_parse_result}"

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Output file not found: $output_file" >&2
        return 1
    fi
    if ! jq empty "$output_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in output file" >&2
        return 1
    fi

    local session_id summary
    session_id=$(jq -r '.session_id // .stats.session_id // ""' "$output_file" 2>/dev/null)
    summary=$(jq -r '.response // ""' "$output_file" 2>/dev/null)

    # Error count: explicit .error (non-null) counts as one; .errors array if present.
    local error_count
    error_count=$(jq -r 'if (.error // null) != null then 1 else (.errors // [] | length) end' "$output_file" 2>/dev/null)
    error_count=$((error_count + 0))

    # Exit signal / status from the RALPH_STATUS block in the response text.
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

    # Gemini uses approval-mode, not a denials array; files_modified left to the
    # ralph_loop git fallback.
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
# Gemini provides structured output and race-free pre-assigned sessions, and
# reports token usage. It uses approval-mode (no denials array) and has no
# Claude-style 5-hour API-limit signal, so those two capabilities are absent —
# Ralph degrades them gracefully (#315).
AGENT_GEMINI_CAPABILITIES="supports_token_usage supports_session_resume"

# agent_gemini_has_capability <capability> -> 0 if Gemini supports it, else 1.
agent_gemini_has_capability() {
    local cap="$1" c
    for c in $AGENT_GEMINI_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
