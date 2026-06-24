/// altheia::vault
///
/// Operator-owned MULTI-ASSET vault. Funds are held as `Balance<T>` in dynamic
/// fields keyed by the coin TypeName, so one vault holds many coin types. The
/// only agent exit path is `withdraw_with_receipt<T>`, gated by AgentCap +
/// Policy, which mints a hot-potato `WithdrawalReceipt` that MUST be consumed
/// before the PTB completes. Swap adapters settle their output back INTO the
/// vault (deposit), so an agent can round-trip (buy then sell) while funds stay
/// inside the operator's vault. Caps gate AGENT spend per asset; the OWNER can
/// always drain everything (capped or not) via the admin path.
module altheia::vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use sui::dynamic_field as df;
use std::type_name::{Self, TypeName};
use altheia::policy::{Self, Policy};
use altheia::agent::{Self, AgentCap};
use altheia::receipt::{Self, WithdrawalReceipt};

/// Shared multi-asset vault. Balances live in dynamic fields (TypeName ->
/// Balance<T>); `assets` tracks which types are present so an owner drain can
/// enumerate them off-chain (Move can't iterate df types at runtime).
public struct Vault has key {
    id: UID,
    operator: address,
    assets: vector<TypeName>,
}

/// Operator's master capability. `key + store` so it can move between the
/// operator's wallets / a multisig.
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

// === Errors ===
const EWrongVault: u64 = 1;
const EInsufficientBalance: u64 = 2;

// === Internal balance helpers (dynamic-field keyed by TypeName) ===

fun deposit_balance<T>(vault: &mut Vault, bal: Balance<T>) {
    let tn = type_name::get<T>();
    if (df::exists_(&vault.id, tn)) {
        balance::join(df::borrow_mut<TypeName, Balance<T>>(&mut vault.id, tn), bal);
    } else {
        df::add(&mut vault.id, tn, bal);
        vault.assets.push_back(tn);
    }
}

fun take_balance<T>(vault: &mut Vault, amount: u64): Balance<T> {
    let tn = type_name::get<T>();
    assert!(df::exists_(&vault.id, tn), EInsufficientBalance);
    let b = df::borrow_mut<TypeName, Balance<T>>(&mut vault.id, tn);
    assert!(balance::value(b) >= amount, EInsufficientBalance);
    balance::split(b, amount)
}

/// Guard for every owner-gated policy mutation: the OwnerCap controls this vault
/// AND the policy belongs to this vault. The second check is what stops an
/// operator from touching another vault's policy (cross-vault tampering) — the
/// admin path has no AgentCap to bind vault+policy the way withdraw does.
fun assert_admin(vault: &Vault, owner: &OwnerCap, policy: &Policy) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    assert!(policy::policy_vault_id(policy) == object::id(vault), EWrongVault);
}

// === Provisioning (single-PTB, return-by-value) ===

/// Provision a multi-asset vault, returning it + the OwnerCap by value for
/// one-PTB composition. Caller MUST `share_vault` before the PTB ends.
public fun provision_open(ctx: &mut TxContext): (Vault, OwnerCap) {
    let vault = Vault { id: object::new(ctx), operator: ctx.sender(), assets: vector::empty<TypeName>() };
    let vault_id = object::id(&vault);
    (vault, OwnerCap { id: object::new(ctx), vault_id })
}

/// Entry wrapper: provision + keep the OwnerCap (CLI convenience).
entry fun provision_vault(ctx: &mut TxContext) {
    let (vault, owner) = provision_open(ctx);
    transfer::share_object(vault);
    transfer::public_transfer(owner, ctx.sender());
}

/// Share a by-value Vault (PTB-end step for `provision_open`).
public fun share_vault(vault: Vault) {
    transfer::share_object(vault);
}

/// Deposit any coin. Anyone can deposit; only the gated path withdraws. Records
/// the type in `assets` on first deposit (incl. swap settlements).
public fun deposit<T>(vault: &mut Vault, coin: Coin<T>) {
    deposit_balance(vault, coin.into_balance());
}

/// Mint a policy BY VALUE (unshared), scope+actions+expiry only — per-asset
/// caps are added with `add_asset_cap<T>`. Caller shares via `policy::share`.
public fun mint_policy_open(
    vault: &Vault,
    owner: &OwnerCap,
    agent_id: vector<u8>,
    allowed_packages: vector<address>,
    allowed_actions: vector<u8>,
    expires_at_ms: u64,
    ctx: &mut TxContext,
): Policy {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::new(object::id(vault), agent_id, allowed_packages, allowed_actions, expires_at_ms, ctx)
}

/// Owner adds/replaces the per-asset cap for `T` on a policy.
public fun add_asset_cap<T>(
    vault: &Vault,
    owner: &OwnerCap,
    policy: &mut Policy,
    per_tx_cap: u64,
    per_day_cap: u64,
    clock: &Clock,
) {
    assert_admin(vault, owner, policy);
    policy::add_asset_cap<T>(policy, per_tx_cap, per_day_cap, clock);
}

/// Mint an AgentCap from a by-value Policy (reads its id), for single-PTB use.
public fun mint_agent_cap_for(
    vault: &Vault,
    owner: &OwnerCap,
    policy: &Policy,
    agent_id: vector<u8>,
    agent_addr: address,
    ctx: &mut TxContext,
) {
    assert_admin(vault, owner, policy);
    agent::mint_and_transfer(agent_id, object::id(vault), object::id(policy), agent_addr, ctx);
}

// === Admin (owner-gated policy mutations) ===

public fun admin_revoke_policy(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_revoked(policy, clock);
}

public fun admin_pause_policy(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_paused(policy, true, clock);
}

public fun admin_unpause_policy(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_paused(policy, false, clock);
}

public fun admin_set_actions(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, allowed_actions: vector<u8>, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_allowed_actions(policy, allowed_actions, clock);
}

public fun admin_set_action_params(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, action: u8, params: vector<u64>, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_action_params(policy, action, params, clock);
}

public fun admin_set_value_guard(vault: &Vault, owner: &OwnerCap, policy: &mut Policy, max_slippage_bps: u64, base_scalar: u64, clock: &Clock) {
    assert_admin(vault, owner, policy);
    policy::set_value_guard(policy, max_slippage_bps, base_scalar, clock);
}

// === Withdraw (the agent gate) ===

/// Withdraw `amount` of T for the agent. Returns (Coin<T>, WithdrawalReceipt) —
/// a hot potato that MUST be consumed (re-vaulted by a swap adapter, or sent to
/// a destination by a capped transfer) before the PTB ends. `check_and_consume`
/// enforces caps for budget assets and allows uncapped position assets to be
/// unwound (proceeds re-vault).
public fun withdraw_with_receipt<T>(
    vault: &mut Vault,
    cap: &AgentCap,
    policy: &mut Policy,
    amount: u64,
    target_package: address,
    recipient: address,
    asset_tag: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<T>, WithdrawalReceipt) {
    assert!(agent::vault_id(cap) == object::id(vault), EWrongVault);
    policy::check_and_consume<T>(policy, cap, amount, target_package, clock);
    let c = coin::from_balance(take_balance<T>(vault, amount), ctx);
    let r = receipt::new(
        agent::agent_id(cap),
        amount,
        asset_tag,
        recipient,
        policy::version(policy),
        clock.timestamp_ms(),
    );
    (c, r)
}

// === Owner drain (kill-switch exit) — owner-gated, NOT cap-gated ===

/// Owner-only full drain of asset `T` (down to the last unit) for PTB
/// composition. Caps never restrict the owner. To drain a multi-asset vault,
/// the owner calls this once per type in `assets(vault)`, batched in one PTB.
public fun admin_withdraw_all<T>(vault: &mut Vault, owner: &OwnerCap, ctx: &mut TxContext): Coin<T> {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    let amount = balance<T>(vault);
    coin::from_balance(take_balance<T>(vault, amount), ctx)
}

/// Owner-only partial withdrawal of asset `T`.
public fun admin_withdraw<T>(vault: &mut Vault, owner: &OwnerCap, amount: u64, ctx: &mut TxContext): Coin<T> {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    coin::from_balance(take_balance<T>(vault, amount), ctx)
}

/// Entry wrapper: drain one asset to the owner's wallet in a single call.
entry fun admin_withdraw_all_to_owner<T>(vault: &mut Vault, owner: &OwnerCap, ctx: &mut TxContext) {
    transfer::public_transfer(admin_withdraw_all<T>(vault, owner, ctx), ctx.sender());
}

// === Accessors ===

public fun balance<T>(vault: &Vault): u64 {
    let tn = type_name::get<T>();
    if (df::exists_(&vault.id, tn)) balance::value(df::borrow<TypeName, Balance<T>>(&vault.id, tn)) else 0
}

/// The set of coin types the vault holds (or has held) — drives the owner's
/// per-asset drain PTB.
public fun assets(vault: &Vault): vector<TypeName> { vault.assets }

public fun operator(vault: &Vault): address { vault.operator }

public fun vault_id(vault: &Vault): ID { object::id(vault) }

public fun owner_vault_id(cap: &OwnerCap): ID { cap.vault_id }
