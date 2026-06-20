/// altheia::receipt
///
/// Hot-potato `WithdrawalReceipt`: no abilities, so it cannot be dropped,
/// copied, stored, or transferred. It must be consumed by `attest_simple`
/// or by a protocol adapter via `consume_with_check` before the PTB ends,
/// else the transaction aborts.
///
/// This module is protocol-agnostic: it knows nothing about DeepBook or any
/// venue. Adapters compute the actual/min values from on-chain state and
/// call `consume_with_check`.
module altheia::receipt;

use altheia::audit;

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

/// Close with a recipient check only (no value assertion).
public fun attest_simple(receipt: WithdrawalReceipt, recipient_actual: address) {
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    let WithdrawalReceipt { agent_id, amount_in, asset_tag: _, recipient, policy_version, timestamp_ms } = receipt;
    audit::emit_withdrawal_attested(agent_id, amount_in, amount_in, recipient, policy_version, timestamp_ms);
}

/// Generic value-checked close for protocol adapters. The adapter computes
/// `actual_value` from the received asset and `min_value` from an on-chain
/// price plus the operator's bound, then calls this. Core stays
/// protocol-agnostic; the agent cannot forge either value (the adapter
/// reads them on-chain).
///
/// Aborts: ERecipientMismatch, EUnderMinValue.
public fun consume_with_check(
    receipt: WithdrawalReceipt,
    actual_value: u64,
    min_value: u64,
    recipient_actual: address,
) {
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    assert!(actual_value >= min_value, EUnderMinValue);
    let WithdrawalReceipt { agent_id, amount_in, asset_tag: _, recipient, policy_version, timestamp_ms } = receipt;
    audit::emit_withdrawal_attested(agent_id, amount_in, actual_value, recipient, policy_version, timestamp_ms);
}

public fun agent_id(receipt: &WithdrawalReceipt): vector<u8> { receipt.agent_id }
public fun amount_in(receipt: &WithdrawalReceipt): u64 { receipt.amount_in }
public fun recipient(receipt: &WithdrawalReceipt): address { receipt.recipient }
public fun policy_version(receipt: &WithdrawalReceipt): u64 { receipt.policy_version }
