#[test_only]
module altheia::vault_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault, OwnerCap};
use altheia::policy::{Self, Policy};
use altheia::agent::AgentCap;
use altheia::receipt;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const POOL: address = @0x90;

// Two distinct coin types for the multi-asset cases. USDC is a budget asset
// (capped); DEEP stands in for an asset acquired via a swap (uncapped).
public struct USDC has drop {}
public struct DEEP has drop {}

const SWAP: u8 = 1; // deepbook_swap action id (mirrors altheia::actions)

/// Provision a multi-asset vault funded with USDC + DEEP, a policy that caps
/// USDC only and allows the swap action on POOL, and an AgentCap for AGENT.
/// Vault + policy are shared; OwnerCap goes to OPERATOR.
fun setup(s: &mut ts::Scenario, clk: &clock::Clock, usdc_amt: u64, deep_amt: u64, per_tx: u64, per_day: u64) {
    let (mut vault, owner) = vault::provision_open(ts::ctx(s));
    vault::admin_deposit<USDC>(&mut vault, &owner, coin::mint_for_testing<USDC>(usdc_amt, ts::ctx(s)));
    vault::admin_deposit<DEEP>(&mut vault, &owner, coin::mint_for_testing<DEEP>(deep_amt, ts::ctx(s)));
    let mut policy = vault::mint_policy_open(&vault, &owner, b"agent-1", vector[POOL], vector[SWAP], 9_999_999_999_999, ts::ctx(s));
    vault::add_asset_cap<USDC>(&vault, &owner, &mut policy, per_tx, per_day, clk);
    vault::mint_agent_cap_for(&vault, &owner, &policy, b"agent-1", AGENT, ts::ctx(s));
    vault::share_vault(vault);
    policy::share(policy);
    transfer::public_transfer(owner, OPERATOR);
}

// 1. Multi-asset provisioning: one vault holds two coin types; the policy caps
//    only the budget asset; the asset list records both.
#[test]
fun test_multi_asset_provision() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 500, 100, 1_000);
    ts::next_tx(&mut s, OPERATOR);
    let v = ts::take_shared<Vault>(&s);
    let p = ts::take_shared<Policy>(&s);
    assert!(vault::balance<USDC>(&v) == 1_000, 0);
    assert!(vault::balance<DEEP>(&v) == 500, 1);
    assert!(vault::assets(&v).length() == 2, 2);
    assert!(policy::has_asset_cap<USDC>(&p), 3);
    assert!(!policy::has_asset_cap<DEEP>(&p), 4); // DEEP uncapped
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 2. Budget asset within cap: withdraw succeeds and records spend.
#[test]
fun test_withdraw_budget_asset_within_cap() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 0, 100, 1_000);
    ts::next_tx(&mut s, AGENT);
    let mut v = ts::take_shared<Vault>(&s);
    let mut p = ts::take_shared<Policy>(&s);
    let cap = ts::take_from_sender<AgentCap>(&s);
    let (coin_out, receipt) = vault::withdraw_with_receipt<USDC>(&mut v, &cap, &mut p, 80, POOL, OPERATOR, b"USDC", &clk, ts::ctx(&mut s));
    assert!(coin::value(&coin_out) == 80, 0);
    assert!(policy::spent_today<USDC>(&p) == 80, 1);
    test_utils::destroy(coin_out);
    receipt::destroy_for_testing(receipt);
    ts::return_to_sender(&s, cap);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 3. Budget asset over per-tx cap aborts.
#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerTx)]
fun test_withdraw_over_per_tx_aborts() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 0, 100, 1_000);
    ts::next_tx(&mut s, AGENT);
    let mut v = ts::take_shared<Vault>(&s);
    let mut p = ts::take_shared<Policy>(&s);
    let cap = ts::take_from_sender<AgentCap>(&s);
    let (coin_out, receipt) = vault::withdraw_with_receipt<USDC>(&mut v, &cap, &mut p, 101, POOL, OPERATOR, b"USDC", &clk, ts::ctx(&mut s));
    test_utils::destroy(coin_out);
    receipt::destroy_for_testing(receipt);
    ts::return_to_sender(&s, cap);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 4. FLAG #1: an uncapped position asset (DEEP from a swap) is SELLABLE — the
//    withdrawal does NOT abort, so it isn't trapped; nothing is recorded.
#[test]
fun test_uncapped_position_is_sellable() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 500, 100, 1_000);
    ts::next_tx(&mut s, AGENT);
    let mut v = ts::take_shared<Vault>(&s);
    let mut p = ts::take_shared<Policy>(&s);
    let cap = ts::take_from_sender<AgentCap>(&s);
    let (coin_out, receipt) = vault::withdraw_with_receipt<DEEP>(&mut v, &cap, &mut p, 500, POOL, OPERATOR, b"DEEP", &clk, ts::ctx(&mut s));
    assert!(coin::value(&coin_out) == 500, 0);
    assert!(policy::spent_today<DEEP>(&p) == 0, 1); // uncapped: nothing recorded
    test_utils::destroy(coin_out);
    receipt::destroy_for_testing(receipt);
    ts::return_to_sender(&s, cap);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 5. Exfil gate: a position asset (uncapped) cannot be transferred out.
#[test]
#[expected_failure(abort_code = ::altheia::policy::EAssetNotAllowed)]
fun test_uncapped_position_not_transferable() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 500, 100, 1_000);
    ts::next_tx(&mut s, OPERATOR);
    let p = ts::take_shared<Policy>(&s);
    policy::assert_transferable<DEEP>(&p); // aborts — DEEP has no cap
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 6. FLAG #2: after revoke, the OWNER drains ALL assets — including the uncapped
//    DEEP — back to their wallet. Caps never restrict the owner.
#[test]
fun test_owner_drains_all_assets_after_revoke() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 500, 100, 1_000);
    ts::next_tx(&mut s, OPERATOR);
    let mut v = ts::take_shared<Vault>(&s);
    let mut p = ts::take_shared<Policy>(&s);
    let owner = ts::take_from_sender<OwnerCap>(&s);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    assert!(policy::is_revoked(&p), 0);
    let usdc = vault::admin_withdraw_all<USDC>(&mut v, &owner, ts::ctx(&mut s));
    let deep = vault::admin_withdraw_all<DEEP>(&mut v, &owner, ts::ctx(&mut s));
    assert!(coin::value(&usdc) == 1_000, 1);
    assert!(coin::value(&deep) == 500, 2); // uncapped position recovered by owner
    assert!(vault::balance<USDC>(&v) == 0, 3);
    assert!(vault::balance<DEEP>(&v) == 0, 4);
    test_utils::destroy(usdc);
    test_utils::destroy(deep);
    ts::return_to_sender(&s, owner);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 8. #2 cross-vault tampering: an operator cannot mutate a policy that belongs
//    to a DIFFERENT vault, even holding a valid OwnerCap for their own vault.
#[test]
#[expected_failure(abort_code = ::altheia::vault::EWrongVault)]
fun test_admin_rejects_policy_from_other_vault() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    let (vault_a, owner_a) = vault::provision_open(ts::ctx(&mut s));
    let mut policy_a = vault::mint_policy_open(&vault_a, &owner_a, b"a", vector[POOL], vector[SWAP], 9_999_999_999_999, ts::ctx(&mut s));
    let (vault_b, owner_b) = vault::provision_open(ts::ctx(&mut s));
    // owner_b legitimately controls vault_b, but policy_a belongs to vault_a.
    vault::admin_revoke_policy(&vault_b, &owner_b, &mut policy_a, &clk);
    // Unreachable after the abort; present so every resource is consumed.
    vault::share_vault(vault_a);
    vault::share_vault(vault_b);
    policy::share(policy_a);
    test_utils::destroy(owner_a);
    test_utils::destroy(owner_b);
    clock::destroy_for_testing(clk);
    ts::end(s);
}

// 9. Deposits are authorized: an operator cannot fund a vault they don't own.
//    Removing the open `deposit` is what blocks third-party junk-coin griefing.
#[test]
#[expected_failure(abort_code = ::altheia::vault::EWrongVault)]
fun test_admin_deposit_rejects_foreign_owner() {
    let mut s = ts::begin(OPERATOR);
    let (vault_a, owner_a) = vault::provision_open(ts::ctx(&mut s));
    let (mut vault_b, owner_b) = vault::provision_open(ts::ctx(&mut s));
    // owner_a controls vault_a, not vault_b → funding vault_b with it aborts.
    vault::admin_deposit<USDC>(&mut vault_b, &owner_a, coin::mint_for_testing<USDC>(100, ts::ctx(&mut s)));
    vault::share_vault(vault_a);
    vault::share_vault(vault_b);
    test_utils::destroy(owner_a);
    test_utils::destroy(owner_b);
    ts::end(s);
}

// 7. After revoke, the agent's withdrawal aborts.
#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyRevoked)]
fun test_withdraw_after_revoke_aborts() {
    let mut s = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut s));
    setup(&mut s, &clk, 1_000, 0, 100, 1_000);
    ts::next_tx(&mut s, OPERATOR);
    let mut p = ts::take_shared<Policy>(&s);
    let v0 = ts::take_shared<Vault>(&s);
    let owner = ts::take_from_sender<OwnerCap>(&s);
    vault::admin_revoke_policy(&v0, &owner, &mut p, &clk);
    ts::return_to_sender(&s, owner);
    ts::return_shared(v0);
    ts::return_shared(p);
    ts::next_tx(&mut s, AGENT);
    let mut v = ts::take_shared<Vault>(&s);
    let mut p2 = ts::take_shared<Policy>(&s);
    let cap = ts::take_from_sender<AgentCap>(&s);
    let (coin_out, receipt) = vault::withdraw_with_receipt<USDC>(&mut v, &cap, &mut p2, 10, POOL, OPERATOR, b"USDC", &clk, ts::ctx(&mut s));
    test_utils::destroy(coin_out);
    receipt::destroy_for_testing(receipt);
    ts::return_to_sender(&s, cap);
    ts::return_shared(v);
    ts::return_shared(p2);
    clock::destroy_for_testing(clk);
    ts::end(s);
}
