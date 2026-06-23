#!/usr/bin/env bats
# Unit tests for lib/monorepo.sh - monorepo service config + path resolution (#163).

load '../helpers/test_helper'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    unset MONOREPO_SERVICES MONOREPO_ROOT
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/monorepo.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# ── monorepo_is_enabled ──────────────────────────────────────────────────────

@test "monorepo_is_enabled: false when MONOREPO_SERVICES unset" {
    run monorepo_is_enabled
    [ "$status" -ne 0 ]
}

@test "monorepo_is_enabled: false when MONOREPO_SERVICES is blank/whitespace" {
    export MONOREPO_SERVICES="   "
    run monorepo_is_enabled
    [ "$status" -ne 0 ]
}

@test "monorepo_is_enabled: true when at least one service declared" {
    export MONOREPO_SERVICES="api"
    run monorepo_is_enabled
    [ "$status" -eq 0 ]
}

# ── monorepo_list_services ───────────────────────────────────────────────────

@test "monorepo_list_services: splits a comma-separated list" {
    export MONOREPO_SERVICES="api,web,shared"
    run monorepo_list_services
    [ "${lines[0]}" = "api" ]
    [ "${lines[1]}" = "web" ]
    [ "${lines[2]}" = "shared" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "monorepo_list_services: tolerates spaces and empty entries" {
    export MONOREPO_SERVICES="api, web ,, shared"
    run monorepo_list_services
    [ "${lines[0]}" = "api" ]
    [ "${lines[1]}" = "web" ]
    [ "${lines[2]}" = "shared" ]
    [ "${#lines[@]}" -eq 3 ]
}

@test "monorepo_list_services: empty when unset" {
    run monorepo_list_services
    [ "${#lines[@]}" -eq 0 ]
}

# ── monorepo_has_service ─────────────────────────────────────────────────────

@test "monorepo_has_service: true for a configured service" {
    export MONOREPO_SERVICES="api,web,shared"
    run monorepo_has_service "web"
    [ "$status" -eq 0 ]
}

@test "monorepo_has_service: false for an unknown service" {
    export MONOREPO_SERVICES="api,web"
    run monorepo_has_service "billing"
    [ "$status" -ne 0 ]
}

@test "monorepo_has_service: false for empty argument" {
    export MONOREPO_SERVICES="api,web"
    run monorepo_has_service ""
    [ "$status" -ne 0 ]
}

@test "monorepo_has_service: no partial/substring match" {
    export MONOREPO_SERVICES="api-gateway,web"
    run monorepo_has_service "api"
    [ "$status" -ne 0 ]
}

# ── monorepo_service_path ────────────────────────────────────────────────────

@test "monorepo_service_path: prefixes MONOREPO_ROOT (trailing slash normalized)" {
    export MONOREPO_ROOT="services/"
    [ "$(monorepo_service_path api)" = "services/api" ]
}

@test "monorepo_service_path: root without trailing slash works" {
    export MONOREPO_ROOT="packages"
    [ "$(monorepo_service_path shared)" = "packages/shared" ]
}

@test "monorepo_service_path: bare service name when MONOREPO_ROOT unset" {
    [ "$(monorepo_service_path api)" = "api" ]
}

# ── monorepo_resolve_service_dir ─────────────────────────────────────────────

@test "monorepo_resolve_service_dir: joins base dir + service path" {
    export MONOREPO_ROOT="services"
    [ "$(monorepo_resolve_service_dir api /repo)" = "/repo/services/api" ]
}

@test "monorepo_resolve_service_dir: defaults base to cwd" {
    export MONOREPO_ROOT="services"
    cd "$TEST_DIR"
    [ "$(monorepo_resolve_service_dir web)" = "$TEST_DIR/services/web" ]
}
