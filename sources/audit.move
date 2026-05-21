/// altheia::audit
///
/// On-chain audit event emission. Every policy decision (allowed, denied,
/// revoked, updated) emits an event consumed by altheia's off-chain audit
/// indexer + hourly Merkle anchoring.
///
/// Each event carries the policy version at decision time required for
/// incident replay (Phase 1.6 feature) and data lineage (regulatory ask).
///
/// Status: skeleton. Event structs land May 27, full wiring through
/// agent::consume lands May 31 - Jun 1 per ship plan.
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
/// `rule_id` is a stable string identifier so the off-chain audit
/// indexer can dedupe + classify.
public struct DeniedAction has copy, drop {
    agent_id: vector<u8>,
    policy_version: u64,
    amount: u64,
    target_package: address,
    rule_id: vector<u8>,
    timestamp_ms: u64,
}

/// Emitted when a policy is revoked. Once seen, the audit pipeline
/// knows the agent is dead.
public struct PolicyRevoked has copy, drop {
    agent_id: vector<u8>,
    policy_version: u64,
    timestamp_ms: u64,
}

/// Emitted when a policy is updated (caps, scope changes).
public struct PolicyUpdated has copy, drop {
    agent_id: vector<u8>,
    policy_version_before: u64,
    policy_version_after: u64,
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
