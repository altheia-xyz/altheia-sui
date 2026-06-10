#[test_only]
module altheia::receipt_tests;

use sui::sui::SUI;
use sui::test_scenario as ts;
use sui::test_utils;
use sui::clock;
use sui::coin;
use altheia::vault::{Self, Vault};
use altheia::policy::Policy;
use altheia::agent::AgentCap;
use altheia::receipt;

const OPERATOR: address = @0xCAFE;
const AGENT: address = @0xBEEF;
const RECIPIENT: address = @0xFACE;
const WRONG_RECIPIENT: address = @0xDEAD;
const ALLOWED_PKG: address = @0xDEEB;

fun mint_simple_receipt(scenario: &mut ts::Scenario, clk: &clock::Clock) {
    let mut v = ts::take_shared<Vault<SUI>>(scenario);
    let cap = ts::take_from_sender<AgentCap>(scenario);
    let mut p = ts::take_shared<Policy>(scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v,
        &cap,
        &mut p,
        50,
        ALLOWED_PKG,
        RECIPIENT,
        b"SUI",
        clk,
        ts::ctx(scenario),
    );
    receipt::attest_simple(r, RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
}

fun setup(): (ts::Scenario, vault::OwnerCap, clock::Clock) {
    let mut scenario = ts::begin(OPERATOR);
    let owner = vault::provision<SUI>(ts::ctx(&mut scenario));
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, OPERATOR);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let funds = coin::mint_for_testing<SUI>(1_000, ts::ctx(&mut scenario));
    vault::deposit(&mut v, funds);
    let pid = vault::mint_policy(
        &v, &owner, b"agent-1", 100, 500, vector[ALLOWED_PKG],
        1_000_000_000, &clk, ts::ctx(&mut scenario),
    );
    vault::mint_agent_cap(&v, &owner, pid, b"agent-1", AGENT, ts::ctx(&mut scenario));
    ts::return_shared(v);
    (scenario, owner, clk)
}

#[test]
fun test_attest_simple_closes_receipt_when_recipient_matches() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    mint_simple_receipt(&mut scenario, &clk);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::ERecipientMismatch)]
fun test_attest_simple_aborts_on_recipient_mismatch() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v, &cap, &mut p, 50, ALLOWED_PKG, RECIPIENT, b"SUI", &clk, ts::ctx(&mut scenario),
    );
    receipt::attest_simple(r, WRONG_RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = ::altheia::receipt::EUnderMinValue)]
fun test_attest_value_conservation_aborts_under_min() {
    let (mut scenario, owner, clk) = setup();
    ts::next_tx(&mut scenario, AGENT);
    let mut v = ts::take_shared<Vault<SUI>>(&scenario);
    let cap = ts::take_from_sender<AgentCap>(&scenario);
    let mut p = ts::take_shared<Policy>(&scenario);
    let (coin_out, r) = vault::withdraw_with_receipt(
        &mut v, &cap, &mut p, 50, ALLOWED_PKG, RECIPIENT, b"SUI", &clk, ts::ctx(&mut scenario),
    );
    // amount_out=40 < min_out=45 → should abort EUnderMinValue
    receipt::attest_value_conservation(r, 40, 45, RECIPIENT);
    test_utils::destroy(coin_out);
    test_utils::destroy(cap);
    ts::return_shared(p);
    ts::return_shared(v);
    clock::destroy_for_testing(clk);
    test_utils::destroy(owner);
    ts::end(scenario);
}
