/// altheia_deepbook::deepbook_adapter
///
/// Venue adapter for DeepBook v3. Reads the pool mid_price on-chain, computes
/// the operator's fair-rate floor, and closes the core hot-potato receipt via
/// `altheia::receipt::consume_with_check` with `DeepBookWitness`.
///
/// `DeepBookWitness` is the registry key: core checks its `type_name` against
/// the on-chain `AdapterRegistry`, so this adapter can settle a withdrawal
/// only while admin keeps it approved. Core measures the received coin itself;
/// this module supplies only the floor.
module altheia_deepbook::deepbook_adapter;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use deepbook::pool::{Self, Pool};
use altheia::receipt::{Self, WithdrawalReceipt};
use altheia::registry::AdapterRegistry;
use altheia::policy::{Self, Policy};
use altheia::actions;

/// Registry key for this adapter. Only this module can construct it, so a
/// `consume_with_check<DeepBookWitness, _>` call proves the receipt is being
/// closed by the DeepBook adapter and nothing else.
public struct DeepBookWitness has drop {}

const BPS_DENOM: u64 = 10_000;

/// Operator hasn't configured the value guard (base_scalar still 0).
const EValueGuardNotConfigured: u64 = 1;

/// DeepBook price scaling: quote_qty = base_qty * mid_price / FLOAT_SCALING
/// (decimal adjustment is baked into mid_price). Holds for both directions.
const FLOAT_SCALING: u128 = 1_000_000_000;

/// Pure: minimum acceptable output (quote base-units) for `amount_in` base
/// base-units swapped at DeepBook `mid_price`, allowing `max_slippage_bps`.
///   expected = amount_in * mid_price / base_scalar
///   floor    = expected * (10_000 - max_slippage_bps) / 10_000
/// mid_price convention (testnet-verified): quote base-units per 1 whole base
/// coin; base_scalar = base coin's smallest-unit scalar.
public fun compute_min_out(
    amount_in: u64,
    mid_price: u64,
    base_scalar: u64,
    max_slippage_bps: u64,
): u64 {
    let expected = (amount_in as u128) * (mid_price as u128) / (base_scalar as u128);
    let floor = expected * ((BPS_DENOM - max_slippage_bps) as u128) / (BPS_DENOM as u128);
    floor as u64
}

/// Pure: minimum acceptable base output for `quote_in` quote base-units spent,
/// the quote->base direction. base_out = quote_in * FLOAT_SCALING / mid_price.
public fun compute_min_base_out(
    quote_in: u64,
    mid_price: u64,
    max_slippage_bps: u64,
): u64 {
    let expected = (quote_in as u128) * FLOAT_SCALING / (mid_price as u128);
    let floor = expected * ((BPS_DENOM - max_slippage_bps) as u128) / (BPS_DENOM as u128);
    floor as u64
}

/// Close the receipt for a base->quote swap. Enforces the `DEEPBOOK_SWAP`
/// capability and reads the value-guard (slippage + scalar) from the on-chain
/// Policy — the agent composes the PTB, so the floor cannot be a caller arg.
/// Reads `mid_price` from `pool`; core reads `coin::value(coin_out)` + registry.
/// `base_left` is the unfilled base, so the floor is on actual spent.
///
/// Aborts: ENotAllowedAction / EValueGuardNotConfigured / ENotApprovedAdapter /
/// ERecipientMismatch / EUnderMinValue.
public fun attest_value_conservation<Base, Quote>(
    r: WithdrawalReceipt,
    registry: &AdapterRegistry,
    policy: &Policy,
    coin_out: &Coin<Quote>,
    base_left: &Coin<Base>,
    pool: &Pool<Base, Quote>,
    clock: &Clock,
    recipient_actual: address,
) {
    policy::assert_allows(policy, actions::deepbook_swap());
    let scalar = policy::base_scalar(policy);
    assert!(scalar > 0, EValueGuardNotConfigured);
    let slippage = policy::max_slippage_bps(policy);
    let price = pool::mid_price(pool, clock);
    let spent = receipt::amount_in(&r) - coin::value(base_left);
    let min_out = compute_min_out(spent, price, scalar, slippage);
    receipt::consume_with_check<DeepBookWitness, Quote>(
        DeepBookWitness {}, registry, r, coin_out, min_out, recipient_actual,
    );
}

/// Close the receipt for a quote->base swap (spend SUI, receive DEEP on the
/// whitelisted DEEP/SUI pool). Same policy-read guard; `quote_left` is the
/// unspent quote so the floor is on actual spent (legit partial fills pass).
///
/// Aborts: ENotAllowedAction / EValueGuardNotConfigured / ENotApprovedAdapter /
/// ERecipientMismatch / EUnderMinValue.
public fun attest_value_conservation_quote_for_base<Base, Quote>(
    r: WithdrawalReceipt,
    registry: &AdapterRegistry,
    policy: &Policy,
    base_out: &Coin<Base>,
    quote_left: &Coin<Quote>,
    pool: &Pool<Base, Quote>,
    clock: &Clock,
    recipient_actual: address,
) {
    policy::assert_allows(policy, actions::deepbook_swap());
    assert!(policy::base_scalar(policy) > 0, EValueGuardNotConfigured);
    let slippage = policy::max_slippage_bps(policy);
    let price = pool::mid_price(pool, clock);
    let spent = receipt::amount_in(&r) - coin::value(quote_left);
    let min_out = compute_min_base_out(spent, price, slippage);
    receipt::consume_with_check<DeepBookWitness, Base>(
        DeepBookWitness {}, registry, r, base_out, min_out, recipient_actual,
    );
}
