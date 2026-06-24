/// altheia::policy
///
/// Per-agent policy as a SHARED object. Holds PER-ASSET caps + scope +
/// cumulative spend state. Because Policy is shared, cumulative daily spend
/// persists across transactions, so caps cannot be bypassed by splitting a
/// spend across multiple PTBs.
///
/// Multi-asset model: an agent's vault holds many coin types; the policy
/// carries one `AssetCap` per type (keyed by TypeName). `check_and_consume<T>`
/// is the enforcement gate, called by vault::withdraw_with_receipt<T> before
/// any Coin<T> leaves the vault. An asset with no cap entry is default-deny.
module altheia::policy;

use sui::clock::{Self, Clock};
use sui::vec_set::{Self, VecSet};
use sui::vec_map::{Self, VecMap};
use sui::dynamic_field as df;
use std::type_name::{Self, TypeName};
use altheia::agent::{Self, AgentCap};
use altheia::audit;

/// Per-asset spend cap + rolling-day state.
public struct AssetCap has store, copy, drop {
    per_tx_cap: u64,
    per_day_cap: u64,
    spent_today: u64,
    day_window_started_ms: u64,
}

/// Per-agent policy object. Shared at mint via vault::mint_policy*.
public struct Policy has key {
    id: UID,
    // The vault this policy governs. Bound at mint; every owner-gated mutation
    // asserts the policy belongs to the vault, so an operator cannot touch
    // another vault's policy (cross-vault tampering).
    vault_id: ID,
    agent_id: vector<u8>,
    // Per-asset caps keyed by coin TypeName. An asset absent here is denied.
    caps: VecMap<TypeName, AssetCap>,
    allowed_packages: vector<address>,
    // Capability allowlist (altheia::actions ids). Default-deny.
    allowed_actions: VecSet<u8>,
    expires_at_ms: u64,
    revoked: bool,
    paused: bool,
    version: u64,
    // Value-guard params (operator-set; agent cannot supply them).
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
const ENotAllowedAction: u64 = 8;
const EActionConfigMissing: u64 = 9;
const EAssetNotAllowed: u64 = 10;
const EInvalidValueGuard: u64 = 11;

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
        caps: vec_map::empty<TypeName, AssetCap>(),
        allowed_packages,
        allowed_actions: actions_set(allowed_actions),
        expires_at_ms,
        revoked: false,
        paused: false,
        version: 1,
        max_slippage_bps: 0,
        base_scalar: 0,
    }
}

/// Add or replace the cap for asset `T`. Owner-gated via the vault front-door.
public(package) fun add_asset_cap<T>(
    policy: &mut Policy,
    per_tx_cap: u64,
    per_day_cap: u64,
    clock: &Clock,
) {
    let tn = type_name::get<T>();
    let now = clock::timestamp_ms(clock);
    // Preserve cumulative spend + window on re-set: re-issuing a cap mid-day
    // must not reset the daily budget (else a compromised operator key could
    // wipe spent_today at will). A new asset starts fresh at `now`.
    let (spent_today, day_window_started_ms) = if (policy.caps.contains(&tn)) {
        let (_, old) = policy.caps.remove(&tn);
        (old.spent_today, old.day_window_started_ms)
    } else {
        (0, now)
    };
    policy.caps.insert(tn, AssetCap {
        per_tx_cap,
        per_day_cap,
        spent_today,
        day_window_started_ms,
    });
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

/// Operator-set value-guard params (per swap value conservation).
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
    let before = policy.version;
    policy.max_slippage_bps = max_slippage_bps;
    policy.base_scalar = base_scalar;
    policy.version = before + 1;
    let now = clock::timestamp_ms(clock);
    audit::emit_changed(policy.agent_id, audit::kind_value_guard(), before, policy.version, now);
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
///     to be sold/swapped back without a cap, because swap proceeds settle into
///     the vault (the receipt guarantees re-vaulting) and selling reduces risk.
/// Exfiltration (transfer OUT) is gated separately by `assert_transferable<T>`,
/// so a position asset can be unwound but never transferred straight out.
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

    let tn = type_name::get<T>();
    if (policy.caps.contains(&tn)) {
        // budget asset: enforce caps + record the spend
        let c = policy.caps.get_mut(&tn);
        if (c.per_tx_cap > 0) assert!(amount <= c.per_tx_cap, ECapExceededPerTx);
        if (now >= c.day_window_started_ms + MS_PER_DAY) {
            c.day_window_started_ms = now;
            c.spent_today = 0;
        };
        // Checked: with per_tx_cap == 0 the amount is otherwise unbounded, so a
        // near-u64::MAX amount would overflow `spent_today + amount` and abort
        // with a raw arithmetic error instead of the clean cap error. The
        // invariant spent_today <= per_day_cap keeps the subtraction safe.
        assert!(amount <= c.per_day_cap - c.spent_today, ECapExceededPerDay);
        c.spent_today = c.spent_today + amount;
    };
    // uncapped: position unwind — allowed, no accounting (proceeds re-vault).

    audit::emit_allowed(policy.agent_id, policy.version, amount, target_package, now);
}

/// Exfiltration gate: an asset may only be transferred OUT of the vault if the
/// operator gave it a cap. Position assets (uncapped) can be sold back but never
/// transferred to an external address. The transfer action path calls this.
public fun assert_transferable<T>(policy: &Policy) {
    assert!(policy.caps.contains(&type_name::get<T>()), EAssetNotAllowed);
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
public fun max_slippage_bps(policy: &Policy): u64 { policy.max_slippage_bps }
public fun base_scalar(policy: &Policy): u64 { policy.base_scalar }

/// Does the policy carry a cap for asset `T`?
public fun has_asset_cap<T>(policy: &Policy): bool {
    policy.caps.contains(&type_name::get<T>())
}

public fun per_tx_cap<T>(policy: &Policy): u64 {
    let tn = type_name::get<T>();
    if (policy.caps.contains(&tn)) policy.caps.get(&tn).per_tx_cap else 0
}

public fun per_day_cap<T>(policy: &Policy): u64 {
    let tn = type_name::get<T>();
    if (policy.caps.contains(&tn)) policy.caps.get(&tn).per_day_cap else 0
}

public fun spent_today<T>(policy: &Policy): u64 {
    let tn = type_name::get<T>();
    if (policy.caps.contains(&tn)) policy.caps.get(&tn).spent_today else 0
}

/// Number of distinct assets with caps.
public fun asset_count(policy: &Policy): u64 {
    policy.caps.size()
}
