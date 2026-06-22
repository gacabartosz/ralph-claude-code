#!/usr/bin/env bash
# lib/agents/codex.sh - Codex CLI adapter, pilot non-Claude provider
# (multi-provider epic, #317 / MP.6).
#
# First real adapter built on the abstraction seam; the template for #318-#322.
# Implements the same contract as the Claude reference adapter:
#   agent_codex_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_codex_detect_format      output_file -> "json"|"text"
#   agent_codex_normalize_response output_file [result_file] -> normalized struct
#   AGENT_CODEX_CAPABILITIES / agent_codex_has_capability
#
# Codex CLI shape (OpenAI `codex exec`):
#   codex exec [resume <id>] --json [-m <model>] <prompt>
# `--json` streams JSONL events (one JSON object per line). The pilot consumes a
# documented event subset (verify exact names against your installed codex):
#   {"type":"session","session_id":"..."}        -> session id
#   {"type":"assistant","text":"..."}            -> assistant message text
#   {"type":"tool","name":"...","status":"..."}  -> tool/command activity
#   {"type":"error","message":"..."}             -> error
#   {"type":"result","usage":{"input_tokens":N,"output_tokens":M}} -> end-of-turn + usage
# The assistant text carries Ralph's RALPH_STATUS block, which drives exit
# detection (portable, provider-independent).

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_codex_build_command - populate CLAUDE_CMD_ARGS for the Codex CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses the shared model knob CLAUDE_MODEL (-> -m) and the session-continuity
# knob CLAUDE_USE_CONTINUE (-> `codex exec resume <id>`). Codex `exec` has no
# system-prompt flag, so loop_context is prepended to the prompt text.
# Security: never emits --dangerously-bypass-approvals-and-sandbox; approvals
# stay at Codex defaults (mirrors the Claude adapter's no-skip-permissions rule).
agent_codex_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local codex_cmd="${CODEX_CMD:-codex}"

    CLAUDE_CMD_ARGS=("$codex_cmd" "exec")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Resume a prior session when continuity is enabled and we have an id.
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("resume" "$session_id")
    fi

    # JSONL event stream (structured output).
    CLAUDE_CMD_ARGS+=("--json")

    # Model override (shared knob).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("-m" "$CLAUDE_MODEL")
    fi

    # Codex exec has no --append-system-prompt; prepend loop context to the prompt.
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

# agent_codex_detect_format - "json" if the output looks like a Codex JSONL event
# stream (first non-empty line is a JSON object), else "text".
agent_codex_detect_format() {
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
    # Each line must be valid JSON (JSONL). jq -e over the slurped stream.
    if jq -e -s '. as $a | ($a | length) > 0' "$output_file" >/dev/null 2>&1; then
        echo "json"
    else
        echo "text"
    fi
}

# agent_codex_normalize_response - map a Codex JSONL event stream to Ralph's
# normalized analysis struct (same shape the Claude adapter produces).
# Args: output_file [result_file]
agent_codex_normalize_response() {
    local output_file=$1
    local result_file="${2:-$RALPH_DIR/.json_parse_result}"

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Output file not found: $output_file" >&2
        return 1
    fi
    # Validate JSONL (slurped) before parsing.
    if ! jq -e -s 'length >= 0' "$output_file" >/dev/null 2>&1; then
        echo "ERROR: Invalid JSONL in output file" >&2
        return 1
    fi

    # Session id: first event carrying a session_id.
    local session_id
    session_id=$(jq -rs '[.[].session_id // empty] | .[0] // ""' "$output_file" 2>/dev/null)

    # Assistant text: concatenate all assistant message events (carries RALPH_STATUS).
    local summary
    summary=$(jq -rs '[.[] | select(.type == "assistant") | .text // empty] | join("\n")' "$output_file" 2>/dev/null)

    # Error count: number of error events.
    local error_count
    error_count=$(jq -rs '[.[] | select(.type == "error")] | length' "$output_file" 2>/dev/null)
    error_count=$((error_count + 0))

    # Exit signal / status from the RALPH_STATUS block embedded in assistant text.
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

    # Codex maps permission handling to sandbox/approval, not a denials array.
    # files_modified is left to ralph_loop's git fallback (Codex doesn't report it).
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
# Codex provides structured output and resume-by-id sessions, and reports token
# usage on turn completion. It maps permission handling to sandbox/approval (no
# denials array) and has no Claude-style 5-hour API-limit signal, so those two
# capabilities are intentionally absent — Ralph degrades them gracefully (#315).
AGENT_CODEX_CAPABILITIES="supports_token_usage supports_session_resume"

# agent_codex_has_capability <capability> -> 0 if Codex supports it, else 1.
agent_codex_has_capability() {
    local cap="$1" c
    for c in $AGENT_CODEX_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
