/// altheia_deepbook::trading_account
///
/// Custody wrapper for DeepBook order-book trading. The USER owns the
/// DeepBook `BalanceManager` (so only the user can withdraw — `withdraw_all`
/// checks `ctx.sender == owner`). The user mints a `TradeCap` (trade-not-
/// withdraw) and deposits it here, bound to a Policy. The agent places/cancels
/// orders through this shared object; the wrapper generates a trade-proof from
/// the held TradeCap under policy. The agent can never extract the TradeCap and
/// can never withdraw funds — non-custodial.
///
/// Order-book actions settle against the BalanceManager, not the Vault, so they
/// don't pass through `check_and_consume`; they call `policy::assert_active`
/// (revoke/pause/expiry) + `assert_allows` + a placement band check instead.
module altheia_deepbook::trading_account;

use sui::clock::Clock;
use deepbook::balance_manager::{Self, BalanceManager, TradeCap};
use deepbook::pool::{Self, Pool};
use altheia::policy::{Self, Policy};
use altheia::agent::{Self, AgentCap};
use altheia::actions;

/// Holds the user's trade-only TradeCap, bound to one Policy.
public struct TradingAccount has key {
    id: UID,
    trade_cap: TradeCap,
    policy_id: ID,
}

const EWrongPolicy: u64 = 1;
const EPriceOutOfBand: u64 = 2;
const ESizeTooLarge: u64 = 3;

/// User-built: deposit a TradeCap (minted from your own BalanceManager) bound
/// to `policy`. Shared so the agent can reference it; the TradeCap inside can
/// never be extracted.
public fun create(trade_cap: TradeCap, policy: &Policy, ctx: &mut TxContext) {
    transfer::share_object(TradingAccount {
        id: object::new(ctx),
        trade_cap,
        policy_id: object::id(policy),
    });
}

/// Pure placement guard against the policy band params
/// [min_price, max_price, max_size]. A limit order's value is guaranteed by
/// its price (it fills at that price or better), so the floor is checked here,
/// at placement — there is no later altheia tx at fill time.
public fun check_limit(price: u64, quantity: u64, params: &vector<u64>) {
    assert!(price >= params[0] && price <= params[1], EPriceOutOfBand);
    assert!(quantity <= params[2], ESizeTooLarge);
}

/// Agent places a resting limit order, bounded by policy.
/// Aborts: EWrongPolicy / (policy) EPolicyRevoked|Paused|Expired /
/// ENotAllowedAction / EPriceOutOfBand / ESizeTooLarge.
public fun place_limit_order<Base, Quote>(
    account: &TradingAccount,
    cap: &AgentCap,
    policy: &Policy,
    pool: &mut Pool<Base, Quote>,
    bm: &mut BalanceManager,
    client_order_id: u64,
    order_type: u8,
    self_matching_option: u8,
    price: u64,
    quantity: u64,
    is_bid: bool,
    pay_with_deep: bool,
    expire_timestamp: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(agent::policy_id(cap) == account.policy_id, EWrongPolicy);
    policy::assert_active(policy, cap, clock);
    policy::assert_allows(policy, actions::deepbook_limit_order());
    let params = policy::action_params(policy, actions::deepbook_limit_order());
    check_limit(price, quantity, &params);
    let proof = balance_manager::generate_proof_as_trader(bm, &account.trade_cap, ctx);
    pool::place_limit_order<Base, Quote>(
        pool, bm, &proof, client_order_id, order_type, self_matching_option,
        price, quantity, is_bid, pay_with_deep, expire_timestamp, clock, ctx,
    );
}

/// Agent cancels all of its resting orders in `pool`.
/// Aborts: EWrongPolicy / (policy) EPolicyRevoked|Paused|Expired / ENotAllowedAction.
public fun cancel_all<Base, Quote>(
    account: &TradingAccount,
    cap: &AgentCap,
    policy: &Policy,
    pool: &mut Pool<Base, Quote>,
    bm: &mut BalanceManager,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(agent::policy_id(cap) == account.policy_id, EWrongPolicy);
    policy::assert_active(policy, cap, clock);
    policy::assert_allows(policy, actions::deepbook_cancel());
    let proof = balance_manager::generate_proof_as_trader(bm, &account.trade_cap, ctx);
    pool::cancel_all_orders<Base, Quote>(pool, bm, &proof, clock, ctx);
}

// === Tests (pure placement guard; the pool calls are integration-tested) ===

#[test]
fun limit_band_in_range_ok() {
    check_limit(100, 10, &vector[10u64, 1_000u64, 50u64]);
}

#[test]
#[expected_failure(abort_code = EPriceOutOfBand)]
fun limit_band_low_price_aborts() {
    check_limit(5, 10, &vector[10u64, 1_000u64, 50u64]);
}

#[test]
#[expected_failure(abort_code = EPriceOutOfBand)]
fun limit_band_high_price_aborts() {
    check_limit(2_000, 10, &vector[10u64, 1_000u64, 50u64]);
}

#[test]
#[expected_failure(abort_code = ESizeTooLarge)]
fun limit_band_oversize_aborts() {
    check_limit(100, 51, &vector[10u64, 1_000u64, 50u64]);
}
