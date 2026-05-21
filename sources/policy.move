/// altheia::policy
///
/// Per-agent capability object encoding policy DSL constraints for the
/// (sui, move-policy-object) substrate.
///
/// Implements `provision` and `revoke` from the substrate-adapter contract v1.0
/// (see altheia-plan/02_SRS/substrate-adapter/CONTRACT.md).
///
/// Status: skeleton. Function bodies + tests land May 23-28 per
/// altheia-plan/01_PHASES/sui/SHIP_PLAN_2026_05_22.md.
module altheia::policy;

use sui::object::{Self, UID, ID};
use sui::tx_context::{Self, TxContext};
use sui::transfer;
use std::vector;

/// Owner capability returned to the operator at `provision` time.
/// Holding this is the only way to revoke or update the linked `Policy`.
public struct OwnerCap has key, store {
    id: UID,
    policy_id: ID,
}

/// Per-agent policy capability. Lives at a Sui object ID known to the
/// operator + agent. The agent's signing path consumes a reference to this
/// object before every action; on-chain enforcement happens here.
public struct Policy has key {
    id: UID,
    /// Agent identifier this policy is bound to.
    agent_id: vector<u8>,
    /// Per-transaction cap (in smallest unit of the token).
    per_tx_cap: u64,
    /// Per-day cap.
    per_day_cap: u64,
    /// Allowed package addresses the agent can call into.
    allowed_packages: vector<address>,
    /// Expiry epoch in milliseconds. Past this, the cap is dead.
    expires_at_ms: u64,
    /// Spent amount within the current day window.
    spent_today: u64,
    /// Day-window start epoch ms; rolls over on consume.
    day_window_started_ms: u64,
    /// Revoked flag. Once true, every consume aborts.
    revoked: bool,
    /// Monotonic policy version. Incremented on every update + revoke.
    /// Required for incident-replay (Phase 1.6 feature).
    version: u64,
}

// === Errors ===

const EPolicyRevoked: u64 = 1;
const EPolicyExpired: u64 = 2;
const ECapExceeded: u64 = 3;
const EPackageNotAllowed: u64 = 4;
const ENotOwner: u64 = 5;

// === Entry functions ===

/// Provision a new policy capability for `agent_id` with the given caps + scope.
/// Returns the policy to a shared object so the agent can consume it; returns
/// the OwnerCap to the operator who provisioned it.
///
/// Mirrors `SubstrateAdapter::provision(policy)` from CONTRACT.md.
public fun mint(
    _agent_id: vector<u8>,
    _per_tx_cap: u64,
    _per_day_cap: u64,
    _allowed_packages: vector<address>,
    _expires_at_ms: u64,
    _ctx: &mut TxContext,
): OwnerCap {
    // TODO(May 23-25): construct Policy + share it; return OwnerCap to caller.
    // Stub: aborts so the function is unimplemented but the signature compiles.
    abort 0
}

/// Update the caps on an existing policy. Owner-gated.
public fun update_caps(
    _policy: &mut Policy,
    _owner: &OwnerCap,
    _new_per_tx: u64,
    _new_per_day: u64,
) {
    // TODO(May 25-26): authorize via owner_cap.policy_id == object::id(policy),
    // mutate caps, bump version.
    abort 0
}

/// Revoke the policy capability. Owner-gated. Bumps version.
/// Once revoked, all subsequent `consume` calls abort.
///
/// Mirrors `SubstrateAdapter::revoke(token)` from CONTRACT.md.
public fun revoke(_policy: &mut Policy, _owner: &OwnerCap) {
    // TODO(May 26): assert owner; set revoked = true; bump version.
    abort 0
}

/// Consume the policy capability for a proposed action. Aborts if any cap
/// is violated or the policy is revoked / expired / package not allowed.
///
/// Called by `agent::AgentCap::consume`, never directly. Encodes the
/// substrate-side `enforce` behavior the SDK's `enforce` method mirrors
/// off-chain.
public(package) fun consume(
    _policy: &mut Policy,
    _amount: u64,
    _target_package: address,
    _now_ms: u64,
) {
    // TODO(May 29-30): full enforcement path.
    //   1. assert !revoked, else EPolicyRevoked
    //   2. assert now_ms < expires_at_ms, else EPolicyExpired
    //   3. assert amount <= per_tx_cap, else ECapExceeded
    //   4. roll daily window if now_ms > day_window_started_ms + 86_400_000
    //   5. assert spent_today + amount <= per_day_cap, else ECapExceeded
    //   6. assert vector::contains(&allowed_packages, &target_package), else EPackageNotAllowed
    //   7. spent_today += amount
    abort 0
}

// === Accessors (read-only) ===

public fun version(policy: &Policy): u64 { policy.version }
public fun is_revoked(policy: &Policy): bool { policy.revoked }
public fun agent_id(policy: &Policy): vector<u8> { policy.agent_id }
