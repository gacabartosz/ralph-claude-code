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
