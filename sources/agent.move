/// altheia::agent
///
/// Agent capability layer. Every signed action the demo agent (or any
/// integrating agent) makes passes through `AgentCap::consume`, which in
/// turn consumes the linked `policy::Policy`. The agent never holds the
/// policy directly its capability is bounded by what `consume` allows.
///
/// Status: skeleton. Function bodies land May 27-28 per ship plan.
module altheia::agent;

use sui::object::{Self, UID};
use sui::tx_context::{Self, TxContext};
use altheia::policy::{Self, Policy};
use altheia::audit;

/// Per-agent capability bound to a single Policy.
public struct AgentCap has key, store {
    id: UID,
    /// Hash / ID of the agent in altheia's identity registry.
    agent_id: vector<u8>,
    /// Sui object ID of the linked policy.
    policy_id: address,
}

// === Errors ===

const EWrongPolicy: u64 = 1;

// === Entry functions ===

/// Mint an AgentCap pointing at a given Policy object id.
/// Operator calls this once per agent after `policy::mint`.
public fun mint(
    _agent_id: vector<u8>,
    _policy_id: address,
    _ctx: &mut TxContext,
): AgentCap {
    // TODO(May 27): construct AgentCap, return to caller.
    abort 0
}

/// Consume the agent's capability for a proposed action.
/// Routes through `policy::consume` for enforcement; on success emits an
/// `audit::Anchor` event with the allowed verdict.
///
/// Aborts mirror the policy enforcement aborts. On abort, the agent's
/// signing path fails and no chain side-effect occurs (modulo gas).
public fun consume(
    _cap: &AgentCap,
    _policy: &mut Policy,
    _amount: u64,
    _target_package: address,
    _now_ms: u64,
    _ctx: &mut TxContext,
) {
    // TODO(May 28-29):
    //   1. assert cap.policy_id == object::id_address(policy), else EWrongPolicy
    //   2. call altheia::policy::consume(policy, amount, target_package, now_ms)
    //      (will abort on cap/scope/revocation/expiry violation)
    //   3. emit altheia::audit::allowed(cap.agent_id, policy::version(policy), amount, target_package)
    abort 0
}

// === Accessors ===

public fun agent_id(cap: &AgentCap): vector<u8> { cap.agent_id }
public fun policy_id(cap: &AgentCap): address { cap.policy_id }
