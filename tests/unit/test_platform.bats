#!/usr/bin/env bats
# Unit tests for lib/platform.sh - OS + multiplexer detection (Issue #156).

load '../helpers/test_helper'

setup() {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/platform.sh"
}

# ── detect_os (parameterized for cross-platform testability) ─────────────────

@test "detect_os: Linux -> linux" {
    [ "$(detect_os 'Linux')" = "linux" ]
    [ "$(detect_os 'Linux-6.1.0')" = "linux" ]
}

@test "detect_os: Darwin -> macos" {
    [ "$(detect_os 'Darwin')" = "macos" ]
    [ "$(detect_os 'Darwin 24.0.0')" = "macos" ]
}

@test "detect_os: Git-Bash/MSYS2/Cygwin -> windows" {
    [ "$(detect_os 'MINGW64_NT-10.0')" = "windows" ]
    [ "$(detect_os 'MSYS_NT-10.0-19045')" = "windows" ]
    [ "$(detect_os 'CYGWIN_NT-10.0')" = "windows" ]
}

@test "detect_os: anything else -> unknown" {
    [ "$(detect_os 'FreeBSD')" = "unknown" ]
    [ "$(detect_os 'Plan9')" = "unknown" ]
}

@test "detect_os: no argument resolves the real host (one of the known values)" {
    local os
    os=$(detect_os)
    [[ "$os" == "linux" || "$os" == "macos" || "$os" == "windows" || "$os" == "unknown" ]]
}

# ── platform_is_windows ──────────────────────────────────────────────────────

@test "platform_is_windows: true for MINGW, false for Linux/Darwin" {
    platform_is_windows "MINGW64_NT-10.0"
    ! platform_is_windows "Linux"
    ! platform_is_windows "Darwin"
}

# ── platform_is_wsl ──────────────────────────────────────────────────────────

@test "platform_is_wsl: detects the Microsoft kernel marker" {
    platform_is_wsl "5.15.90.1-microsoft-standard-WSL2"
    platform_is_wsl "4.4.0-19041-Microsoft"
}

@test "platform_is_wsl: false for a plain Linux kernel string" {
    ! platform_is_wsl "6.1.0-generic"
}

# ── detect_multiplexer / platform_has_tmux ───────────────────────────────────

@test "detect_multiplexer: reports tmux when available, else none" {
    local mux
    mux=$(detect_multiplexer)
    [[ "$mux" == "tmux" || "$mux" == "none" ]]
    # Must agree with command -v tmux
    if command -v tmux >/dev/null 2>&1; then
        [ "$mux" = "tmux" ]
    else
        [ "$mux" = "none" ]
    fi
}

@test "platform_has_tmux: agrees with detect_multiplexer" {
    if [[ "$(detect_multiplexer)" == "tmux" ]]; then
        platform_has_tmux
    else
        ! platform_has_tmux
    fi
}
