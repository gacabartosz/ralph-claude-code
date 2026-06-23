#!/usr/bin/env bats
# Tests for flake.nix - Nix reproducible-install support (Issue #157).
#
# Structural assertions run everywhere (they guard the flake's content against
# drift). The actual `nix build` smoke check only runs where Nix is installed
# (CI / Nix hosts); it is skipped otherwise so the suite stays green on plain
# bash hosts.

load '../helpers/test_helper'

FLAKE="${BATS_TEST_DIRNAME}/../../flake.nix"

# ── Structural assertions ────────────────────────────────────────────────────

@test "flake.nix exists at the repo root" {
    [ -f "$FLAKE" ]
}

@test "flake.nix declares a description" {
    grep -qE '^\s*description\s*=' "$FLAKE"
}

@test "flake.nix wires nixpkgs + flake-utils inputs" {
    grep -q 'nixpkgs.url' "$FLAKE"
    grep -q 'flake-utils.url' "$FLAKE"
    grep -q 'eachDefaultSystem' "$FLAKE"
}

@test "flake.nix exposes packages.default, apps.default and devShells.default" {
    grep -q 'packages.default' "$FLAKE"
    grep -q 'apps.default' "$FLAKE"
    grep -q 'devShells.default' "$FLAKE"
}

@test "flake.nix bundles all documented runtime dependencies" {
    local dep
    for dep in jq git nodejs tmux coreutils gnugrep gnused; do
        grep -q "$dep" "$FLAKE" || {
            echo "missing runtime dep in flake.nix: $dep"
            return 1
        }
    done
    # some bash flavor must be present
    grep -qE 'bashInteractive|[^a-zA-Z]bash[^a-zA-Z]' "$FLAKE"
}

@test "flake.nix maps every ralph command to its backing script" {
    # command=script pairs mirroring install.sh
    grep -q '\[ralph\]=ralph_loop.sh' "$FLAKE"
    grep -q '\[ralph-monitor\]=ralph_monitor.sh' "$FLAKE"
    grep -q '\[ralph-setup\]=setup.sh' "$FLAKE"
    grep -q '\[ralph-import\]=ralph_import.sh' "$FLAKE"
    grep -q '\[ralph-migrate\]=migrate_to_ralph_folder.sh' "$FLAKE"
    grep -q '\[ralph-enable\]=ralph_enable.sh' "$FLAKE"
    grep -q '\[ralph-enable-ci\]=ralph_enable_ci.sh' "$FLAKE"
    grep -q '\[ralph-stats\]=ralph-stats.sh' "$FLAKE"
}

@test "flake.nix wraps commands so deps land on PATH" {
    grep -q 'makeWrapper' "$FLAKE"
    grep -q 'makeBinPath' "$FLAKE"
}

@test "flake.nix declares MIT license and ralph as mainProgram" {
    grep -q 'licenses.mit' "$FLAKE"
    grep -q 'mainProgram = "ralph"' "$FLAKE"
}

@test "flake.nix dev shell includes the bats test toolchain" {
    grep -q 'bats' "$FLAKE"
}

# ── Build smoke check (Nix hosts / CI only) ──────────────────────────────────

@test "nix flake check passes (skipped without nix)" {
    command -v nix >/dev/null 2>&1 || skip "nix not installed"
    run nix --extra-experimental-features 'nix-command flakes' \
        flake check "${BATS_TEST_DIRNAME}/../.." --no-build
    [ "$status" -eq 0 ]
}

@test "nix build produces a ralph entrypoint (skipped without nix)" {
    command -v nix >/dev/null 2>&1 || skip "nix not installed"
    cd "$BATS_TEST_DIRNAME/../.."
    run nix --extra-experimental-features 'nix-command flakes' build --no-link --print-out-paths
    [ "$status" -eq 0 ]
    local out="${lines[-1]}"
    [ -x "$out/bin/ralph" ]
}
