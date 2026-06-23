#!/usr/bin/env bats
# Unit tests for lib/cost_utils.sh - token cost estimation (Issue #110, ENH.2a).

load '../helpers/test_helper'

setup() {
    # shellcheck disable=SC1090
    source "${BATS_TEST_DIRNAME}/../../lib/cost_utils.sh"
    unset COST_INPUT_PER_MTOK COST_OUTPUT_PER_MTOK \
          COST_DEFAULT_INPUT_PER_MTOK COST_DEFAULT_OUTPUT_PER_MTOK
}

# ── Rate resolution ──────────────────────────────────────────────────────────

@test "rates: opus models price at 15/75 per MTok" {
    [ "$(get_model_cost_rates 'claude-opus-4-8')" = "15 75" ]
}

@test "rates: sonnet models price at 3/15 per MTok" {
    [ "$(get_model_cost_rates 'claude-sonnet-4-6')" = "3 15" ]
}

@test "rates: haiku models price at 1/5 per MTok" {
    [ "$(get_model_cost_rates 'claude-haiku-4-5')" = "1 5" ]
}

@test "rates: substring match is case-insensitive" {
    [ "$(get_model_cost_rates 'Claude-OPUS-4-8')" = "15 75" ]
}

@test "rates: unknown/empty model falls back to sonnet-class default" {
    [ "$(get_model_cost_rates '')" = "3 15" ]
    [ "$(get_model_cost_rates 'some-other-llm')" = "3 15" ]
}

@test "rates: COST_DEFAULT_* overrides the unknown-model default" {
    export COST_DEFAULT_INPUT_PER_MTOK="2"
    export COST_DEFAULT_OUTPUT_PER_MTOK="8"
    [ "$(get_model_cost_rates 'mystery-model')" = "2 8" ]
}

@test "rates: explicit COST_*_PER_MTOK override wins for any model" {
    export COST_INPUT_PER_MTOK="10"
    export COST_OUTPUT_PER_MTOK="40"
    [ "$(get_model_cost_rates 'claude-opus-4-8')" = "10 40" ]
}

# ── Cost computation ─────────────────────────────────────────────────────────

@test "compute_cost: opus 1M in + 1M out = 15 + 75 = 90" {
    [ "$(compute_cost 'claude-opus-4-8' 1000000 1000000)" = "90.000000" ]
}

@test "compute_cost: sonnet input-only is priced at the input rate" {
    [ "$(compute_cost 'claude-sonnet-4-6' 1000000 0)" = "3.000000" ]
}

@test "compute_cost: output tokens use the (higher) output rate" {
    # haiku: 1M output * $5/MTok = 5.000000
    [ "$(compute_cost 'claude-haiku-4-5' 0 1000000)" = "5.000000" ]
}

@test "compute_cost: small realistic counts (opus 1500 in / 600 out)" {
    # 1500/1e6*15 + 600/1e6*75 = 0.0225 + 0.045 = 0.067500
    [ "$(compute_cost 'claude-opus-4-8' 1500 600)" = "0.067500" ]
}

@test "compute_cost: zero tokens cost nothing" {
    [ "$(compute_cost 'claude-opus-4-8' 0 0)" = "0.000000" ]
}

@test "compute_cost: non-numeric token counts are treated as zero" {
    [ "$(compute_cost 'claude-sonnet-4-6' 'abc' '')" = "0.000000" ]
}

@test "compute_cost: honors explicit rate override" {
    export COST_INPUT_PER_MTOK="10"
    export COST_OUTPUT_PER_MTOK="40"
    # 1M*10 + 1M*40 = 50
    [ "$(compute_cost 'whatever' 1000000 1000000)" = "50.000000" ]
}

# ── Display + accumulation helpers ───────────────────────────────────────────

@test "format_cost_usd: renders a 4dp dollar string" {
    [ "$(format_cost_usd '0.067500')" = "\$0.0675" ]
    [ "$(format_cost_usd '12.5')" = "\$12.5000" ]
}

@test "format_cost_usd: bad input formats as \$0.0000" {
    [ "$(format_cost_usd 'oops')" = "\$0.0000" ]
}

@test "add_cost: accumulates two amounts at 6dp" {
    [ "$(add_cost '0.067500' '0.010000')" = "0.077500" ]
}

@test "add_cost: tolerates empty/garbage operands" {
    [ "$(add_cost '' 'x')" = "0.000000" ]
    [ "$(add_cost '1.5' '')" = "1.500000" ]
}
