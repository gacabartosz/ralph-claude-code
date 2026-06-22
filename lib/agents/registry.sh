#!/usr/bin/env bash
# lib/agents/registry.sh - Agent provider registry (multi-provider epic, #312)
#
# Resolves the active agent provider and dispatches command construction to its
# adapter. This is the abstraction seam for the multi-provider epic.
#
# Claude is the reference adapter and default; Codex (#317), Gemini (#318),
# OpenCode (#319) and Droid (#320) are non-Claude adapters. Selection is #314.
#
# Adapter contract: each provider lib defines agent_<name>_{build_command,
# detect_format,normalize_response,has_capability} + AGENT_<NAME>_CAPABILITIES.
# build populates the shared CLAUDE_CMD_ARGS array; normalize writes Ralph's
# internal analysis struct. The registry routes the agent_* dispatchers to the
# active provider's functions.

# Directory this lib lives in (used to source sibling adapters relative to it).
AGENTS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Active provider default, set at source time (capture-before-source
# convention: ralph_loop.sh records _env_AGENT_PROVIDER BEFORE sourcing this
# lib so an explicit environment value is not masked by this default).
AGENT_PROVIDER="${AGENT_PROVIDER:-claude}"

# Space-separated list of registered providers (adapters available in this lib).
# Provider selection (#314) validates AGENT_PROVIDER against this list.
AGENT_REGISTERED_PROVIDERS="claude codex gemini opencode droid"

# agent_provider_is_registered - return 0 if $1 is a registered provider.
agent_provider_is_registered() {
    local name="$1" p
    for p in $AGENT_REGISTERED_PROVIDERS; do
        [[ "$p" == "$name" ]] && return 0
    done
    return 1
}

# Source the registered adapters.
# shellcheck source=lib/agents/claude.sh
source "$AGENTS_LIB_DIR/claude.sh"
# shellcheck source=lib/agents/codex.sh
source "$AGENTS_LIB_DIR/codex.sh"
# shellcheck source=lib/agents/gemini.sh
source "$AGENTS_LIB_DIR/gemini.sh"
# shellcheck source=lib/agents/opencode.sh
source "$AGENTS_LIB_DIR/opencode.sh"
# shellcheck source=lib/agents/droid.sh
source "$AGENTS_LIB_DIR/droid.sh"

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
        codex)
            agent_codex_build_command "$@"
            ;;
        gemini)
            agent_gemini_build_command "$@"
            ;;
        opencode)
            agent_opencode_build_command "$@"
            ;;
        droid)
            agent_droid_build_command "$@"
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
        codex)
            agent_codex_detect_format "$@"
            ;;
        gemini)
            agent_gemini_detect_format "$@"
            ;;
        opencode)
            agent_opencode_detect_format "$@"
            ;;
        droid)
            agent_droid_detect_format "$@"
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
        codex)
            agent_codex_normalize_response "$@"
            ;;
        gemini)
            agent_gemini_normalize_response "$@"
            ;;
        opencode)
            agent_opencode_normalize_response "$@"
            ;;
        droid)
            agent_droid_normalize_response "$@"
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

# =============================================================================
# CAPABILITIES (multi-provider epic, #315 / MP.4)
# =============================================================================
# Ralph has Claude-specific features (token-usage limiting, the permission-denial
# circuit breaker #101, API-limit detection #100/#183, session resume). For
# providers that cannot supply the underlying signal, those features must no-op
# gracefully rather than misbehave. Adapters declare a capability record; callers
# gate the dependent feature on agent_capability_enabled. Exit detection via
# RALPH_STATUS stays always-on (portable) and is intentionally not gated.

# agent_has_capability <capability> - does the active provider support it?
# Returns 0 if supported, 1 otherwise (unknown providers support nothing).
agent_has_capability() {
    case "$AGENT_PROVIDER" in
        claude)
            agent_claude_has_capability "$@"
            ;;
        codex)
            agent_codex_has_capability "$@"
            ;;
        gemini)
            agent_gemini_has_capability "$@"
            ;;
        opencode)
            agent_opencode_has_capability "$@"
            ;;
        droid)
            agent_droid_has_capability "$@"
            ;;
        *)
            return 1
            ;;
    esac
}

# Space-delimited record of capabilities already warned about, so each
# degradation WARN is logged at most once per process (bash 3.2: a string, not
# an associative array).
_AGENT_CAP_WARNED=""

# agent_capability_enabled <capability> [feature_label]
# Returns 0 if the active provider supports <capability> (caller proceeds).
# Otherwise logs a one-time WARN (per capability) and returns 1 so the caller
# can no-op the dependent feature. feature_label defaults to the capability name.
agent_capability_enabled() {
    local cap="$1" feature_label="${2:-$1}"
    if agent_has_capability "$cap"; then
        return 0
    fi
    case " $_AGENT_CAP_WARNED " in
        *" $cap "*) return 1 ;;  # already warned for this capability
    esac
    _AGENT_CAP_WARNED="$_AGENT_CAP_WARNED $cap"
    if declare -f log_status >/dev/null 2>&1; then
        log_status "WARN" "Provider '$AGENT_PROVIDER' does not support $cap; $feature_label disabled"
    else
        echo "WARN: provider '$AGENT_PROVIDER' does not support $cap; $feature_label disabled" >&2
    fi
    return 1
}
