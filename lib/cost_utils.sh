#!/usr/bin/env bash
# lib/cost_utils.sh - Token cost estimation (Issue #110, ENH.2).
#
# Turns token counts into an approximate USD cost so Ralph can surface spending
# in --status / the monitor / ralph-stats. Input and output tokens are priced
# separately (output is typically ~5x input), so callers must pass them apart —
# do NOT sum them first.
#
# Rates are APPROXIMATE list prices in USD per 1,000,000 tokens (MTok) and are
# matched by model-name substring (opus/sonnet/haiku). They drift over time and
# are NOT authoritative billing — override them for accuracy or unknown models:
#   COST_INPUT_PER_MTOK / COST_OUTPUT_PER_MTOK   force rates for ANY model
#   COST_DEFAULT_INPUT_PER_MTOK / COST_DEFAULT_OUTPUT_PER_MTOK  unknown-model default
# Pure bash 3.2 + awk (no floats in bash, no associative arrays).

# get_model_cost_rates <model> -> "<input_per_mtok> <output_per_mtok>"
# Resolves the per-MTok input/output rates for a model name. Precedence:
#   explicit COST_*_PER_MTOK override > known model substring > configurable default.
get_model_cost_rates() {
    local model="$1"

    # Explicit override for any model (both must be set to take effect).
    if [[ -n "${COST_INPUT_PER_MTOK:-}" && -n "${COST_OUTPUT_PER_MTOK:-}" ]]; then
        echo "$COST_INPUT_PER_MTOK $COST_OUTPUT_PER_MTOK"
        return 0
    fi

    local lower
    lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')

    # Unknown-model default (configurable); defaults to sonnet-class pricing.
    local def_in="${COST_DEFAULT_INPUT_PER_MTOK:-3}"
    local def_out="${COST_DEFAULT_OUTPUT_PER_MTOK:-15}"

    case "$lower" in
        *opus*)   echo "15 75" ;;
        *sonnet*) echo "3 15" ;;
        *haiku*)  echo "1 5" ;;
        *)        echo "$def_in $def_out" ;;
    esac
}

# compute_cost <model> <input_tokens> <output_tokens> -> USD (6 decimal places)
# cost = input_tokens/1e6 * input_rate + output_tokens/1e6 * output_rate
compute_cost() {
    local model="$1" in_tok="${2:-0}" out_tok="${3:-0}"

    # Normalize non-numeric inputs to 0 so a malformed token count never breaks
    # the loop (cost is informational).
    [[ "$in_tok" =~ ^[0-9]+$ ]] || in_tok=0
    [[ "$out_tok" =~ ^[0-9]+$ ]] || out_tok=0

    local rates in_rate out_rate
    rates=$(get_model_cost_rates "$model")
    in_rate="${rates%% *}"
    out_rate="${rates##* }"

    awk -v it="$in_tok" -v ot="$out_tok" -v ir="$in_rate" -v orr="$out_rate" \
        'BEGIN { printf "%.6f", (it / 1000000.0) * ir + (ot / 1000000.0) * orr }'
}

# format_cost_usd <amount> -> "$<amount>" rounded to 4 dp for display
# (keeps small per-loop costs visible without scientific notation).
format_cost_usd() {
    local amount="${1:-0}"
    [[ "$amount" =~ ^[0-9.]+$ ]] || amount=0
    awk -v a="$amount" 'BEGIN { printf "$%.4f", a }'
}

# add_cost <a> <b> -> a + b (6 dp); accumulates running totals without bc.
add_cost() {
    local a="${1:-0}" b="${2:-0}"
    [[ "$a" =~ ^[0-9.]+$ ]] || a=0
    [[ "$b" =~ ^[0-9.]+$ ]] || b=0
    awk -v x="$a" -v y="$b" 'BEGIN { printf "%.6f", x + y }'
}
