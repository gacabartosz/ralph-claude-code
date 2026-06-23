#!/usr/bin/env bats
# Unit tests for scripts/update_badges.sh - README badge regeneration (Issue #138).

load '../helpers/test_helper'

BADGE_SCRIPT="${BATS_TEST_DIRNAME}/../../scripts/update_badges.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Minimal fake repo: a README with stale badges + a prose version line.
    README="$TEST_DIR/README.md"
    cat > "$README" << 'EOF'
# Demo

![Version](https://img.shields.io/badge/version-0.1.0-blue)
![Tests](https://img.shields.io/badge/tests-5%20passing-green)

**Version**: v0.11.5 - Active Development
EOF

    # Fake test tree with a known number of @test definitions (3 total).
    # NOTE: the marker is assembled at runtime (AT) so this .bats source file has
    # no literal `^@test` line — otherwise bats' own preprocessor would mangle the
    # heredoc and the fixtures would contain zero @test lines.
    mkdir -p "$TEST_DIR/tests/unit" "$TEST_DIR/tests/integration"
    local AT='@test'
    printf '%s "one" { true; }\n%s "two" { true; }\n' "$AT" "$AT" \
        > "$TEST_DIR/tests/unit/a.bats"
    printf '%s "three" { true; }\n' "$AT" \
        > "$TEST_DIR/tests/integration/b.bats"

    # Point the script's defaults at the fake repo.
    export REPO_ROOT="$TEST_DIR"
    export README_FILE="$README"
    export VERSION_FILE="$TEST_DIR/VERSION"   # absent unless a test creates it

    # shellcheck disable=SC1090
    source "$BADGE_SCRIPT"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── version detection ────────────────────────────────────────────────────────

@test "detect_version reads the README **Version** prose line" {
    [ "$(detect_version "$README")" = "0.11.5" ]
}

@test "detect_version prefers a VERSION file when present" {
    printf 'v2.3.4\n' > "$VERSION_FILE"
    [ "$(detect_version "$README" "$VERSION_FILE")" = "2.3.4" ]
}

@test "detect_version ignores a malformed VERSION file and falls back to README" {
    printf 'not-a-version\n' > "$VERSION_FILE"
    [ "$(detect_version "$README" "$VERSION_FILE")" = "0.11.5" ]
}

@test "detect_version fails when no source has a version" {
    local empty="$TEST_DIR/empty.md"
    echo "# nothing here" > "$empty"
    run detect_version "$empty"
    [ "$status" -ne 0 ]
}

# ── test counting ────────────────────────────────────────────────────────────

@test "count_tests sums @test across the given dirs" {
    [ "$(count_tests "$TEST_DIR/tests/unit" "$TEST_DIR/tests/integration")" = "3" ]
}

@test "count_tests tolerates a missing dir" {
    [ "$(count_tests "$TEST_DIR/tests/unit" "$TEST_DIR/tests/nope")" = "2" ]
}

# ── badge rewriting ──────────────────────────────────────────────────────────

@test "update_readme_badges rewrites both badges in place" {
    update_readme_badges "$README" "9.9.9" "42"
    grep -q 'badge/version-9.9.9-blue' "$README"
    grep -q 'badge/tests-42%20passing-green' "$README"
    # no leftover sed backup
    [ ! -f "${README}.bak" ]
}

@test "read_badge_* return the current badge values" {
    [ "$(read_badge_version "$README")" = "0.1.0" ]
    [ "$(read_badge_tests "$README")" = "5" ]
}

# ── main: end-to-end + --check ───────────────────────────────────────────────

@test "main rewrites the badges to match version + test count" {
    export TESTS_UNIT_DIR="$TEST_DIR/tests/unit"
    export TESTS_INTEGRATION_DIR="$TEST_DIR/tests/integration"
    run main
    [ "$status" -eq 0 ]
    grep -q 'badge/version-0.11.5-blue' "$README"
    grep -q 'badge/tests-3%20passing-green' "$README"
}

@test "main --check fails when badges are stale" {
    export TESTS_UNIT_DIR="$TEST_DIR/tests/unit"
    export TESTS_INTEGRATION_DIR="$TEST_DIR/tests/integration"
    run main --check
    [ "$status" -ne 0 ]
    [[ "$output" == *"STALE"* ]]
}

@test "main --check passes once badges are current" {
    export TESTS_UNIT_DIR="$TEST_DIR/tests/unit"
    export TESTS_INTEGRATION_DIR="$TEST_DIR/tests/integration"
    main >/dev/null            # sync first
    run main --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to date"* ]]
}
