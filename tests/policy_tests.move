#[test_only]
module altheia::policy_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::agent::AgentCap;
use altheia::actions;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const ALLOWED_PKG: address = @0xDEEB;
const DISALLOWED_PKG: address = @0xBADD;

/// Provision a vault + policy capping SUI (per_tx, per_day), allowing the swap
/// action on ALLOWED_PKG, with an AgentCap for AGENT. Vault + policy shared.
fun setup_with_caps(per_tx: u64, per_day: u64): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (vault, owner) = vault::provision_open(ts::ctx(&mut scenario));
    let mut p = vault::mint_policy_open(&vault, &owner, b"agent-1", vector[ALLOWED_PKG], vector[actions::deepbook_swap()], 1_000_000_000, ts::ctx(&mut scenario));
    vault::add_asset_cap<SUI>(&vault, &owner, &mut p, per_tx, per_day, &clk);
    vault::mint_agent_cap_for(&vault, &owner, &p, b"agent-1", AGENT, ts::ctx(&mut scenario));
    vault::share_vault(vault);
    policy::share(p);
    (scenario, owner, clk)
}

#[test]
fun test_check_and_consume_passes_under_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 50, ALLOWED_PKG, &clk);
    assert!(policy::spent_today<SUI>(&p) == 50, 0);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerTx)]
fun test_check_and_consume_aborts_over_per_tx_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 101, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPackageNotAllowed)]
fun test_check_and_consume_aborts_on_disallowed_package() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 50, DISALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyRevoked)]
fun test_check_and_consume_aborts_after_revoke() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::ECapExceededPerDay)]
fun test_check_and_consume_aborts_over_per_day_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let mut i = 0;
    while (i < 5) { policy::check_and_consume<SUI>(&mut p, &cap, 100, ALLOWED_PKG, &clk); i = i + 1; };
    policy::check_and_consume<SUI>(&mut p, &cap, 100, ALLOWED_PKG, &clk); // 600 > 500
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_per_tx_cap_zero_is_optional() {
    let (mut scenario, owner, clk) = setup_with_caps(0, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 400, ALLOWED_PKG, &clk);
    assert!(policy::spent_today<SUI>(&p) == 400, 0);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_allowlist_allows_and_denies() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let p = ts::take_shared<Policy>(&scenario);
    assert!(policy::allows(&p, actions::deepbook_swap()), 0);
    assert!(!policy::allows(&p, actions::transfer()), 1);
    assert!(!policy::allows(&p, actions::deepbook_limit_order()), 2);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
fun test_action_params_roundtrip() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let band = vector[10u64, 1_000u64, 50u64];
    vault::admin_set_action_params(&v, &owner, &mut p, actions::deepbook_limit_order(), band, &clk);
    assert!(policy::has_action_params(&p, actions::deepbook_limit_order()), 0);
    let got = policy::action_params(&p, actions::deepbook_limit_order());
    assert!(got == vector[10u64, 1_000u64, 50u64], 1);
    ts::return_shared(v);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::policy::EPolicyPaused)]
fun test_check_and_consume_aborts_when_paused() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_pause_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume<SUI>(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
