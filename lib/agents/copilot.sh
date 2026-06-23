#!/usr/bin/env bash
# lib/agents/copilot.sh - GitHub Copilot CLI adapter (multi-provider epic, #322 / MP.11).
#
# The DEGRADED, TEXT-ONLY provider — Copilot has no structured (JSON) output, so
# this adapter validates the graceful-degradation design (#315) under the hardest
# case. Implements the same contract as the other adapters:
#   agent_copilot_build_command      prompt_file loop_context session_id -> CLAUDE_CMD_ARGS
#   agent_copilot_detect_format      output_file -> always "text"
#   agent_copilot_normalize_response output_file [result_file] -> normalized struct
#   AGENT_COPILOT_CAPABILITIES / agent_copilot_has_capability
#
# Copilot CLI shape:
#   copilot -s [--model <m>] [--resume <id>] [--allow-tool <t>]... [--deny-tool <t>]... -p <prompt>
# `-s/--silent` emits the agent response only (clean output). There is NO JSON
# mode, so exit detection relies ENTIRELY on the RALPH_STATUS text block via the
# analyzer's text-mode path (#224) — agent_copilot_detect_format always returns
# "text", which routes analyze_response down that portable path. The full-bypass
# `--allow-all` is NEVER emitted (cross-adapter security invariant); grant specific
# tools with COPILOT_ALLOWED_TOOLS instead.

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# COMMAND CONSTRUCTION
# =============================================================================

# agent_copilot_build_command - populate CLAUDE_CMD_ARGS for the Copilot CLI.
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Reuses CLAUDE_MODEL (-> --model) and CLAUDE_USE_CONTINUE (-> --resume <id>),
# plus COPILOT_CMD (binary), COPILOT_ALLOWED_TOOLS (-> --allow-tool per tool),
# COPILOT_DENIED_TOOLS (-> --deny-tool per tool). Copilot is text-only, so
# CLAUDE_OUTPUT_FORMAT is intentionally ignored. The prompt is passed via -p (no
# system-prompt flag exists), so loop_context is prepended to it. --allow-all is
# never emitted (security invariant).
agent_copilot_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3
    local copilot_cmd="${COPILOT_CMD:-copilot}"

    # -s/--silent: agent response only (the closest Copilot has to clean output).
    CLAUDE_CMD_ARGS=("$copilot_cmd" "-s")

    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Model override (shared knob).
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--model" "$CLAUDE_MODEL")
    fi

    # Resume a specific session by id when continuity is on.
    if [[ "${CLAUDE_USE_CONTINUE:-true}" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    fi

    # Granular tool permissions (comma/space separated -> one flag per tool).
    # --allow-all (full bypass) is intentionally never emitted.
    local tool
    if [[ -n "${COPILOT_ALLOWED_TOOLS:-}" ]]; then
        for tool in ${COPILOT_ALLOWED_TOOLS//,/ }; do
            [[ -n "$tool" ]] && CLAUDE_CMD_ARGS+=("--allow-tool" "$tool")
        done
    fi
    if [[ -n "${COPILOT_DENIED_TOOLS:-}" ]]; then
        for tool in ${COPILOT_DENIED_TOOLS//,/ }; do
            [[ -n "$tool" ]] && CLAUDE_CMD_ARGS+=("--deny-tool" "$tool")
        done
    fi

    # Copilot has no system-prompt flag; prepend loop context to the prompt and
    # pass it via -p.
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    if [[ -n "$loop_context" ]]; then
        prompt_content="${loop_context}"$'\n\n'"${prompt_content}"
    fi
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# =============================================================================
# OUTPUT NORMALIZATION (text-only)
# =============================================================================

# agent_copilot_detect_format - Copilot has no structured output, so this always
# reports "text". That routes analyze_response down its RALPH_STATUS text path.
agent_copilot_detect_format() {
    echo "text"
}

# agent_copilot_normalize_response - parse Copilot's TEXT output into Ralph's
# normalized analysis struct. Exit detection comes from the RALPH_STATUS block in
# the text (the same struct shape the JSON adapters emit). In normal loop runs
# analyze_response handles text directly; this keeps the adapter contract complete
# and lets the harness validate the text path.
# Args: output_file [result_file]
agent_copilot_normalize_response() {
    local output_file=$1
    local result_file="${2:-$RALPH_DIR/.json_parse_result}"

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Output file not found: $output_file" >&2
        return 1
    fi

    local summary
    summary=$(cat "$output_file")

    # Exit signal / status from the RALPH_STATUS block in the text.
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

    # Text mode has no structured error/usage/session fields; counts left to the
    # analyzer text path and the ralph_loop git fallback.
    jq -n \
        --arg status "$status" \
        --argjson exit_signal "$exit_signal" \
        --argjson is_test_only false \
        --argjson is_stuck false \
        --argjson has_completion_signal "$has_completion_signal" \
        --argjson files_modified 0 \
        --argjson error_count 0 \
        --arg summary "$summary" \
        --argjson loop_number 0 \
        --arg session_id "" \
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
# CAPABILITIES (the most degraded adapter)
# =============================================================================
# Copilot is text-only: no structured output -> no token usage, and no API-limit
# signal. It has rich per-tool permissions at BUILD time (--allow-tool/--deny-tool)
# but no machine-readable permission-denial signal at parse time, so the
# permission-denial circuit breaker (#101) cannot fire. Only session resume by id
# (--resume) is supported. Everything else degrades gracefully (#315).
AGENT_COPILOT_CAPABILITIES="supports_session_resume"

# agent_copilot_has_capability <capability> -> 0 if Copilot supports it, else 1.
agent_copilot_has_capability() {
    local cap="$1" c
    for c in $AGENT_COPILOT_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
