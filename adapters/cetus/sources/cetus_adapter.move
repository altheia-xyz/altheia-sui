/// altheia_cetus::cetus_adapter
///
/// Venue adapter for Cetus CLMM. Closes the core hot-potato receipt via
/// `altheia::receipt::consume_with_check` with `CetusWitness`, enforcing the
/// operator-set rate floor on the received coin.
///
/// Cetus's `flash_swap` performs NO slippage check by design (the integrator
/// must), so altheia's value floor IS the slippage guard: the swap output must
/// clear `min_out_from_rate(spent, min_rate)` or the receipt won't close and
/// the whole PTB aborts. The floor is operator-declared (action_params), not
/// read from the pool.
///
/// `CetusWitness` is the registry key: core checks its `type_name` against the
/// on-chain `AdapterRegistry`, so this adapter can settle a withdrawal only
/// while admin keeps it approved.
module altheia_cetus::cetus_adapter;

use sui::coin;
use sui::balance;
use sui::clock::Clock;
use cetus_clmm::config::GlobalConfig;
use cetus_clmm::pool::{Self, Pool};
use altheia::receipt;
use altheia::registry::AdapterRegistry;
use altheia::policy::{Self, Policy};
use altheia::vault::{Self, Vault};
use altheia::agent::AgentCap;
use altheia::actions;

/// Registry key for this adapter. Only this module can construct it, so a
/// `consume_with_check<CetusWitness, _>` call proves the receipt is being closed
/// by the Cetus adapter and nothing else.
public struct CetusWitness has drop {}

/// A swap with a zero operator min_rate has no value floor — reject it.
const EZeroMinRate: u64 = 1;

/// Scale for the operator-set value-guard rate: min_out = spent * rate / RATE_SCALE.
const RATE_SCALE: u128 = 1_000_000_000;

/// Cetus sqrt-price-limit sentinels (no price bound; the value floor is the
/// real guard). a2b clamps to the min tick, b2a to the max tick.
const MIN_SQRT_PRICE: u128 = 4295048016;
const MAX_SQRT_PRICE: u128 = 79226673515401279992447579055;

/// Pure: minimum acceptable output for `spent` input units at the operator's
/// `min_rate` (no oracle — the floor is operator-declared, not market-read).
public fun min_out_from_rate(spent: u64, min_rate: u64): u64 {
    ((spent as u128) * (min_rate as u128) / RATE_SCALE) as u64
}

/// Sell CoinTypeA for CoinTypeB on a Cetus CLMM pool (a2b). The agent calls
/// this one function — the developer deploys nothing. `withdraw_with_receipt`
/// runs check_and_consume<A> first (revoke/pause/expiry/cap/scope). The Cetus
/// flash-swap is repaid from the withdrawn input; the received B must clear the
/// operator floor or `consume_with_check` aborts the PTB.
public fun execute_swap_a_for_b<A, B>(
    vault: &mut Vault,
    cap: &AgentCap,
    policy: &mut Policy,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    registry: &AdapterRegistry,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    policy::assert_allows(policy, actions::cetus_swap());
    let min_rate = policy::action_params(policy, actions::cetus_swap())[0];
    assert!(min_rate > 0, EZeroMinRate);

    let target_pool = object::id(pool).to_address();
    let (coin_in, r) = vault::withdraw_with_receipt<A>(
        vault, cap, policy, amount, target_pool, recipient, b"SWAP", clock, ctx,
    );
    let mut bal_in = coin::into_balance(coin_in);

    // a2b, exact-input: receive B, owe A. flash_swap does NO slippage check.
    let (recv_a, recv_b, fr) = pool::flash_swap<A, B>(
        config, pool, true, true, amount, MIN_SQRT_PRICE, clock,
    );
    let pay = pool::swap_pay_amount(&fr);
    let pay_bal = balance::split(&mut bal_in, pay);
    pool::repay_flash_swap<A, B>(config, pool, pay_bal, balance::zero<B>(), fr);
    settle_remainder(vault, cap, recv_a, ctx); // a2b receives B; re-vault any A returned

    let coin_out = coin::from_balance(recv_b, ctx);
    let min_out = min_out_from_rate(pay, min_rate);
    receipt::consume_with_check<CetusWitness, B>(
        CetusWitness {}, registry, r, &coin_out, min_out, recipient,
    );
    vault::deposit_for(vault, cap, coin_out);
    settle_remainder(vault, cap, bal_in, ctx); // unspent input back to the vault
}

/// Reverse direction: sell CoinTypeB for CoinTypeA (b2a), e.g. unwind a position.
public fun execute_swap_b_for_a<A, B>(
    vault: &mut Vault,
    cap: &AgentCap,
    policy: &mut Policy,
    config: &GlobalConfig,
    pool: &mut Pool<A, B>,
    registry: &AdapterRegistry,
    amount: u64,
    recipient: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    policy::assert_allows(policy, actions::cetus_swap());
    let min_rate = policy::action_params(policy, actions::cetus_swap())[0];
    assert!(min_rate > 0, EZeroMinRate);

    let target_pool = object::id(pool).to_address();
    let (coin_in, r) = vault::withdraw_with_receipt<B>(
        vault, cap, policy, amount, target_pool, recipient, b"SWAP", clock, ctx,
    );
    let mut bal_in = coin::into_balance(coin_in);

    // b2a, exact-input: receive A, owe B.
    let (recv_a, recv_b, fr) = pool::flash_swap<A, B>(
        config, pool, false, true, amount, MAX_SQRT_PRICE, clock,
    );
    let pay = pool::swap_pay_amount(&fr);
    let pay_bal = balance::split(&mut bal_in, pay);
    pool::repay_flash_swap<A, B>(config, pool, balance::zero<A>(), pay_bal, fr);
    settle_remainder(vault, cap, recv_b, ctx); // b2a receives A; re-vault any B returned

    let coin_out = coin::from_balance(recv_a, ctx);
    let min_out = min_out_from_rate(pay, min_rate);
    receipt::consume_with_check<CetusWitness, A>(
        CetusWitness {}, registry, r, &coin_out, min_out, recipient,
    );
    vault::deposit_for(vault, cap, coin_out);
    settle_remainder(vault, cap, bal_in, ctx);
}

/// Re-vault any unspent input (exact-input swaps usually leave zero), or drop a
/// zero balance without registering a dust asset.
fun settle_remainder<T>(vault: &mut Vault, cap: &AgentCap, bal: balance::Balance<T>, ctx: &mut TxContext) {
    if (balance::value(&bal) > 0) {
        vault::deposit_for(vault, cap, coin::from_balance(bal, ctx));
    } else {
        balance::destroy_zero(bal);
    }
}
