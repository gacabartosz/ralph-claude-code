#!/usr/bin/env bash
# lib/monorepo.sh - Monorepo awareness: service config parsing + path resolution
# (Issue #163). Pure helpers (bash 3.2, no associative arrays) so the loop and the
# enable/setup tooling can reason about a multi-service repo.
#
# Config (in .ralphrc):
#   MONOREPO_SERVICES="api,web,shared,workers"   # comma/space-separated list
#   MONOREPO_ROOT="services/"                      # optional prefix dir for services
#
# A repo is "monorepo-aware" only when MONOREPO_SERVICES is non-empty; otherwise
# every helper degrades to a no-op so single-package projects are unaffected.

# monorepo_is_enabled -> 0 if MONOREPO_SERVICES declares at least one service.
monorepo_is_enabled() {
    local s
    s=$(printf '%s' "${MONOREPO_SERVICES:-}" | tr ',' ' ' | tr -s '[:space:]' ' ')
    s="${s# }"; s="${s% }"
    [[ -n "$s" ]]
}

# monorepo_list_services -> echo each configured service on its own line (trimmed,
# empties dropped). Accepts comma- or space-separated MONOREPO_SERVICES.
monorepo_list_services() {
    local raw svc
    raw=$(printf '%s' "${MONOREPO_SERVICES:-}" | tr ',' ' ')
    for svc in $raw; do
        [[ -n "$svc" ]] && echo "$svc"
    done
}

# monorepo_has_service <name> -> 0 if <name> is one of the configured services.
monorepo_has_service() {
    local want="$1" svc
    [[ -n "$want" ]] || return 1
    while IFS= read -r svc; do
        [[ "$svc" == "$want" ]] && return 0
    done < <(monorepo_list_services)
    return 1
}

# monorepo_service_path <name> -> the service's path relative to the repo root,
# i.e. "<MONOREPO_ROOT>/<name>" with a normalized (no trailing) root. When
# MONOREPO_ROOT is empty the service name itself is the path.
monorepo_service_path() {
    local name="$1"
    local root="${MONOREPO_ROOT:-}"
    root="${root%/}"          # strip a single trailing slash
    if [[ -n "$root" ]]; then
        echo "$root/$name"
    else
        echo "$name"
    fi
}

# monorepo_resolve_service_dir <name> [base_dir] -> the service path joined to a
# base dir (default: current dir). Does NOT require the dir to exist (callers can
# validate separately); just composes the path predictably.
monorepo_resolve_service_dir() {
    local name="$1"
    local base="${2:-$(pwd)}"
    base="${base%/}"
    echo "$base/$(monorepo_service_path "$name")"
}
