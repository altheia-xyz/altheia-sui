/// altheia::policy
///
/// Per-agent policy as a SHARED object. Holds caps + scope + cumulative
/// spend state. Because Policy is shared, the daily window state
/// persists across PTBs — closes the per-PTB splitting hole the 4-lens
/// review identified.
///
/// `check_and_consume` is the enforcement gate, called by
/// vault::withdraw_with_receipt before any Coin leaves the vault.
module altheia::policy;

use sui::clock::{Self, Clock};
use altheia::agent::{Self, AgentCap};
use altheia::audit;

/// Per-agent policy object. Shared at mint via vault::mint_policy.
public struct Policy has key {
    id: UID,
    agent_id: vector<u8>,
    per_tx_cap: u64,
    per_day_cap: u64,
    allowed_packages: vector<address>,
    expires_at_ms: u64,
    spent_today: u64,
    day_window_started_ms: u64,
    revoked: bool,
    paused: bool,
    version: u64,
    // Value-guard params (operator-set; agent cannot supply them). Read by
    // the demo's execute_trade_guarded and passed to
    // receipt::attest_value_conservation. Default 0 until configured via
    // vault::admin_set_value_guard; base_scalar must be > 0 before the
    // guarded path is used.
    max_slippage_bps: u64,
    base_scalar: u64,
}

// === Errors ===

const EPolicyRevoked: u64 = 1;
const EPolicyExpired: u64 = 2;
const EPolicyPaused: u64 = 3;
const ECapExceededPerTx: u64 = 4;
const ECapExceededPerDay: u64 = 5;
const EPackageNotAllowed: u64 = 6;
const EWrongPolicy: u64 = 7;

const MS_PER_DAY: u64 = 86_400_000;

// === Package-visible constructors (called by vault front-door) ===

public(package) fun new(
    agent_id: vector<u8>,
    per_tx_cap: u64,
    per_day_cap: u64,
    allowed_packages: vector<address>,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Policy {
    let now = clock::timestamp_ms(clock);
    Policy {
        id: object::new(ctx),
        agent_id,
        per_tx_cap,
        per_day_cap,
        allowed_packages,
        expires_at_ms,
        spent_today: 0,
        day_window_started_ms: now,
        revoked: false,
        paused: false,
        version: 1,
        max_slippage_bps: 0,
        base_scalar: 0,
    }
}

/// Construct + share a Policy. Returns the policy's ID so the caller
/// (vault::mint_policy) can pass it to mint_agent_cap and to clients.
/// Policy is `key` only — share_object can only be called from within
/// this module.
public(package) fun mint_and_share(
    agent_id: vector<u8>,
    per_tx_cap: u64,
    per_day_cap: u64,
    allowed_packages: vector<address>,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    let p = new(agent_id, per_tx_cap, per_day_cap, allowed_packages, expires_at_ms, clock, ctx);
    let pid = object::id(&p);
    transfer::share_object(p);
    pid
}

public(package) fun set_caps(
    policy: &mut Policy,
    new_per_tx_cap: u64,
    new_per_day_cap: u64,
    clock: &Clock,
) {
    let before = policy.version;
    policy.per_tx_cap = new_per_tx_cap;
    policy.per_day_cap = new_per_day_cap;
    policy.version = before + 1;
    audit::emit_updated(
        policy.agent_id,
        before,
        policy.version,
        clock::timestamp_ms(clock),
    );
}

public(package) fun set_revoked(policy: &mut Policy, clock: &Clock) {
    let before = policy.version;
    policy.revoked = true;
    policy.version = before + 1;
    audit::emit_revoked(
        policy.agent_id,
        policy.version,
        clock::timestamp_ms(clock),
    );
}

public(package) fun set_paused(policy: &mut Policy, paused: bool, clock: &Clock) {
    let before = policy.version;
    policy.paused = paused;
    policy.version = before + 1;
    audit::emit_updated(
        policy.agent_id,
        before,
        policy.version,
        clock::timestamp_ms(clock),
    );
}

/// Operator-set value-guard params. `base_scalar` is the base coin's
/// smallest-unit scalar (1e9 for SUI); `max_slippage_bps` the allowed
/// deviation below DeepBook's fair rate. Set by vault::admin_set_value_guard.
public(package) fun set_value_guard(
    policy: &mut Policy,
    max_slippage_bps: u64,
    base_scalar: u64,
    clock: &Clock,
) {
    let before = policy.version;
    policy.max_slippage_bps = max_slippage_bps;
    policy.base_scalar = base_scalar;
    policy.version = before + 1;
    audit::emit_updated(
        policy.agent_id,
        before,
        policy.version,
        clock::timestamp_ms(clock),
    );
}

// === Enforcement gate ===

/// Aborts on any rule failure; updates spent_today + day window on
/// success; emits AllowedAction on success.
///
/// Denied paths abort — aborts roll back all effects, so the indexer
/// learns of denials from transaction failure metadata, not from an
/// on-chain emit (emitting before abort is rolled back anyway).
public(package) fun check_and_consume(
    policy: &mut Policy,
    cap: &AgentCap,
    amount: u64,
    target_package: address,
    clock: &Clock,
) {
    assert!(agent::policy_id(cap) == object::id(policy), EWrongPolicy);
    assert!(!policy.revoked, EPolicyRevoked);
    assert!(!policy.paused, EPolicyPaused);

    let now = clock::timestamp_ms(clock);
    assert!(now < policy.expires_at_ms, EPolicyExpired);

    assert!(amount <= policy.per_tx_cap, ECapExceededPerTx);
    assert!(policy.allowed_packages.contains(&target_package), EPackageNotAllowed);

    // Roll the daily window if it's been ≥ 24h since it started.
    if (now >= policy.day_window_started_ms + MS_PER_DAY) {
        policy.day_window_started_ms = now;
        policy.spent_today = 0;
    };

    let new_spent = policy.spent_today + amount;
    assert!(new_spent <= policy.per_day_cap, ECapExceededPerDay);
    policy.spent_today = new_spent;

    audit::emit_allowed(
        policy.agent_id,
        policy.version,
        amount,
        target_package,
        now,
    );
}

// === Accessors ===

public fun version(policy: &Policy): u64 { policy.version }
public fun is_revoked(policy: &Policy): bool { policy.revoked }
public fun is_paused(policy: &Policy): bool { policy.paused }
public fun agent_id(policy: &Policy): vector<u8> { policy.agent_id }
public fun per_tx_cap(policy: &Policy): u64 { policy.per_tx_cap }
public fun per_day_cap(policy: &Policy): u64 { policy.per_day_cap }
public fun spent_today(policy: &Policy): u64 { policy.spent_today }
public fun max_slippage_bps(policy: &Policy): u64 { policy.max_slippage_bps }
public fun base_scalar(policy: &Policy): u64 { policy.base_scalar }
