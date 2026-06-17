/// altheia::audit
///
/// On-chain audit event emission. Every policy decision and every
/// receipt attestation emits an event consumed by altheia's off-chain
/// audit indexer.
///
/// Each event carries the policy version at decision time, for incident
/// replay and data-lineage reconstruction.
module altheia::audit;

use sui::event;

// === Events ===

/// Emitted when an agent's action passes policy.
public struct AllowedAction has copy, drop {
    agent_id: vector<u8>,
    policy_version: u64,
    amount: u64,
    target_package: address,
    timestamp_ms: u64,
}

/// Emitted when an agent's action is denied by policy.
public struct DeniedAction has copy, drop {
    agent_id: vector<u8>,
    policy_version: u64,
    amount: u64,
    target_package: address,
    rule_id: vector<u8>,
    timestamp_ms: u64,
}

/// Emitted when a policy is revoked. Once seen, the agent is dead.
public struct PolicyRevoked has copy, drop {
    agent_id: vector<u8>,
    policy_version: u64,
    timestamp_ms: u64,
}

/// Emitted when a policy is updated (caps, scope, pause/unpause).
public struct PolicyUpdated has copy, drop {
    agent_id: vector<u8>,
    policy_version_before: u64,
    policy_version_after: u64,
    timestamp_ms: u64,
}

/// Emitted by receipt::attest_* when a withdrawal closes its hot potato.
/// `amount_out` >= `amount_in` for simple withdrawals; for swaps it is
/// the asserted post-swap value at attest time.
public struct WithdrawalAttested has copy, drop {
    agent_id: vector<u8>,
    amount_in: u64,
    amount_out: u64,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
}

// === Public emitters ===

public(package) fun emit_allowed(
    agent_id: vector<u8>,
    policy_version: u64,
    amount: u64,
    target_package: address,
    timestamp_ms: u64,
) {
    event::emit(AllowedAction {
        agent_id,
        policy_version,
        amount,
        target_package,
        timestamp_ms,
    });
}

public(package) fun emit_denied(
    agent_id: vector<u8>,
    policy_version: u64,
    amount: u64,
    target_package: address,
    rule_id: vector<u8>,
    timestamp_ms: u64,
) {
    event::emit(DeniedAction {
        agent_id,
        policy_version,
        amount,
        target_package,
        rule_id,
        timestamp_ms,
    });
}

public(package) fun emit_revoked(
    agent_id: vector<u8>,
    policy_version: u64,
    timestamp_ms: u64,
) {
    event::emit(PolicyRevoked {
        agent_id,
        policy_version,
        timestamp_ms,
    });
}

public(package) fun emit_updated(
    agent_id: vector<u8>,
    policy_version_before: u64,
    policy_version_after: u64,
    timestamp_ms: u64,
) {
    event::emit(PolicyUpdated {
        agent_id,
        policy_version_before,
        policy_version_after,
        timestamp_ms,
    });
}

public(package) fun emit_withdrawal_attested(
    agent_id: vector<u8>,
    amount_in: u64,
    amount_out: u64,
    recipient: address,
    policy_version: u64,
    timestamp_ms: u64,
) {
    event::emit(WithdrawalAttested {
        agent_id,
        amount_in,
        amount_out,
        recipient,
        policy_version,
        timestamp_ms,
    });
}
