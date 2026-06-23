#!/usr/bin/env bash
# scripts/update_badges.sh - regenerate README version/test-count badges from
# source so they never drift from reality (Issue #138).
#
# Sources of truth:
#   version    : a VERSION file if present, else the README "**Version**: vX.Y.Z"
#                prose line (the human-maintained release marker).
#   test count : the number of `@test` definitions under the npm-test scope
#                (tests/unit + tests/integration) — what `npm test` actually runs.
#
# Usage:
#   scripts/update_badges.sh            # rewrite the badges in README.md
#   scripts/update_badges.sh --check    # exit 1 if the badges are stale (CI guard)
#
# Functions are sourceable (the `main` call is guarded) so they can be unit-tested.

# No `set -e` (repo convention — see Issue #208); be explicit about failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# detect_version <readme_file> [version_file] -> X.Y.Z on stdout (1 if not found)
detect_version() {
    local readme="$1"
    local version_file="${2:-}"

    # 1) Explicit VERSION file wins (strip whitespace + a leading v).
    if [[ -n "$version_file" && -f "$version_file" ]]; then
        local v
        v=$(head -1 "$version_file" | tr -d '[:space:]' | sed -E 's/^v//')
        if [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$v"
            return 0
        fi
    fi

    # 2) README prose: **Version**: vX.Y.Z ...
    local line
    line=$(grep -m1 -E '^\*\*Version\*\*:' "$readme" 2>/dev/null)
    local v
    v=$(printf '%s' "$line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$v" ]]; then
        echo "$v"
        return 0
    fi
    return 1
}

# count_tests <dir>... -> total number of `@test` definitions across the dirs
count_tests() {
    local d total=0
    local -a existing=()
    for d in "$@"; do
        [[ -d "$d" ]] && existing+=("$d")
    done
    if [[ "${#existing[@]}" -gt 0 ]]; then
        total=$(grep -rhE '^@test' "${existing[@]}" 2>/dev/null | wc -l | tr -d '[:space:]')
    fi
    echo "${total:-0}"
}

# read current badge values (for --check / reporting)
read_badge_version() {
    grep -m1 -oE 'badge/version-[0-9]+\.[0-9]+\.[0-9]+-blue' "$1" 2>/dev/null \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}
read_badge_tests() {
    grep -m1 -oE 'badge/tests-[0-9]+%20passing-green' "$1" 2>/dev/null \
        | grep -oE '[0-9]+' | head -1
}

# update_readme_badges <readme> <version> <count> -> rewrites the two badges
update_readme_badges() {
    local readme="$1" version="$2" count="$3"
    # -i.bak is portable across BSD (macOS) and GNU sed; remove the backup after.
    sed -i.bak -E \
        -e "s#(badge/version-)[0-9]+\.[0-9]+\.[0-9]+(-blue)#\1${version}\2#" \
        -e "s#(badge/tests-)[0-9]+(%20passing-green)#\1${count}\2#" \
        "$readme"
    rm -f "${readme}.bak"
}

main() {
    local check_only="false"
    [[ "${1:-}" == "--check" ]] && check_only="true"

    local readme="${README_FILE:-$REPO_ROOT/README.md}"
    local version_file="${VERSION_FILE:-$REPO_ROOT/VERSION}"
    # Default search scope mirrors `npm test` (bats tests/unit tests/integration).
    local tests_unit="${TESTS_UNIT_DIR:-$REPO_ROOT/tests/unit}"
    local tests_integration="${TESTS_INTEGRATION_DIR:-$REPO_ROOT/tests/integration}"

    if [[ ! -f "$readme" ]]; then
        echo "ERROR: README not found: $readme" >&2
        return 1
    fi

    local version count
    version=$(detect_version "$readme" "$version_file") || {
        echo "ERROR: could not determine version (no VERSION file, no **Version**: line)" >&2
        return 1
    }
    count=$(count_tests "$tests_unit" "$tests_integration")

    local cur_version cur_count
    cur_version=$(read_badge_version "$readme")
    cur_count=$(read_badge_tests "$readme")

    if [[ "$check_only" == "true" ]]; then
        if [[ "$cur_version" == "$version" && "$cur_count" == "$count" ]]; then
            echo "Badges up to date: version=$version tests=$count"
            return 0
        fi
        echo "Badges STALE: version $cur_version->$version, tests $cur_count->$count" >&2
        echo "Run scripts/update_badges.sh to fix." >&2
        return 1
    fi

    update_readme_badges "$readme" "$version" "$count"
    echo "Updated badges: version=$version tests=$count"
}

# Only run main when executed directly (sourcing for tests defines functions only).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
