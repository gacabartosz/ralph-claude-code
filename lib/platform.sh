#!/usr/bin/env bash
# lib/platform.sh - Cross-platform OS + terminal-multiplexer detection (Issue #156).
#
# A small, dependency-free foundation for Windows awareness. Ralph's existing
# helpers (date_utils, timeout_utils, log_utils) use *capability* detection for
# BSD-vs-GNU differences; this adds explicit OS/multiplexer detection — the
# "platform utilities" component PR #86 proposed — so future Windows wrappers and
# the monitor can branch cleanly.
#
# WSL runs a real Linux userland → detected as "linux" (fully supported today).
# Git-Bash / MSYS2 / Cygwin run bash on Windows → detected as "windows"; most of
# Ralph works there, but tmux-based `--monitor` does not (no tmux on native
# Windows) — detect_multiplexer reports "none" so callers can degrade gracefully.
#
# detect_os takes an optional uname string so it is unit-testable without a real
# Windows host.

# detect_os [uname_s] -> linux | macos | windows | unknown
detect_os() {
    local sys="${1:-$(uname -s 2>/dev/null)}"
    case "$sys" in
        Linux*)               echo "linux" ;;
        Darwin*)              echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
        *)                    echo "unknown" ;;
    esac
}

# platform_is_windows [uname_s] -> 0 if running under Git-Bash/MSYS2/Cygwin.
platform_is_windows() {
    [[ "$(detect_os "$@")" == "windows" ]]
}

# platform_is_wsl -> 0 if running under WSL (Linux kernel reporting Microsoft).
# WSL is a real Linux userland, so detect_os returns "linux"; this distinguishes
# it for documentation/diagnostics. Accepts an optional version-string override.
platform_is_wsl() {
    local rel="${1:-}"
    if [[ -z "$rel" ]]; then
        rel=$(uname -r 2>/dev/null)
        # Some WSL builds only expose the marker via /proc/version
        if [[ ! "$rel" =~ [Mm]icrosoft ]] && [[ -r /proc/version ]]; then
            rel=$(cat /proc/version 2>/dev/null)
        fi
    fi
    [[ "$rel" =~ [Mm]icrosoft ]]
}

# detect_multiplexer -> tmux | none
# Native Windows has no tmux; Windows Terminal split panes would need a Windows
# host to drive and are out of scope here (tracked as BLOCKED in fix_plan).
detect_multiplexer() {
    if command -v tmux >/dev/null 2>&1; then
        echo "tmux"
    else
        echo "none"
    fi
}

# platform_has_tmux -> 0 if a tmux binary is available (so --monitor can work).
platform_has_tmux() {
    [[ "$(detect_multiplexer)" == "tmux" ]]
}
