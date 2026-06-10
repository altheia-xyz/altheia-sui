#[test_only]
module altheia::policy_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use altheia::vault::{Self, Vault};
use altheia::policy::{Self, Policy};
use altheia::agent::AgentCap;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const ALLOWED_PKG: address = @0xDEEB;
const DISALLOWED_PKG: address = @0xBADD;

fun setup_with_caps(
    per_tx: u64,
    per_day: u64,
): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let v = ts::take_shared<Vault<SUI>>(&scenario);
    let pid = vault::mint_policy(
        &v,
        &owner,
        b"agent-1",
        per_tx,
        per_day,
        vector[ALLOWED_PKG],
        1_000_000_000,
        &clk,
        ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"agent-1", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);
    (scenario, owner, clk)
}

#[test]
fun test_check_and_consume_passes_under_cap() {
    let (mut scenario, owner, clk) = setup_with_caps(100, 500);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    policy::check_and_consume(&mut p, &cap, 50, ALLOWED_PKG, &clk);
    assert!(policy::spent_today(&p) == 50, 0);
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
    policy::check_and_consume(&mut p, &cap, 101, ALLOWED_PKG, &clk);
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
    policy::check_and_consume(&mut p, &cap, 50, DISALLOWED_PKG, &clk);
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
    let v = ts::take_shared<Vault<SUI>>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_revoke_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
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
    let v = ts::take_shared<Vault<SUI>>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    vault::admin_pause_policy(&v, &owner, &mut p, &clk);
    ts::return_shared(v);
    ts::next_tx(&mut scenario, AGENT);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    policy::check_and_consume(&mut p, &cap, 10, ALLOWED_PKG, &clk);
    test_utils::destroy(cap);
    ts::return_shared(p);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
