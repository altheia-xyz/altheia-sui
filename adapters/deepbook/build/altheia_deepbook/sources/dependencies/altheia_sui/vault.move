/// altheia::vault
///
/// Operator-owned vault holding agent-spendable funds as `Balance<T>`
/// (store-only inside the vault — the Balance itself can never escape
/// as a top-level object). The ONLY exit path is `withdraw_with_receipt`,
/// which gates by AgentCap + Policy and mints a hot-potato
/// `WithdrawalReceipt` that MUST be consumed before the PTB completes.
///
/// Front-door module: provision, deposit, mint policy + agent caps, admin
/// operations, withdraw. Funds are held as `Balance<T>` (not transferable
/// `Coin<T>`) and can only leave through `withdraw_with_receipt`, so the
/// agent never holds spendable funds without an accompanying unconsumed
/// receipt.
module altheia::vault;

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::clock::Clock;
use altheia::policy::{Self, Policy};
use altheia::agent::{Self, AgentCap};
use altheia::receipt::{Self, WithdrawalReceipt};

/// Shared vault per (operator, asset T). Balance<T> has no `key` and no
/// `drop` — it can only live inside this struct.
public struct Vault<phantom T> has key {
    id: UID,
    balance: Balance<T>,
    operator: address,
}

/// Operator's master capability. `key + store` so the operator can move
/// it between their own wallets, hold it in a multisig, etc.
public struct OwnerCap has key, store {
    id: UID,
    vault_id: ID,
}

// === Errors ===
const EWrongVault: u64 = 1;
const EInsufficientBalance: u64 = 2;
// Note: EWrongPolicyForVault is asserted inside policy::check_and_consume
// (which checks cap.policy_id == id(policy)); no separate vault-side check.

// === Provisioning ===

/// Create an empty Vault<T> + return OwnerCap. Vault is shared.
/// Returns OwnerCap for PTB composition. CLI/operators use
/// `provision_vault` (entry wrapper below) since `sui client call`
/// cannot handle a non-droppable return value.
public fun provision<T>(ctx: &mut TxContext): OwnerCap {
    let vault = Vault<T> {
        id: object::new(ctx),
        balance: balance::zero<T>(),
        operator: ctx.sender(),
    };
    let vault_id = object::id(&vault);
    transfer::share_object(vault);
    OwnerCap {
        id: object::new(ctx),
        vault_id,
    }
}

/// Entry wrapper: provision a vault and keep the OwnerCap. Operator-facing
/// (plain `sui client call`), no PTB needed.
entry fun provision_vault<T>(ctx: &mut TxContext) {
    let owner = provision<T>(ctx);
    transfer::public_transfer(owner, ctx.sender());
}

/// Deposit a Coin into the vault. Anyone can deposit (adding funds is
/// harmless; only the operator-gated path can withdraw).
public fun deposit<T>(vault: &mut Vault<T>, coin: Coin<T>) {
    balance::join(&mut vault.balance, coin.into_balance());
}

/// Operator mints a new policy for an agent. Policy is shared.
/// Returns the policy ID so the operator can hand it to the agent
/// alongside the AgentCap.
public fun mint_policy<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    agent_id: vector<u8>,
    per_tx_cap: u64,
    per_day_cap: u64,
    allowed_packages: vector<address>,
    allowed_actions: vector<u8>,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): ID {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::mint_and_share(
        agent_id,
        per_tx_cap,
        per_day_cap,
        allowed_packages,
        allowed_actions,
        expires_at_ms,
        clock,
        ctx,
    )
}

/// Operator mints an AgentCap for `agent_addr`. The cap is `key`-only,
/// so the agent cannot transfer it away.
public fun mint_agent_cap<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy_id: ID,
    agent_id: vector<u8>,
    agent_addr: address,
    ctx: &mut TxContext,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    agent::mint_and_transfer(
        agent_id,
        object::id(vault),
        policy_id,
        agent_addr,
        ctx,
    );
}

// === Admin (owner-gated policy mutations) ===

public fun admin_update_policy_caps<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    new_per_tx_cap: u64,
    new_per_day_cap: u64,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_caps(policy, new_per_tx_cap, new_per_day_cap, clock);
}

public fun admin_revoke_policy<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_revoked(policy, clock);
}

public fun admin_pause_policy<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_paused(policy, true, clock);
}

public fun admin_unpause_policy<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_paused(policy, false, clock);
}

/// Operator updates the agent's capability allowlist (altheia::actions ids).
public fun admin_set_actions<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    allowed_actions: vector<u8>,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_allowed_actions(policy, allowed_actions, clock);
}

/// Operator sets per-action config params (e.g. limit-order price band + size).
/// Agent-callable paths read these from the Policy; the agent cannot set them.
public fun admin_set_action_params<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    action: u8,
    params: vector<u64>,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_action_params(policy, action, params, clock);
}

/// Operator configures the value-guard bound for swaps. Agent-callable
/// paths read these from the Policy; the agent cannot set them.
public fun admin_set_value_guard<T>(
    vault: &Vault<T>,
    owner: &OwnerCap,
    policy: &mut Policy,
    max_slippage_bps: u64,
    base_scalar: u64,
    clock: &Clock,
) {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    policy::set_value_guard(policy, max_slippage_bps, base_scalar, clock);
}

// === Withdraw (the gate) ===

/// Withdraw `amount` of T from the vault for the agent's use. Returns
/// (Coin<T>, WithdrawalReceipt). The receipt is a hot potato that MUST
/// be consumed via `altheia::receipt::attest_*` before the PTB ends,
/// else the entire PTB aborts and the Coin never materializes.
///
/// Authorization chain:
///   1. cap.vault_id == object::id(vault)   else EWrongVault
///   2. policy::check_and_consume (also checks cap.policy_id, caps,
///      scope, revoked, paused, expiry; updates spent_today)
///   3. vault.balance >= amount             else EInsufficientBalance
public fun withdraw_with_receipt<T>(
    vault: &mut Vault<T>,
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
    // check_and_consume verifies cap.policy_id == id(policy) internally.
    policy::check_and_consume(policy, cap, amount, target_package, clock);
    assert!(balance::value(&vault.balance) >= amount, EInsufficientBalance);

    let b = balance::split(&mut vault.balance, amount);
    let c = coin::from_balance(b, ctx);
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

// === Owner drain (kill-switch exit) ===

/// Owner-only withdrawal of `amount` from the vault. The kill-switch path:
/// after revoking the policy, the owner drains the vault back to their wallet.
/// Authorized by OwnerCap, not the agent — the agent can never call this.
public fun admin_withdraw<T>(
    vault: &mut Vault<T>,
    owner: &OwnerCap,
    amount: u64,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    assert!(balance::value(&vault.balance) >= amount, EInsufficientBalance);
    coin::from_balance(balance::split(&mut vault.balance, amount), ctx)
}

/// Owner-only full drain (down to the last unit). Returns the whole balance
/// as a Coin for PTB composition (sweep to the owner wallet).
public fun admin_withdraw_all<T>(
    vault: &mut Vault<T>,
    owner: &OwnerCap,
    ctx: &mut TxContext,
): Coin<T> {
    assert!(owner.vault_id == object::id(vault), EWrongVault);
    let amount = balance::value(&vault.balance);
    coin::from_balance(balance::split(&mut vault.balance, amount), ctx)
}

/// Entry wrapper: drain the whole vault to the owner's wallet in one call.
entry fun admin_withdraw_all_to_owner<T>(
    vault: &mut Vault<T>,
    owner: &OwnerCap,
    ctx: &mut TxContext,
) {
    let c = admin_withdraw_all<T>(vault, owner, ctx);
    transfer::public_transfer(c, ctx.sender());
}

// === Accessors ===

public fun balance<T>(vault: &Vault<T>): u64 {
    balance::value(&vault.balance)
}

public fun operator<T>(vault: &Vault<T>): address {
    vault.operator
}

public fun vault_id<T>(vault: &Vault<T>): ID {
    object::id(vault)
}

public fun owner_vault_id(cap: &OwnerCap): ID {
    cap.vault_id
}
