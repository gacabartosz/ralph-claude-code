#!/usr/bin/env bash
# lib/agents/registry.sh - Agent provider registry (multi-provider epic, #312)
#
# Resolves the active agent provider and dispatches command construction to its
# adapter. This is the abstraction seam for the multi-provider epic.
#
# Phase 1 (#312): Claude is the only registered provider and the default. The
# selection plumbing (AGENT_PROVIDER config + CLI flag) is wired in #314 — for
# now selection resolves to claude with zero behavior change.
#
# Adapter contract: each provider lib defines agent_<name>_build_command, which
# populates the shared CLAUDE_CMD_ARGS array from the prompt file, loop context
# and session id. The registry routes agent_build_command to the active one.

# Directory this lib lives in (used to source sibling adapters relative to it).
AGENTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Active provider default, set at source time (capture-before-source
# convention: ralph_loop.sh records _env_AGENT_PROVIDER BEFORE sourcing this
# lib so an explicit environment value is not masked by this default).
AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"

# Space-separated list of registered providers (adapters available in this lib).
# Provider selection (#314) validates AGENT_PROVIDER against this list.
AGENT_REGISTERED_PROVIDERS="claude"

# agent_provider_is_registered - return 0 if $1 is a registered provider.
agent_provider_is_registered() {
    local name="$1" p
    for p in $AGENT_REGISTERED_PROVIDERS; do
        [[ "$p" == "$name" ]] && return 0
    done
    return 1
}

# Source the reference adapter.
# shellcheck source=lib/agents/claude.sh
source "$AGENTS_LIB_DIR/claude.sh"

# agent_build_command - dispatch command construction to the active adapter.
#
# Args: prompt_file loop_context session_id
# Output: global CLAUDE_CMD_ARGS array (provider-agnostic output interface)
# Returns: the adapter's return code; 1 for an unknown provider.
agent_build_command() {
    case "$AGENT_PROVIDER" in
        claude)
            agent_claude_build_command "$@"
            ;;
        *)
            if declare -f log_status >/dev/null 2>&1; then
                log_status "ERROR" "Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'"
            else
                echo "ERROR: Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'" >&2
            fi
            return 1
            ;;
    esac
}

# agent_detect_format - dispatch output-format detection to the active adapter.
#
# Args: output_file
# Output: "json" or "text" on stdout
# Returns: the adapter's return code; 1 for an unknown provider.
agent_detect_format() {
    case "$AGENT_PROVIDER" in
        claude)
            agent_claude_detect_format "$@"
            ;;
        *)
            if declare -f log_status >/dev/null 2>&1; then
                log_status "ERROR" "Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'"
            else
                echo "ERROR: Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'" >&2
            fi
            return 1
            ;;
    esac
}

# agent_normalize_response - dispatch response normalization to the active
# adapter. The adapter parses a raw output file into Ralph's normalized analysis
# struct (written to result_file, default .ralph/.json_parse_result).
#
# Args: output_file [result_file]
# Returns: the adapter's return code; 1 for an unknown provider.
agent_normalize_response() {
    case "$AGENT_PROVIDER" in
        claude)
            agent_claude_normalize_response "$@"
            ;;
        *)
            if declare -f log_status >/dev/null 2>&1; then
                log_status "ERROR" "Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'"
            else
                echo "ERROR: Unknown AGENT_PROVIDER: '$AGENT_PROVIDER'" >&2
            fi
            return 1
            ;;
    esac
}
