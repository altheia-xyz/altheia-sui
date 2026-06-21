#[test_only]
module altheia::vault_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::actions;
use altheia::agent::AgentCap;
use altheia::receipt;
use altheia::registry::{Self, AdapterRegistry};
use altheia::test_support::{Self, AdapterW};

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;

// Single-PTB provisioning: provision_open + deposit + mint_policy_open +
// mint_agent_cap_for compose without intermediate sharing, and the swap
// value-guard (action_params[deepbook_swap]) is set so the adapter won't abort
// EActionConfigMissing. This is the contract side of the one-signature mint.
#[test]
fun test_single_ptb_provision_sets_swap_action_params() {
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    // returns vault + owner BY VALUE (unshared) for one-PTB composition
    let (mut v, owner) = vault::provision_open<SUI>(ts::ctx(&mut scenario));
    let funds = coin::mint_for_testing<SUI>(2_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    assert!(vault::balance(&v) == 2_000, 0);

    let p = vault::mint_policy_with_guard<SUI>(
        &v, &owner, b"agent-ptb", 500, 2_000, vector[@0x123], vector[1], 9_999_999_999_999, 15_000_000, &clk, ts::ctx(&mut scenario),
    );
    // the bug this guards against: a single-PTB policy with no swap action-param
    assert!(policy::has_action_params(&p, actions::deepbook_swap()), 1);
    assert!(policy::action_params(&p, actions::deepbook_swap())[0] == 15_000_000, 2);

    vault::mint_agent_cap_for<SUI>(&v, &owner, &p, b"agent-ptb", AGENT, ts::ctx(&mut scenario));

    // PTB-end: consume the by-value objects (share / hand to owner)
    policy::share(p);
    vault::share_vault(v);
    test_utils::destroy(owner);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

#[test]
fun test_provision_creates_vault_and_returns_owner() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_deposit_increases_balance() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let c = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, c);
    assert!(vault::balance(&v) == 1_000, 0);
    ts::return_shared(v);
    test_utils::destroy(owner);
    ts::end(scenario);
}

// Owner kill-switch drain: empties the vault back to the owner.
#[test]
fun test_admin_withdraw_all_drains_to_owner() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let c = vault::admin_withdraw_all<SUI>(&mut v, &owner, ts::ctx(&mut scenario));
    assert!(coin::value(&c) == 1_000, 0);
    assert!(vault::balance(&v) == 0, 1);
    test_utils::destroy(c);
    ts::return_shared(v);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_withdraw_with_receipt_returns_coin_and_receipt() {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let regcap = registry::create(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    // approve the (test) adapter witness so the receipt can be closed
    let mut reg = ts::take_shared<AdapterRegistry>(&scenario);
    registry::add_adapter<AdapterW>(&mut reg, &regcap);
    ts::return_shared(reg);
    // fund + provision the agent
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v, &owner, b"agent-1", 100, 500, vector[@0x0], vector[], 1_000_000_000, &clk, ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"agent-1", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);

    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let reg = ts::take_shared<AdapterRegistry>(&scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v, &cap, &mut p, 50, @0x0, RECIPIENT, b"SUI", &clk, ts::ctx(&mut scenario),
    );
    // close the hot potato through the gated, approved-adapter path
    receipt::consume_with_check<AdapterW, SUI>(test_support::witness(), &reg, r, &coin_out, 0, RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(reg);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    test_utils::destroy(regcap);
    ts::end(scenario);
}
