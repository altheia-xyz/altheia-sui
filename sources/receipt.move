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

use altheia::audit;

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

/// Value-conservation close (for swaps): assert the swap output value
/// is >= min_out_value at the caller-supplied price reference (the
/// caller is responsible for sourcing a manipulation-resistant value —
/// e.g. DeepBook TWAP — and passing it in).
public fun attest_value_conservation(
    receipt: WithdrawalReceipt,
    amount_out: u64,
    min_out_value: u64,
    recipient_actual: address,
) {
    assert!(receipt.recipient == recipient_actual, ERecipientMismatch);
    assert!(amount_out >= min_out_value, EUnderMinValue);
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
        amount_out,
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
