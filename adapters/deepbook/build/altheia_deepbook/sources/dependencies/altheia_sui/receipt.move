/// altheia::receipt
///
/// Hot-potato `WithdrawalReceipt`: no abilities, so it cannot be dropped,
/// copied, stored, or transferred. The ONLY way to close it is
/// `consume_with_check`, which requires the witness of a registry-approved
/// adapter. So a withdrawal cannot settle except through an approved adapter
/// that enforces value-conservation — there is no ungated escape hatch.
///
/// This module is protocol-agnostic: it knows nothing about DeepBook or any
/// venue. Each adapter reads its own price/output on-chain, computes the
/// floor, and passes its witness here; core gates on the witness type,
/// measures the received coin itself, and emits the audit anchor.
module altheia::receipt;

use std::type_name;
use sui::coin::{Self, Coin};
use altheia::audit;
use altheia::registry::{Self, AdapterRegistry};

public struct WithdrawalReceipt {
    agent_id: vector<u8>,
    amount_in: u64,
    asset_tag: vector<u8>,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
}

const ERecipientMismatch: u64 = 1;
const EUnderMinValue: u64 = 2;
const ENotApprovedAdapter: u64 = 3;

/// Only vault::withdraw_with_receipt can mint a receipt.
public(package) fun new(
    agent_id: vector<u8>,
    amount_in: u64,
    asset_tag: vector<u8>,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
): WithdrawalReceipt {
    WithdrawalReceipt { agent_id, amount_in, asset_tag, recipient, policy_version, timestamp_ms }
}

#[test_only]
public fun new_for_testing(
    agent_id: vector<u8>, amount_in: u64, asset_tag: vector<u8>,
    recipient: address, policy_version: u64, timestamp_ms: u64,
): WithdrawalReceipt {
    new(agent_id, amount_in, asset_tag, recipient, policy_version, timestamp_ms)
}

/// Close the receipt. Callable only by an approved adapter:
///   - witness `W` proves the call originates from that adapter's module
///     (only it can construct its own witness type);
///   - core checks `type_name::get<W>()` against the on-chain registry;
///   - core measures `coin_out` itself (the adapter cannot forge the amount);
///   - `min_value` is the adapter's fair-rate floor from on-chain price.
///
/// `Out` is the received asset's type (quote of a swap, or the same asset for
/// a passthrough transfer). For a non-value-checked move, pass `min_value = 0`.
///
/// Aborts: ENotApprovedAdapter, ERecipientMismatch, EUnderMinValue.
public fun consume_with_check<W: drop, Out>(
    _w: W,
    registry: &AdapterRegistry,
    receipt: WithdrawalReceipt,
    coin_out: &Coin<Out>,
    min_value: u64,
    recipient_actual: address,
) {
    assert!(registry::is_approved(registry, &type_name::get<W>()), ENotApprovedAdapter);
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    let actual_value = coin::value(coin_out);
    assert!(actual_value >= min_value, EUnderMinValue);
    let WithdrawalReceipt { agent_id, amount_in, asset_tag: _, recipient, policy_version, timestamp_ms } = receipt;
    audit::emit_withdrawal_attested(agent_id, amount_in, actual_value, recipient, policy_version, timestamp_ms);
}

public fun agent_id(receipt: &WithdrawalReceipt): vector<u8> { receipt.agent_id }
public fun amount_in(receipt: &WithdrawalReceipt): u64 { receipt.amount_in }
public fun recipient(receipt: &WithdrawalReceipt): address { receipt.recipient }
public fun policy_version(receipt: &WithdrawalReceipt): u64 { receipt.policy_version }
