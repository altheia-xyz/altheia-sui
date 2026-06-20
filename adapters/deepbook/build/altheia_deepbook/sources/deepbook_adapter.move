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
use deepbook::pool::{Self as dbpool, Pool};
use token::deep::DEEP;
use altheia::receipt::{Self, WithdrawalReceipt};
use altheia::registry::AdapterRegistry;
use altheia::policy::{Self, Policy};
use altheia::vault::{Self, Vault};
use altheia::agent::AgentCap;
use altheia::actions;

/// Registry key for this adapter. Only this module can construct it, so a
/// `consume_with_check<DeepBookWitness, _>` call proves the receipt is being
/// closed by the DeepBook adapter and nothing else.
public struct DeepBookWitness has drop {}

const BPS_DENOM: u64 = 10_000;

/// DeepBook price scaling: quote_qty = base_qty * mid_price / FLOAT_SCALING.
const FLOAT_SCALING: u128 = 1_000_000_000;

/// Scale for the operator-set value-guard rate: min_out = spent * rate / RATE_SCALE.
/// rate = minimum output base-units per 1 input quote-unit, times RATE_SCALE.
const RATE_SCALE: u128 = 1_000_000_000;

/// Pure: minimum acceptable output for `spent` input units at the operator's
/// `min_rate` (no oracle — the floor is operator-declared, not market-read).
public fun min_out_from_rate(spent: u64, min_rate: u64): u64 {
    ((spent as u128) * (min_rate as u128) / RATE_SCALE) as u64
}

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

/// Guarded quote->base swap, atomic in one call (spend Quote e.g. SUI, receive
/// Base e.g. DEEP on the whitelisted DEEP/SUI pool). The agent calls this one
/// function — the developer deploys nothing.
///
/// The reference `mid_price` is read BEFORE the swap, because the swap itself
/// moves/empties the book (reading it after can abort or misprice). The
/// value-guard (slippage) is read from the on-chain Policy; the floor is
/// computed on what was actually spent (`amount - quote_left`) so legit partial
/// fills pass. Core measures the received Base coin + checks the registry gate.
///
/// Aborts: ENotAllowedAction / EValueGuardNotConfigured / (policy caps/scope/
/// revoked/paused/expiry) / ENotApprovedAdapter / EUnderMinValue.
public fun execute_swap_quote_for_base<Base, Quote>(
    vault: &mut Vault<Quote>,
    cap: &AgentCap,
    policy: &mut Policy,
    pool: &mut Pool<Base, Quote>,
    registry: &AdapterRegistry,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    policy::assert_allows(policy, actions::deepbook_swap());
    // Operator-set floor rate (base-units out per quote-unit in). No oracle, no
    // book dependency. action_params aborts EActionConfigMissing if unset.
    let min_rate = policy::action_params(policy, actions::deepbook_swap())[0];

    let target_pool = object::id(pool).to_address();
    // withdraw runs check_and_consume first → revoke/pause/expiry/caps/scope.
    let (coin_in, r) = vault::withdraw_with_receipt(
        vault, cap, policy, amount, target_pool, recipient, b"SWAP", clock, ctx,
    );
    let deep_in = coin::zero<DEEP>(ctx);
    let (base_out, quote_left, deep_left) = dbpool::swap_exact_quote_for_base<Base, Quote>(
        pool, coin_in, deep_in, 0, clock, ctx,
    );
    let spent = amount - coin::value(&quote_left);
    let min_out = min_out_from_rate(spent, min_rate);
    receipt::consume_with_check<DeepBookWitness, Base>(
        DeepBookWitness {}, registry, r, &base_out, min_out, recipient,
    );
    transfer::public_transfer(base_out, recipient);
    transfer::public_transfer(quote_left, recipient);
    transfer::public_transfer(deep_left, recipient);
}
