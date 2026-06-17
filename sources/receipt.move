/// altheia::receipt
///
/// Hot-potato `WithdrawalReceipt`: no abilities → cannot be dropped,
/// copied, stored, or transferred. The only way to consume it is via
/// `attest_simple` or `attest_value_conservation` in the same PTB.
///
/// If the PTB ends with an unconsumed receipt, the transaction is
/// invalid and aborts. That's the binding gate — vault::withdraw mints
/// the receipt, and nothing in the PTB can complete without closing it.
module altheia::receipt;

use sui::coin::{Self, Coin};
use sui::clock::Clock;
use deepbook::pool::{Self, Pool};
use altheia::audit;

const BPS_DENOM: u64 = 10_000;

// === Hot potato ===

/// No abilities. Must be consumed by an attest_* function before PTB ends.
public struct WithdrawalReceipt {
    agent_id: vector<u8>,
    amount_in: u64,
    asset_tag: vector<u8>,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
}

// === Errors ===
const ERecipientMismatch: u64 = 1;
const EUnderMinValue: u64 = 2;

// === Package-visible constructor ===

/// Only vault::withdraw_with_receipt can mint a receipt.
public(package) fun new(
    agent_id: vector<u8>,
    amount_in: u64,
    asset_tag: vector<u8>,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
): WithdrawalReceipt {
    WithdrawalReceipt {
        agent_id,
        amount_in,
        asset_tag,
        recipient,
        policy_version,
        timestamp_ms,
    }
}

// === Attestations (consume the receipt) ===

/// Simple withdrawal close: assert recipient matches what the receipt
/// intended, emit WithdrawalAttested, destructure receipt.
public fun attest_simple(
    receipt: WithdrawalReceipt,
    recipient_actual: address,
) {
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    let WithdrawalReceipt {
        agent_id,
        amount_in,
        asset_tag: _,
        recipient,
        policy_version,
        timestamp_ms,
    } = receipt;
    audit::emit_withdrawal_attested(
        agent_id,
        amount_in,
        amount_in,
        recipient,
        policy_version,
        timestamp_ms,
    );
}

/// Pure: minimum acceptable output (quote base-units) for `amount_in` base
/// base-units swapped at DeepBook `mid_price`, allowing `max_slippage_bps`.
///
///   expected = amount_in * mid_price / base_scalar
///   floor    = expected * (10_000 - max_slippage_bps) / 10_000
///
/// mid_price convention verified on testnet 2026-06-17: raw mid_price is
/// quote base-units per 1 WHOLE base coin (SUI/DBUSDC returned 794000 =
/// 0.794 DBUSDC/SUI). `base_scalar` is the base coin's smallest-unit scalar
/// (1e9 for SUI). u128 intermediates prevent overflow.
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

/// Consume the receipt, asserting the swap output meets the fair-rate floor.
///
/// Reads `mid_price` from `pool` and `coin::value(coin_out)`; computes the
/// floor via `compute_min_out(amount_in, mid_price, base_scalar,
/// max_slippage_bps)`; aborts `EUnderMinValue` if the output is below it.
/// Neither the price nor the output is caller-supplied. Callers source
/// `base_scalar` + `max_slippage_bps` from the operator's Policy.
///
/// Aborts: ERecipientMismatch, EUnderMinValue.
public fun attest_value_conservation<Base, Quote>(
    receipt: WithdrawalReceipt,
    coin_out: &Coin<Quote>,
    pool: &Pool<Base, Quote>,
    clock: &Clock,
    base_scalar: u64,
    max_slippage_bps: u64,
    recipient_actual: address,
) {
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    let price = pool::mid_price(pool, clock);
    let min_out = compute_min_out(receipt.amount_in, price, base_scalar, max_slippage_bps);
    let actual = coin::value(coin_out);
    assert!(actual >= min_out, EUnderMinValue);
    let WithdrawalReceipt {
        agent_id,
        amount_in,
        asset_tag: _,
        recipient,
        policy_version,
        timestamp_ms,
    } = receipt;
    audit::emit_withdrawal_attested(
        agent_id,
        amount_in,
        actual,
        recipient,
        policy_version,
        timestamp_ms,
    );
}

// === Accessors ===

public fun agent_id(receipt: &WithdrawalReceipt): vector<u8> { receipt.agent_id }
public fun amount_in(receipt: &WithdrawalReceipt): u64 { receipt.amount_in }
public fun recipient(receipt: &WithdrawalReceipt): address { receipt.recipient }
public fun policy_version(receipt: &WithdrawalReceipt): u64 { receipt.policy_version }
