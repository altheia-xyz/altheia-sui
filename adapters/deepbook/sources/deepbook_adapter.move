/// altheia_deepbook::deepbook_adapter
///
/// Venue adapter for DeepBook v3. Closes the core hot-potato receipt via
/// `altheia::receipt::consume_with_check` with `DeepBookWitness`, enforcing the
/// operator-set rate floor on the received coin. The floor is operator-declared
/// (action_params), not read from the pool; the `compute_min_out*` mid_price
/// helpers below are provided for callers but not used by the live swap path.
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

/// A swap with a zero operator min_rate has no value floor — reject it rather
/// than execute an unguarded swap.
const EZeroMinRate: u64 = 1;

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

/// Pure: optional sell-side floor rate from `action_params`. `params[1]` is the
/// sell min_rate (quote out per base spent); absent (length < 2) means no
/// sell-side floor, preserving compatibility with buy-only `[min_rate]` configs
/// already set on existing policies.
public fun sell_min_rate(params: &vector<u64>): u64 {
    if (params.length() >= 2) params[1] else 0
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
    vault: &mut Vault,
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
    // A zero min_rate floors min_out at 0 (no value guard). Reject rather than
    // execute an unguarded swap — the operator must set a real floor.
    assert!(min_rate > 0, EZeroMinRate);

    let target_pool = object::id(pool).to_address();
    // withdraw runs check_and_consume<Quote> first → revoke/pause/expiry/cap/scope.
    let (coin_in, r) = vault::withdraw_with_receipt<Quote>(
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
    // Settle back INTO the vault so the agent holds the position and can later
    // sell it (round-trip). Funds never leave the operator's vault on a swap.
    vault::deposit_for(vault, cap,base_out);
    vault::deposit_for(vault, cap,quote_left);
    vault::deposit_for(vault, cap,deep_left);
}

/// Reverse direction: sell Base for Quote (unwind a position). The input Base is
/// withdrawn from the vault — if it's an uncapped position asset, the core lets
/// it through (selling reduces risk); if the operator capped Base, the cap
/// applies. Proceeds (Quote) settle back into the vault. Optional sell-side
/// floor: if the operator set a second `action_params` element (`params[1]`),
/// it is the sell min_rate and the proceeds must clear `min_out_from_rate`;
/// absent, there is no sell floor (backward compatible with buy-only configs).
public fun execute_swap_base_for_quote<Base, Quote>(
    vault: &mut Vault,
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
    // Optional operator sell-side floor (params[1]); 0 if unset → no floor.
    let floor_rate = if (policy::has_action_params(policy, actions::deepbook_swap())) {
        sell_min_rate(&policy::action_params(policy, actions::deepbook_swap()))
    } else { 0 };
    let target_pool = object::id(pool).to_address();
    let (coin_in, r) = vault::withdraw_with_receipt<Base>(
        vault, cap, policy, amount, target_pool, recipient, b"SWAP", clock, ctx,
    );
    let deep_in = coin::zero<DEEP>(ctx);
    let (base_left, quote_out, deep_left) = dbpool::swap_exact_base_for_quote<Base, Quote>(
        pool, coin_in, deep_in, 0, clock, ctx,
    );
    let spent = amount - coin::value(&base_left);
    let min_out = min_out_from_rate(spent, floor_rate);
    receipt::consume_with_check<DeepBookWitness, Quote>(
        DeepBookWitness {}, registry, r, &quote_out, min_out, recipient,
    );
    vault::deposit_for(vault, cap,quote_out);
    vault::deposit_for(vault, cap,base_left);
    vault::deposit_for(vault, cap,deep_left);
}
