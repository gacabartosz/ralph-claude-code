#!/usr/bin/env bats
# Registry / adapter parity guard (multi-provider epic, #327 / MP.15a).
#
# Keeps the provider registry and the per-provider adapters in sync. As adapters
# are added (#317–#322) it is easy to drift: register a provider without its
# functions, ship an adapter file without registering it, or forget a capability
# record. These tests assert the invariants that make `ralph --provider <name>`
# work for EVERY registered provider, so a future adapter PR that breaks parity
# fails fast rather than at runtime.

load '../helpers/test_helper'
load '../helpers/adapter_harness'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR="$TEST_DIR/.ralph"
    mkdir -p "$RALPH_DIR"

    PROMPT_FILE="$TEST_DIR/PROMPT.md"
    printf 'Test prompt content\n' > "$PROMPT_FILE"

    # CLAUDE_CODE_CMD is validated/defaulted at startup in real runs; the claude
    # adapter reads it directly (other adapters inline a ${*_CMD:-name} default).
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    unset CLAUDE_MODEL CLAUDE_EFFORT AGENT_PROVIDER

    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/agents/registry.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]] && rm -rf "$TEST_DIR"
}

# Helper: uppercase a provider name (bash 3.2 has no ${var^^}).
_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

@test "registry parity: there is at least one registered provider incl. claude" {
    [ -n "$AGENT_REGISTERED_PROVIDERS" ]
    [[ " $AGENT_REGISTERED_PROVIDERS " == *" claude "* ]]
}

@test "registry parity: every registered provider defines all 4 contract functions" {
    local p fn
    for p in $AGENT_REGISTERED_PROVIDERS; do
        for fn in build_command detect_format normalize_response has_capability; do
            declare -f "agent_${p}_${fn}" >/dev/null || {
                echo "missing function: agent_${p}_${fn}"
                return 1
            }
        done
    done
}

@test "registry parity: every registered provider declares a well-formed capability record" {
    local p var val
    for p in $AGENT_REGISTERED_PROVIDERS; do
        var="AGENT_$(_upper "$p")_CAPABILITIES"
        val="${!var}"
        # harness_assert_capabilities_wellformed: non-empty, all tokens supports_*
        harness_assert_capabilities_wellformed "$val" || {
            echo "bad capability record in $var: '$val'"
            return 1
        }
    done
}

@test "registry parity: has_capability dispatch agrees with each adapter's own function" {
    # For every registered provider, the registry dispatcher must route to that
    # provider's has_capability (no unknown-provider fallthrough). Check a cap
    # every adapter declares (supports_session_resume) and one none should
    # invent (a bogus cap must be unsupported everywhere).
    local p
    for p in $AGENT_REGISTERED_PROVIDERS; do
        AGENT_PROVIDER="$p"
        if "agent_${p}_has_capability" supports_session_resume; then
            agent_has_capability supports_session_resume || {
                echo "dispatch mismatch (expected supported) for provider: $p"
                return 1
            }
        else
            ! agent_has_capability supports_session_resume || {
                echo "dispatch mismatch (expected unsupported) for provider: $p"
                return 1
            }
        fi
        ! agent_has_capability supports_totally_bogus_cap || {
            echo "provider $p claims a bogus capability via dispatch"
            return 1
        }
    done
}

@test "registry parity: build dispatch yields a non-empty argv for every provider" {
    local p
    for p in $AGENT_REGISTERED_PROVIDERS; do
        AGENT_PROVIDER="$p"
        CLAUDE_CMD_ARGS=()
        agent_build_command "$PROMPT_FILE" "" "" || {
            echo "agent_build_command failed for provider: $p"
            return 1
        }
        [ "${#CLAUDE_CMD_ARGS[@]}" -gt 0 ] || {
            echo "empty CLAUDE_CMD_ARGS for provider: $p"
            return 1
        }
        [ -n "${CLAUDE_CMD_ARGS[0]}" ] || {
            echo "empty argv[0] for provider: $p"
            return 1
        }
    done
}

@test "registry parity: every lib/agents/*.sh adapter is registered (no orphans)" {
    local f name
    for f in "${BATS_TEST_DIRNAME}/../../lib/agents/"*.sh; do
        name="$(basename "$f" .sh)"
        [ "$name" = "registry" ] && continue
        case " $AGENT_REGISTERED_PROVIDERS " in
            *" $name "*) ;;
            *)
                echo "adapter lib/agents/${name}.sh is not in AGENT_REGISTERED_PROVIDERS"
                return 1
                ;;
        esac
    done
}

@test "registry parity: unknown provider is rejected by validation and dispatch" {
    ! agent_provider_is_registered "bogus_provider"
    AGENT_PROVIDER="bogus_provider"
    run agent_build_command "$PROMPT_FILE" "" ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown AGENT_PROVIDER"* ]]
}
