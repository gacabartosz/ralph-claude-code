#!/usr/bin/env bash
# lib/agents/claude.sh - Claude CLI reference adapter (multi-provider epic, #312)
#
# Implements the command-build half of the agent adapter contract. This is the
# REFERENCE adapter: it reproduces ralph_loop.sh's historical command argv
# byte-for-byte. New providers implement the same agent_<name>_build_command
# contract and populate the shared CLAUDE_CMD_ARGS output array.
#
# Inputs (read from the environment / globals set by ralph_loop.sh):
#   CLAUDE_CODE_CMD, CLAUDE_MODEL, CLAUDE_EFFORT, CLAUDE_OUTPUT_FORMAT,
#   CLAUDE_ALLOWED_TOOLS, CLAUDE_USE_CONTINUE
# Output:
#   CLAUDE_CMD_ARGS array (provider-agnostic output interface)

# agent_claude_build_command - populate CLAUDE_CMD_ARGS for the Claude CLI.
#
# Args: prompt_file loop_context session_id
# Returns: 1 if the prompt file is missing (after logging), 0 otherwise.
#
# Security invariant: never emits --dangerously-skip-permissions. Tool
# permissions are controlled via --allowedTools from CLAUDE_ALLOWED_TOOLS,
# preserving the permission-denial circuit breaker (Issue #101).
agent_claude_build_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        if declare -f log_status >/dev/null 2>&1; then
            log_status "ERROR" "Prompt file not found: $prompt_file"
        else
            echo "ERROR: Prompt file not found: $prompt_file" >&2
        fi
        return 1
    fi

    # Add model override (Issue #228)
    if [[ -n "${CLAUDE_MODEL:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--model" "$CLAUDE_MODEL")
    fi

    # Add effort level override (Issue #228)
    if [[ -n "${CLAUDE_EFFORT:-}" ]]; then
        CLAUDE_CMD_ARGS+=("--effort" "$CLAUDE_EFFORT")
    fi

    # Add output format flag
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Add allowed tools (each tool as separate array element)
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi

    # Add session continuity flag
    # IMPORTANT: Use --resume with explicit session ID instead of --continue
    # --continue resumes the "most recent session in current directory" which
    # can hijack active Claude Code sessions. --resume with a specific session ID
    # ensures we only resume Ralph's own sessions. (Issue #151)
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    fi
    # If no session_id, start fresh - Claude will generate a new session ID
    # which we'll capture via save_claude_session() for future loops

    # Add loop context as system prompt (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi

    # Read prompt file content and use -p flag
    # Note: Claude CLI uses -p for prompts, not --prompt-file (which doesn't exist)
    # Array-based approach maintains shell injection safety
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# =============================================================================
# OUTPUT NORMALIZATION (multi-provider epic, #313 / MP.2)
# =============================================================================
# The normalize half of the adapter contract: turn a raw Claude CLI output file
# into Ralph's internal normalized analysis struct (written to
# .ralph/.json_parse_result). Moved here wholesale from lib/response_analyzer.sh
# with zero behavior change; response_analyzer.sh now sources this adapter and
# delegates to the agent_claude_* contract wrappers at the bottom of this file.

# Use RALPH_DIR if set by the main script, otherwise default to .ralph
RALPH_DIR="${RALPH_DIR:-.ralph}"

# =============================================================================
# JSON OUTPUT FORMAT DETECTION AND PARSING
# =============================================================================

# Max file size for full jq validation (1 MB). Above this threshold the file is
# probably a truncated streaming JSONL dump after a productive timeout (issue #250) —
# `jq empty` would attempt to parse the entire content and hang/crash on malformed input.
# Files above this size fall back to text mode, which the rest of the analyzer already handles.
# Override via env var RALPH_JSONL_SAFE_MAX_BYTES.
RALPH_JSONL_SAFE_MAX_BYTES=${RALPH_JSONL_SAFE_MAX_BYTES:-1048576}

# _file_size_bytes - Cross-platform stat helper (BSD/macOS + GNU/Linux).
# Returns byte size of $1, or 0 if file missing.
_file_size_bytes() {
    local f="$1"
    [[ ! -f "$f" ]] && { printf '0'; return; }
    local size
    size=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f" 2>/dev/null || echo 0)
    printf '%d' "${size:-0}"
}

# Detect output format (json or text)
# Returns: "json" if valid JSON, "text" otherwise
detect_output_format() {
    local output_file=$1

    if [[ ! -f "$output_file" ]] || [[ ! -s "$output_file" ]]; then
        echo "text"
        return
    fi

    # Check if file starts with { or [ (JSON indicators)
    local first_char=$(head -c 1 "$output_file" 2>/dev/null | tr -d '[:space:]')

    if [[ "$first_char" != "{" && "$first_char" != "[" ]]; then
        echo "text"
        return
    fi

    # Fix #250: Guard against productive-timeout JSONL dumps (~4 MB, 12K+ lines).
    # `jq empty` on these hangs because Claude was killed mid-stream and the file is
    # not well-formed JSON. Size cap + check for `"type":"result"` marker (the line
    # Claude writes last on clean completion). If file is large AND lacks the marker,
    # the stream is truncated — fall back to text mode without invoking jq on the
    # full file. Downstream ralph_loop.sh already extracts a result_line from streams
    # when present (see "Extracted and validated session data from stream output"),
    # so this guard only kicks in for the unrecoverable case.
    local size
    size=$(_file_size_bytes "$output_file")
    if [[ "$size" -gt "$RALPH_JSONL_SAFE_MAX_BYTES" ]]; then
        if ! grep -q '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null; then
            echo "text"
            return
        fi
    fi

    # Validate as JSON using jq
    if jq empty "$output_file" 2>/dev/null; then
        echo "json"
    else
        echo "text"
    fi
}

# Parse JSON response and extract structured fields
# Creates .ralph/.json_parse_result with normalized analysis data
# Supports THREE JSON formats:
# 1. Flat format: { status, exit_signal, work_type, files_modified, ... }
# 2. Claude CLI object format: { result, sessionId, metadata: { files_changed, has_errors, completion_status, ... } }
# 3. Claude CLI array format: [ {type: "system", ...}, {type: "assistant", ...}, {type: "result", ...} ]
parse_json_response() {
    local output_file=$1
    local result_file="${2:-$RALPH_DIR/.json_parse_result}"
    local normalized_file=""

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: Output file not found: $output_file" >&2
        return 1
    fi

    # Validate JSON first
    if ! jq empty "$output_file" 2>/dev/null; then
        echo "ERROR: Invalid JSON in output file" >&2
        return 1
    fi

    # Check if JSON is an array (Claude CLI array format)
    # Claude CLI outputs: [{type: "system", ...}, {type: "assistant", ...}, {type: "result", ...}]
    if jq -e 'type == "array"' "$output_file" >/dev/null 2>&1; then
        normalized_file=$(mktemp)

        # Extract the "result" type message from the array (usually the last entry)
        # This contains: result, session_id, is_error, duration_ms, etc.
        local result_obj=$(jq '[.[] | select(.type == "result")] | .[-1] // {}' "$output_file" 2>/dev/null)

        # Guard against empty result_obj if jq fails (review fix: Macroscope)
        [[ -z "$result_obj" ]] && result_obj="{}"

        # Extract session_id from init message as fallback
        local init_session_id=$(jq -r '.[] | select(.type == "system" and .subtype == "init") | .session_id // empty' "$output_file" 2>/dev/null | head -1)

        # Prioritize result object's own session_id, then fall back to init message (review fix: CodeRabbit)
        # This prevents session ID loss when arrays lack an init message with session_id
        local effective_session_id
        effective_session_id=$(echo "$result_obj" | jq -r '.sessionId // .session_id // empty' 2>/dev/null)
        if [[ -z "$effective_session_id" || "$effective_session_id" == "null" ]]; then
            effective_session_id="$init_session_id"
        fi

        # Build normalized object merging result with effective session_id
        if [[ -n "$effective_session_id" && "$effective_session_id" != "null" ]]; then
            echo "$result_obj" | jq --arg sid "$effective_session_id" '. + {sessionId: $sid} | del(.session_id)' > "$normalized_file"
        else
            echo "$result_obj" | jq 'del(.session_id)' > "$normalized_file"
        fi

        # Use normalized file for subsequent parsing
        output_file="$normalized_file"
    fi

    # Detect JSON format by checking for Claude CLI fields
    local has_result_field=$(jq -r 'has("result")' "$output_file" 2>/dev/null)

    # Extract fields - support both flat format and Claude CLI format
    # Priority: Claude CLI fields first, then flat format fields

    # Status: from flat format OR derived from metadata.completion_status
    local status=$(jq -r '.status // "UNKNOWN"' "$output_file" 2>/dev/null)
    local completion_status=$(jq -r '.metadata.completion_status // ""' "$output_file" 2>/dev/null)
    if [[ "$completion_status" == "complete" || "$completion_status" == "COMPLETE" ]]; then
        status="COMPLETE"
    fi

    # Exit signal: from flat format OR derived from completion_status
    # Track whether EXIT_SIGNAL was explicitly provided (vs inferred from STATUS)
    local exit_signal=$(jq -r '.exit_signal // false' "$output_file" 2>/dev/null)
    local explicit_exit_signal_found=$(jq -r 'has("exit_signal")' "$output_file" 2>/dev/null)

    # Bug #1 Fix: If exit_signal is still false, check for RALPH_STATUS block in .result field
    # Claude CLI JSON format embeds the RALPH_STATUS block within the .result text field
    if [[ "$exit_signal" == "false" && "$has_result_field" == "true" ]]; then
        local result_text=$(jq -r '.result // ""' "$output_file" 2>/dev/null)
        if [[ -n "$result_text" ]] && echo "$result_text" | grep -q -- "---RALPH_STATUS---"; then
            # Extract EXIT_SIGNAL value from RALPH_STATUS block within result text
            local embedded_exit_sig
            embedded_exit_sig=$(echo "$result_text" | grep "EXIT_SIGNAL:" | cut -d: -f2 | xargs)
            if [[ -n "$embedded_exit_sig" ]]; then
                # Explicit EXIT_SIGNAL found in RALPH_STATUS block
                explicit_exit_signal_found="true"
                if [[ "$embedded_exit_sig" == "true" ]]; then
                    exit_signal="true"
                    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && echo "DEBUG: Extracted EXIT_SIGNAL=true from .result RALPH_STATUS block" >&2
                else
                    exit_signal="false"
                    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && echo "DEBUG: Extracted EXIT_SIGNAL=false from .result RALPH_STATUS block (respecting explicit intent)" >&2
                fi
            fi
            # Also check STATUS field as fallback ONLY when EXIT_SIGNAL was not specified
            # This respects explicit EXIT_SIGNAL: false which means "task complete, continue working"
            local embedded_status
            embedded_status=$(echo "$result_text" | grep "STATUS:" | cut -d: -f2 | xargs)
            if [[ "$embedded_status" == "COMPLETE" && "$explicit_exit_signal_found" != "true" ]]; then
                # STATUS: COMPLETE without any EXIT_SIGNAL field implies completion
                exit_signal="true"
                [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && echo "DEBUG: Inferred EXIT_SIGNAL=true from .result STATUS=COMPLETE (no explicit EXIT_SIGNAL found)" >&2
            fi
        fi
    fi

    # Work type: from flat format
    local work_type=$(jq -r '.work_type // "UNKNOWN"' "$output_file" 2>/dev/null)

    # Files modified: from flat format OR from metadata.files_changed
    local files_modified=$(jq -r '.metadata.files_changed // .files_modified // 0' "$output_file" 2>/dev/null)

    # Error count: from flat format OR derived from metadata.has_errors
    # Note: When only has_errors=true is present (without explicit error_count),
    # we set error_count=1 as a minimum. This is defensive programming since
    # the stuck detection threshold is >5 errors, so 1 error won't trigger it.
    # Actual error count may be higher, but precise count isn't critical for our logic.
    local error_count=$(jq -r '.error_count // 0' "$output_file" 2>/dev/null)
    local has_errors=$(jq -r '.metadata.has_errors // false' "$output_file" 2>/dev/null)
    if [[ "$has_errors" == "true" && "$error_count" == "0" ]]; then
        error_count=1  # At least one error if has_errors is true
    fi

    # Summary: from flat format OR from result field (Claude CLI format)
    local summary=$(jq -r '.result // .summary // ""' "$output_file" 2>/dev/null)

    # Session ID: from Claude CLI format (sessionId) OR from metadata.session_id
    local session_id=$(jq -r '.sessionId // .metadata.session_id // ""' "$output_file" 2>/dev/null)

    # Loop number: from metadata
    local loop_number=$(jq -r '.metadata.loop_number // .loop_number // 0' "$output_file" 2>/dev/null)

    # Confidence: from flat format
    local confidence=$(jq -r '.confidence // 0' "$output_file" 2>/dev/null)

    # Progress indicators: from Claude CLI metadata (optional)
    local progress_count=$(jq -r '.metadata.progress_indicators | if . then length else 0 end' "$output_file" 2>/dev/null)

    # Permission denials: from Claude Code output (Issue #101)
    # When Claude Code is denied permission to run commands, it outputs a permission_denials array
    local permission_denial_count=$(jq -r '.permission_denials | if . then length else 0 end' "$output_file" 2>/dev/null)
    permission_denial_count=$((permission_denial_count + 0))  # Ensure integer

    local has_permission_denials="false"
    if [[ $permission_denial_count -gt 0 ]]; then
        has_permission_denials="true"
    fi

    # Extract denied tool names and commands for logging/display
    # Shows tool_name for non-Bash tools, and for Bash tools shows the command that was denied
    # This handles both cases: AskUserQuestion denial shows "AskUserQuestion",
    # while Bash denial shows "Bash(git commit -m ...)" with truncated command
    local denied_commands_json="[]"
    if [[ $permission_denial_count -gt 0 ]]; then
        denied_commands_json=$(jq -r '[.permission_denials[] | if .tool_name == "Bash" then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))" else .tool_name // "unknown" end]' "$output_file" 2>/dev/null || echo "[]")
    fi

    # Normalize values
    # Convert exit_signal to boolean string
    # Only infer from status/completion_status if no explicit EXIT_SIGNAL was provided
    if [[ "$explicit_exit_signal_found" == "true" ]]; then
        # Respect explicit EXIT_SIGNAL value (already set above)
        [[ "$exit_signal" == "true" ]] && exit_signal="true" || exit_signal="false"
    elif [[ "$exit_signal" == "true" || "$status" == "COMPLETE" || "$completion_status" == "complete" || "$completion_status" == "COMPLETE" ]]; then
        exit_signal="true"
    else
        exit_signal="false"
    fi

    # Determine is_test_only from work_type
    local is_test_only="false"
    if [[ "$work_type" == "TEST_ONLY" ]]; then
        is_test_only="true"
    fi

    # Determine is_stuck from error_count (threshold >5)
    local is_stuck="false"
    error_count=$((error_count + 0))  # Ensure integer
    if [[ $error_count -gt 5 ]]; then
        is_stuck="true"
    fi

    # Ensure files_modified is integer
    files_modified=$((files_modified + 0))

    # Ensure progress_count is integer
    progress_count=$((progress_count + 0))

    # Calculate has_completion_signal
    local has_completion_signal="false"
    if [[ "$status" == "COMPLETE" || "$exit_signal" == "true" ]]; then
        has_completion_signal="true"
    fi

    # Boost confidence based on structured data availability
    if [[ "$has_result_field" == "true" ]]; then
        confidence=$((confidence + 20))  # Structured response boost
    fi
    if [[ $progress_count -gt 0 ]]; then
        confidence=$((confidence + progress_count * 5))  # Progress indicators boost
    fi

    # Write normalized result using jq for safe JSON construction
    # String fields use --arg (auto-escapes), numeric/boolean use --argjson
    jq -n \
        --arg status "$status" \
        --argjson exit_signal "$exit_signal" \
        --argjson is_test_only "$is_test_only" \
        --argjson is_stuck "$is_stuck" \
        --argjson has_completion_signal "$has_completion_signal" \
        --argjson files_modified "$files_modified" \
        --argjson error_count "$error_count" \
        --arg summary "$summary" \
        --argjson loop_number "$loop_number" \
        --arg session_id "$session_id" \
        --argjson confidence "$confidence" \
        --argjson has_permission_denials "$has_permission_denials" \
        --argjson permission_denial_count "$permission_denial_count" \
        --argjson denied_commands "$denied_commands_json" \
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

    # Cleanup temporary normalized file if created (for array format handling)
    if [[ -n "$normalized_file" && -f "$normalized_file" ]]; then
        rm -f "$normalized_file"
    fi

    return 0
}

# agent_claude_detect_format - adapter contract: detect output format (json/text).
# Thin wrapper over detect_output_format so callers depend on the provider
# contract name, not the Claude-internal implementation.
agent_claude_detect_format() {
    detect_output_format "$@"
}

# agent_claude_normalize_response - adapter contract: parse a raw Claude output
# file into the normalized analysis struct at result_file (default
# .ralph/.json_parse_result). Thin wrapper over parse_json_response.
# Args: output_file [result_file]
agent_claude_normalize_response() {
    parse_json_response "$@"
}

# =============================================================================
# CAPABILITIES (multi-provider epic, #315 / MP.4)
# =============================================================================
# Capability record for the Claude adapter. Claude supports Ralph's full feature
# set; future adapters declare a subset and Ralph degrades gracefully (gated via
# agent_capability_enabled in the registry). Space-separated for bash 3.2
# compatibility (no associative arrays).
AGENT_CLAUDE_CAPABILITIES="supports_token_usage supports_permission_denials supports_api_limit_detection supports_session_resume"

# agent_claude_has_capability <capability> -> 0 if Claude supports it, else 1.
agent_claude_has_capability() {
    local cap="$1" c
    for c in $AGENT_CLAUDE_CAPABILITIES; do
        [[ "$c" == "$cap" ]] && return 0
    done
    return 1
}
