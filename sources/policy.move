/// altheia::policy
///
/// Per-agent policy as a SHARED object. The core struct holds only venue-agnostic
/// INVARIANTS (identity, vault binding, lifecycle, scope, version). All
/// adapter-specific bounds live in DYNAMIC-FIELD policy modules built from the
/// generic `policy_module` primitives — so new adapters plug in without ever
/// changing this struct. See altheia-plan/01_PHASES/sui/POLICY_MODULE_DESIGN.md.
///
/// Spend caps are the first module: one `SpendModule` per capped asset (keyed by
/// TypeName), a per-tx ceiling + a FLOW `BoundedCounter` for the rolling-day cap.
/// Because Policy is shared, cumulative daily spend persists across transactions,
/// so caps can't be bypassed by splitting a spend across PTBs. An asset with no
/// SpendModule is uncapped (a position that may be unwound, never transferred out).
/// `check_and_consume<T>` is the enforcement gate, called by
/// vault::withdraw_with_receipt<T> before any Coin<T> leaves the vault.
module altheia::policy;

use sui::clock::{Self, Clock};
use sui::vec_set::{Self, VecSet};
use sui::dynamic_field as df;
use std::type_name::{Self, TypeName};
use altheia::agent::{Self, AgentCap};
use altheia::audit;
use altheia::policy_module::{Self as pm, BoundedCounter};

// === Policy modules (dynamic-field bounds; keyed off the core struct) ===

/// Per-asset spend bound: per-tx ceiling (0 = no per-tx limit) + a FLOW counter
/// for the rolling-day cap.
public struct SpendModule has store, drop {
    per_tx: u64,
    day: BoundedCounter,
}
public struct SpendKey has copy, drop, store { asset: TypeName }

/// Operator-set value-guard params (per swap value conservation).
public struct ValueGuard has store, drop {
    max_slippage_bps: u64,
    base_scalar: u64,
}
public struct ValueGuardKey has copy, drop, store {}

/// Per-asset debt bound: a STOCK counter (borrow ↑ / repay ↓ against a ceiling).
/// Self-contained — Scallop's own oracle-based health factor / liquidation is
/// separate and enforced by Scallop; this is altheia's hard borrow ceiling.
public struct DebtModule has store, drop { ceiling: BoundedCounter }
public struct DebtKey has copy, drop, store { asset: TypeName }

/// Per-agent policy object. Shared at mint via vault::mint_policy*.
public struct Policy has key {
    id: UID,
    // The vault this policy governs. Bound at mint; every owner-gated mutation
    // asserts the policy belongs to the vault (cross-vault tampering).
    vault_id: ID,
    agent_id: vector<u8>,
    allowed_packages: vector<address>,
    // Capability allowlist (altheia::actions ids). Default-deny.
    allowed_actions: VecSet<u8>,
    expires_at_ms: u64,
    revoked: bool,
    paused: bool,
    version: u64,
}

// === Errors ===

const EPolicyRevoked: u64 = 1;
const EPolicyExpired: u64 = 2;
const EPolicyPaused: u64 = 3;
const ECapExceededPerTx: u64 = 4;
const ECapExceededPerDay: u64 = 5;
const EPackageNotAllowed: u64 = 6;
const EWrongPolicy: u64 = 7;
const ENotAllowedAction: u64 = 8;
const EActionConfigMissing: u64 = 9;
const EAssetNotAllowed: u64 = 10;
const EInvalidValueGuard: u64 = 11;
const EBorrowNotAllowed: u64 = 12;
const EBorrowCapExceeded: u64 = 13;

const MS_PER_DAY: u64 = 86_400_000;
const BPS_DENOM: u64 = 10_000;

/// Build a VecSet from a vector of action ids (dedupes).
fun actions_set(ids: vector<u8>): VecSet<u8> {
    let mut set = vec_set::empty<u8>();
    let mut i = 0;
    let n = ids.length();
    while (i < n) {
        let id = ids[i];
        if (!set.contains(&id)) set.insert(id);
        i = i + 1;
    };
    set
}

// === Package-visible constructors (called by vault front-door) ===

/// New policy with NO asset caps yet — add them with `add_asset_cap<T>`.
public(package) fun new(
    vault_id: ID,
    agent_id: vector<u8>,
    allowed_packages: vector<address>,
    allowed_actions: vector<u8>,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): Policy {
    Policy {
        id: object::new(ctx),
        vault_id,
        agent_id,
        allowed_packages,
        allowed_actions: actions_set(allowed_actions),
        expires_at_ms,
        revoked: false,
        paused: false,
        version: 1,
    }
}

/// Add or replace the spend cap for asset `T`. Owner-gated via the vault
/// front-door. Re-setting preserves the accumulated day counter (current +
/// window) — re-issuing a cap mid-day must not reset the daily budget.
public(package) fun add_asset_cap<T>(
    policy: &mut Policy,
    per_tx_cap: u64,
    per_day_cap: u64,
    clock: &Clock,
) {
    let key = SpendKey { asset: type_name::get<T>() };
    let now = clock::timestamp_ms(clock);
    let day = if (df::exists_(&policy.id, key)) {
        let old: SpendModule = df::remove(&mut policy.id, key);
        pm::preserve(&old.day, per_day_cap) // old drops (has drop)
    } else {
        pm::new_flow(per_day_cap, MS_PER_DAY, now)
    };
    df::add(&mut policy.id, key, SpendModule { per_tx: per_tx_cap, day });
    let before = policy.version;
    policy.version = before + 1;
    audit::emit_changed(policy.agent_id, audit::kind_cap(), before, policy.version, now);
}

/// Share a by-value Policy (PTB-end step for `vault::mint_policy_*`). Policy is
/// `key`-only, so sharing must originate here in its defining module.
public fun share(p: Policy) {
    transfer::share_object(p);
}

public(package) fun set_revoked(policy: &mut Policy, clock: &Clock) {
    let before = policy.version;
    policy.revoked = true;
    policy.version = before + 1;
    audit::emit_revoked(policy.agent_id, policy.version, clock::timestamp_ms(clock));
}

public(package) fun set_paused(policy: &mut Policy, paused: bool, clock: &Clock) {
    let before = policy.version;
    policy.paused = paused;
    policy.version = before + 1;
    let now = clock::timestamp_ms(clock);
    let kind = if (paused) audit::kind_pause() else audit::kind_unpause();
    audit::emit_changed(policy.agent_id, kind, before, policy.version, now);
}

/// Operator-set value-guard params (per swap value conservation). Stored as a
/// dynamic-field module, not a core struct field.
public(package) fun set_value_guard(
    policy: &mut Policy,
    max_slippage_bps: u64,
    base_scalar: u64,
    clock: &Clock,
) {
    // Slippage is a fraction of BPS_DENOM (>100% is meaningless); base_scalar is
    // a divisor in the floor math, so zero would divide-by-zero.
    assert!(max_slippage_bps <= BPS_DENOM, EInvalidValueGuard);
    assert!(base_scalar > 0, EInvalidValueGuard);
    if (df::exists_(&policy.id, ValueGuardKey {})) {
        let _: ValueGuard = df::remove(&mut policy.id, ValueGuardKey {});
    };
    df::add(&mut policy.id, ValueGuardKey {}, ValueGuard { max_slippage_bps, base_scalar });
    let before = policy.version;
    policy.version = before + 1;
    audit::emit_changed(policy.agent_id, audit::kind_value_guard(), before, policy.version, clock::timestamp_ms(clock));
}

// === Liveness gate (for actions that don't move Vault funds) ===

/// Assert the agent's policy is live: correct policy, not revoked/paused/expired.
public fun assert_active(policy: &Policy, cap: &AgentCap, clock: &Clock) {
    assert!(agent::policy_id(cap) == object::id(policy), EWrongPolicy);
    assert!(!policy.revoked, EPolicyRevoked);
    assert!(!policy.paused, EPolicyPaused);
    assert!(clock::timestamp_ms(clock) < policy.expires_at_ms, EPolicyExpired);
}

// === Enforcement gate ===

/// Enforce + consume against asset `T`. Caps govern BUDGET DEPLOYMENT, not what
/// the vault may hold:
///   - Capped (budget) asset → enforce per_tx/per_day + record the spend.
///   - Uncapped asset → a POSITION acquired via a prior permitted swap; allowed
///     to be sold/swapped back without a cap (proceeds re-vault, selling reduces
///     risk). Exfiltration OUT is gated separately by `assert_transferable<T>`.
public(package) fun check_and_consume<T>(
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
    assert!(policy.allowed_packages.contains(&target_package), EPackageNotAllowed);

    let key = SpendKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) {
        // budget asset: enforce caps + record the spend
        let sm = df::borrow_mut<SpendKey, SpendModule>(&mut policy.id, key);
        if (sm.per_tx > 0) assert!(amount <= sm.per_tx, ECapExceededPerTx);
        // per-day via the FLOW counter, but keep the distinct per-day abort code:
        // would_exceed does the window-roll math without mutating.
        assert!(!pm::would_exceed(&sm.day, amount, now), ECapExceededPerDay);
        pm::consume(&mut sm.day, amount, now);
    };
    // uncapped: position unwind — allowed, no accounting (proceeds re-vault).

    audit::emit_allowed(policy.agent_id, policy.version, amount, target_package, now);
}

/// Exfiltration gate: an asset may only be transferred OUT of the vault if the
/// operator gave it a spend cap. Position assets (uncapped) can be sold back but
/// never transferred to an external address. The transfer action path calls this.
public fun assert_transferable<T>(policy: &Policy) {
    assert!(df::exists_(&policy.id, SpendKey { asset: type_name::get<T>() }), EAssetNotAllowed);
}

// === Debt module (lending) — the STOCK case, first consumer of the base ===

/// Set/replace the borrow ceiling for asset `T` (owner-gated via vault). STOCK
/// counter — re-setting preserves outstanding borrowed (can't wipe debt by
/// re-issuing the cap). ceiling 0 = borrowing this asset is disabled.
public(package) fun set_debt_cap<T>(policy: &mut Policy, ceiling: u64, clock: &Clock) {
    let key = DebtKey { asset: type_name::get<T>() };
    let bc = if (df::exists_(&policy.id, key)) {
        let old: DebtModule = df::remove(&mut policy.id, key);
        pm::preserve(&old.ceiling, ceiling)
    } else {
        pm::new_stock(ceiling)
    };
    df::add(&mut policy.id, key, DebtModule { ceiling: bc });
    let before = policy.version;
    policy.version = before + 1;
    audit::emit_changed(policy.agent_id, audit::kind_cap(), before, policy.version, clock::timestamp_ms(clock));
}

/// Enforce + record a borrow of `amount` of `T`: liveness + the debt ceiling.
/// Default-deny — an asset with no debt module cannot be borrowed.
public(package) fun consume_debt<T>(
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
    let key = DebtKey { asset: type_name::get<T>() };
    assert!(df::exists_(&policy.id, key), EBorrowNotAllowed);
    let dm = df::borrow_mut<DebtKey, DebtModule>(&mut policy.id, key);
    assert!(!pm::would_exceed(&dm.ceiling, amount, now), EBorrowCapExceeded);
    pm::consume(&mut dm.ceiling, amount, now);
    audit::emit_allowed(policy.agent_id, policy.version, amount, target_package, now);
}

/// Release `amount` of outstanding debt for `T` (repay). Saturating.
public(package) fun release_debt<T>(policy: &mut Policy, amount: u64) {
    let key = DebtKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) {
        let dm = df::borrow_mut<DebtKey, DebtModule>(&mut policy.id, key);
        pm::release(&mut dm.ceiling, amount);
    };
}

public fun has_debt_cap<T>(policy: &Policy): bool {
    df::exists_(&policy.id, DebtKey { asset: type_name::get<T>() })
}
public fun borrow_cap<T>(policy: &Policy): u64 {
    let key = DebtKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) { let dm = df::borrow<DebtKey, DebtModule>(&policy.id, key); pm::limit(&dm.ceiling) } else 0
}
public fun borrowed<T>(policy: &Policy): u64 {
    let key = DebtKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) { let dm = df::borrow<DebtKey, DebtModule>(&policy.id, key); pm::current(&dm.ceiling) } else 0
}

/// Replace the capability allowlist (owner-gated via vault::admin_set_actions).
public(package) fun set_allowed_actions(policy: &mut Policy, ids: vector<u8>, clock: &Clock) {
    let before = policy.version;
    policy.allowed_actions = actions_set(ids);
    policy.version = before + 1;
    let now = clock::timestamp_ms(clock);
    audit::emit_changed(policy.agent_id, audit::kind_actions(), before, policy.version, now);
}

// === Per-action config (dynamic fields, operator-set) ===

public(package) fun set_action_params(policy: &mut Policy, action: u8, params: vector<u64>, clock: &Clock) {
    if (df::exists_(&policy.id, action)) {
        let _: vector<u64> = df::remove(&mut policy.id, action);
    };
    df::add(&mut policy.id, action, params);
    let before = policy.version;
    policy.version = before + 1;
    audit::emit_changed(policy.agent_id, audit::kind_action_params(), before, policy.version, clock::timestamp_ms(clock));
}

public fun action_params(policy: &Policy, action: u8): vector<u64> {
    assert!(df::exists_(&policy.id, action), EActionConfigMissing);
    *df::borrow<u8, vector<u64>>(&policy.id, action)
}

public fun has_action_params(policy: &Policy, action: u8): bool {
    df::exists_(&policy.id, action)
}

// === Action allowlist (default-deny) ===

public fun allows(policy: &Policy, action: u8): bool {
    policy.allowed_actions.contains(&action)
}

public fun assert_allows(policy: &Policy, action: u8) {
    assert!(policy.allowed_actions.contains(&action), ENotAllowedAction);
}

// === Accessors ===

public fun version(policy: &Policy): u64 { policy.version }
public fun policy_vault_id(policy: &Policy): ID { policy.vault_id }
public fun is_revoked(policy: &Policy): bool { policy.revoked }
public fun is_paused(policy: &Policy): bool { policy.paused }
public fun agent_id(policy: &Policy): vector<u8> { policy.agent_id }

public fun max_slippage_bps(policy: &Policy): u64 {
    if (df::exists_(&policy.id, ValueGuardKey {})) {
        df::borrow<ValueGuardKey, ValueGuard>(&policy.id, ValueGuardKey {}).max_slippage_bps
    } else 0
}
public fun base_scalar(policy: &Policy): u64 {
    if (df::exists_(&policy.id, ValueGuardKey {})) {
        df::borrow<ValueGuardKey, ValueGuard>(&policy.id, ValueGuardKey {}).base_scalar
    } else 0
}

/// Does the policy carry a spend cap for asset `T`?
public fun has_asset_cap<T>(policy: &Policy): bool {
    df::exists_(&policy.id, SpendKey { asset: type_name::get<T>() })
}

public fun per_tx_cap<T>(policy: &Policy): u64 {
    let key = SpendKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) df::borrow<SpendKey, SpendModule>(&policy.id, key).per_tx else 0
}

public fun per_day_cap<T>(policy: &Policy): u64 {
    let key = SpendKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) {
        let sm = df::borrow<SpendKey, SpendModule>(&policy.id, key);
        pm::limit(&sm.day)
    } else 0
}

public fun spent_today<T>(policy: &Policy): u64 {
    let key = SpendKey { asset: type_name::get<T>() };
    if (df::exists_(&policy.id, key)) {
        let sm = df::borrow<SpendKey, SpendModule>(&policy.id, key);
        pm::current(&sm.day)
    } else 0
}
