#!/usr/bin/env bash
# lib/agents/kilocode.sh - Kilocode CLI adapter (multi-provider epic, #321 / MP.10).
#
# Implements the same contract as the Claude/Codex/Gemini/OpenCode/Droid adapters:
#   agent_kilocode_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_kilocode_detect_format      output_file -> "json"|"text"
#   agent_kilocode_normalize_response output_file [result_file] -> normalized struct
#   AGENT_KILOCODE_CAPABILITIES / agent_kilocode_has_capability
#
# Kilocode CLI shape:
#   kilocode --auto [-j] [-mo <model>] [-c] <prompt>
# Headless operation requires --auto; structured JSON output is enabled with
# -j/--json (which itself requires --auto). Sessions only "continue last" via
# -c/--continue (no session-id targeting — the weakest resume form; see the
# capability note). --yolo bypasses approvals and is NEVER emitted (cross-adapter
# security invariant; --auto already provides headless autonomy). The assistant
# text carries Ralph's RALPH_STATUS block, which drives exit detection
# (provider-independent).

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_kilocode_build_command - populate CLAUDE_CMD_ARGS for the Kilocode CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses CLAUDE_MODEL (-> -mo), CLAUDE_USE_CONTINUE (-> -c continue-last when a
# prior session id exists), CLAUDE_OUTPUT_FORMAT (json -> -j), plus KILOCODE_CMD
# (binary). --auto is always present (headless requirement). Kilocode takes the
# prompt positionally and has no system-prompt flag, so loop_context is prepended.
# --yolo is intentionally never emitted (security invariant).
agent_kilocode_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local kilocode_cmd="${KILOCODE_CMD:-kilocode}"

    # --auto is required for any headless (non-TUI) run.
    CLAUDE_CMD_ARGS=("$kilocode_cmd" "--auto")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Structured output (mirror the json/text switch). -j requires --auto, which
    # is always present above.
    if [[ "${CLAUDE_OUTPUT_FORMAT:-json}" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("-j")
    fi

    # Model override (shared knob; Kilocode uses -mo, not -m).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("-mo" "$CLAUDE_MODEL")
    fi

    # Continue the LAST session only when continuity is on and a prior session
    # existed. Kilocode's -c has no session-id argument (continue-last caveat).
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("-c")
    fi

    # Kilocode has no system-prompt flag; prepend loop context to the prompt.
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

# agent_kilocode_detect_format - "json" if the output is a JSON object, else "text".
agent_kilocode_detect_format() {
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

# agent_kilocode_normalize_response - map Kilocode -j (JSON) output to Ralph's
# normalized analysis struct (same shape the other adapters produce).
# Args: output_file [result_file]
#
# Expected Kilocode JSON object (verify against your installed kilocode):
#   {"result":"<assistant text incl RALPH_STATUS>",
#    "session_id":"...", "usage":{...}, "error":null}
agent_kilocode_normalize_response() {
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
    summary=$(jq -r '.result // .output // .text // .response // ""' "$output_file" 2>/dev/null)

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

    # Kilocode uses --auto approval (no denials array); files_modified left to the
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
# Kilocode provides structured output (-j) and reports token usage. Its session
# support is continue-LAST-only (-c, no session-id targeting) — the weakest resume
# form among the providers, but it still qualifies as supports_session_resume; the
# caveat is documented in docs/providers/KILOCODE.md. It uses --auto approval (no
# denials array) and has no Claude-style 5-hour API-limit signal, so those two
# capabilities are absent — Ralph degrades them gracefully (#315).
AGENT_KILOCODE_CAPABILITIES="supports_token_usage supports_session_resume"

# agent_kilocode_has_capability <capability> -> 0 if Kilocode supports it, else 1.
agent_kilocode_has_capability() {
    local cap="$1" c
    for c in $AGENT_KILOCODE_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
