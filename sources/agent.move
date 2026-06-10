/// altheia::agent
///
/// Per-agent capability. Non-transferable (`key` only, no `store`) — once
/// minted to an address, the agent cannot give it away.
///
/// Binds the agent to (vault_id, policy_id). vault::withdraw_with_receipt
/// checks vault_id; policy::check_and_consume checks policy_id.
module altheia::agent;

/// Capability the agent holds. `key` only — module-internal transfer only.
public struct AgentCap has key {
    id: UID,
    agent_id: vector<u8>,
    vault_id: ID,
    policy_id: ID,
}

// === Package-visible constructor + transfer ===

/// Mints an AgentCap and transfers it directly to `recipient`. Only
/// callable from inside the package (specifically: vault::mint_agent_cap).
/// Because AgentCap is `key` only, this is the ONLY way to deliver it —
/// `public_transfer` won't compile on it.
public(package) fun mint_and_transfer(
    agent_id: vector<u8>,
    vault_id: ID,
    policy_id: ID,
    recipient: address,
    ctx: &mut TxContext,
) {
    let cap = AgentCap {
        id: object::new(ctx),
        agent_id,
        vault_id,
        policy_id,
    };
    transfer::transfer(cap, recipient);
}

// === Accessors ===

public fun agent_id(cap: &AgentCap): vector<u8> { cap.agent_id }
public fun vault_id(cap: &AgentCap): ID { cap.vault_id }
public fun policy_id(cap: &AgentCap): ID { cap.policy_id }
public fun id(cap: &AgentCap): ID { object::id(cap) }
