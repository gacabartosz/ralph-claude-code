#!/usr/bin/env bash
# lib/agents/droid.sh - Factory Droid CLI adapter (multi-provider epic, #320 / MP.9).
#
# Implements the same contract as the Claude/Codex/Gemini/OpenCode adapters:
#   agent_droid_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_droid_detect_format      output_file -> "json"|"text"
#   agent_droid_normalize_response output_file [result_file] -> normalized struct
#   AGENT_DROID_CAPABILITIES / agent_droid_has_capability
#
# Droid CLI shape:
#   droid exec [-o json] [-m <model>] [--session-id <id>] [--auto <level>] <prompt>
# `-o json` emits a single JSON object. Sessions resume by id via --session-id.
# Droid's default model is claude-opus-4-8 (used when CLAUDE_MODEL is empty). The
# assistant text carries Ralph's RALPH_STATUS block, which drives exit detection
# (provider-independent).

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_droid_build_command - populate CLAUDE_CMD_ARGS for the Droid CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses CLAUDE_MODEL (-> -m), CLAUDE_USE_CONTINUE (-> --session-id <id>),
# CLAUDE_OUTPUT_FORMAT (json -> -o json), plus DROID_CMD (binary) and DROID_AUTO
# (--auto <level> approval autonomy). Droid exec takes the prompt positionally
# and has no system-prompt flag, so loop_context is prepended.
agent_droid_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local droid_cmd="${DROID_CMD:-droid}"

    CLAUDE_CMD_ARGS=("$droid_cmd" "exec")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Structured output (mirror the json/text switch).
    if [[ "${CLAUDE_OUTPUT_FORMAT:-json}" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("-o" "json")
    fi

    # Model override (shared knob; empty -> Droid default claude-opus-4-8).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("-m" "$CLAUDE_MODEL")
    fi

    # Resume a specific session by id when continuity is on.
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--session-id" "$session_id")
    fi

    # Approval autonomy level (optional).
    if [[ -n "${DROID_AUTO:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--auto" "$DROID_AUTO")
    fi

    # Droid exec has no system-prompt flag; prepend loop context to the prompt.
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

# agent_droid_detect_format - "json" if the output is a JSON object, else "text".
agent_droid_detect_format() {
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

# agent_droid_normalize_response - map Droid `-o json` output to Ralph's
# normalized analysis struct (same shape the other adapters produce).
# Args: output_file [result_file]
#
# Expected Droid JSON object (verify against your installed droid):
#   {"result":"<assistant text incl RALPH_STATUS>",
#    "session_id":"...", "usage":{...}, "error":null}
agent_droid_normalize_response() {
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
    session_id=$(jq -r '.session_id // .sessionId // ""' "$output_file" 2>/dev/null)
    summary=$(jq -r '.result // .output // .response // ""' "$output_file" 2>/dev/null)

    # Error count: explicit .error (non-null) counts as one; .errors array if present.
    local error_count
    error_count=$(jq -r 'if (.error // null) != null then 1 else (.errors // [] | length) end' "$output_file" 2>/dev/null)
    error_count=$((error_count + 0))

    # Exit signal / status from the RALPH_STATUS block in the assistant text.
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

    # Droid uses --auto approval (no denials array); files_modified left to the
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
# Droid provides structured output and resume-by-id sessions, and reports token
# usage. It uses --auto approval levels (no denials array) and has no Claude-style
# 5-hour API-limit signal, so those two capabilities are absent — Ralph degrades
# them gracefully (#315).
AGENT_DROID_CAPABILITIES="supports_token_usage supports_session_resume"

# agent_droid_has_capability <capability> -> 0 if Droid supports it, else 1.
agent_droid_has_capability() {
    local cap="$1" c
    for c in $AGENT_DROID_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
